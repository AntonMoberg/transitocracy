extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Rebuild = preload("res://scripts/simulation/road_rebuild.gd")
const Snapshot = preload("res://scripts/simulation/region_snapshot.gd")
const Flow = preload("res://scripts/simulation/trip_flow_calculator.gd")
const DevelopmentJob = preload("res://scripts/simulation/development_job.gd")
var errors: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var cities := 32
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("cities="): cities = int(argument.substr(7))
	var setup: Dictionary = Setup.build(8752568, cities, .1)
	var region = setup.region
	region.dev_mode = true
	var previous_flow = setup.flow
	var traffic = setup.traffic_state
	var durations: Array[float] = []
	var cold_durations: Array[float] = []
	var city_id := -1
	for step in range(12):
		var id := -1
		for candidate in region.development_candidates:
			if candidate.neighborhood_id < 0 and candidate.frontage_link_id >= 0 and (city_id < 0 or candidate.city_id == city_id):
				id = candidate.id
				city_id = candidate.city_id
				break
		if id < 0:
			errors.append("No proposal at step %d" % step)
			break
		var candidate: Dictionary = region.development_candidates[id]
		var preparation_region = Snapshot.copy_region(region)
		var packet := Planner.prepare_approval(preparation_region, id, {}, {})
		_check(not packet.is_empty(), "Preparation failed")
		var request := {"kind":"approval", "candidate_id":id, "key":candidate.key, "approved":true, "allocation":-1, "shares":{}, "density":{}}
		var cold_started := Time.get_ticks_usec()
		var cold := Rebuild.edit(region, traffic, setup.clock.unix_seconds, previous_flow, request)
		cold_durations.append((Time.get_ticks_usec()-cold_started)/1000.0)
		request["prepared"] = packet
		var start := Time.get_ticks_usec()
		var result := Rebuild.edit(region, traffic, setup.clock.unix_seconds, previous_flow, request)
		durations.append((Time.get_ticks_usec()-start)/1000.0)
		if result.get("edit_failed", false) or cold.get("edit_failed", false):
			errors.append("Approval failed: %s / %s" % [result, cold])
			break
		_check(result.errors.is_empty(), "Invalid approved region: %s" % result.errors)
		_check(result.edit_outcome.stages_us.get("prepared", 0) == 1, "Did not reuse prepared geometry")
		_check(result.reused_flow, "Empty district did not reuse traffic flow")
		_check(result.region.neighborhoods[-1].buildings == cold.region.neighborhoods[-1].buildings, "Prepared buildings differ from cold approval")
		_check(result.region.neighborhoods[-1].base_housing_capacity == cold.region.neighborhoods[-1].base_housing_capacity, "Prepared capacity changed")
		_check(region.development_candidates[id].neighborhood_id < 0, "Approval mutated source candidate")
		if step == 0:
			var publication_region = Snapshot.copy_region(region)
			var refresh := DevelopmentJob.new()
			refresh.source = publication_region
			refresh.request = {"kind":"suggestions", "cities":[city_id]}
			var suggestions := refresh.run()
			publication_region.road_geometry_revision += 1
			_check(not DevelopmentJob.publish_suggestions(publication_region, suggestions), "Stale suggestions were published after a geometry edit")
			publication_region.road_geometry_revision -= 1
			var latest_population: int = publication_region.neighborhoods[0].population+19
			publication_region.neighborhoods[0].population = latest_population
			_check(DevelopmentJob.publish_suggestions(publication_region, suggestions) and publication_region.neighborhoods[0].population == latest_population, "Suggestion publication replaced current simulation state")
			var paid_region = Snapshot.copy_region(region)
			paid_region.dev_mode = false
			var payer = paid_region.jurisdictions[paid_region.city_jurisdiction_ids[city_id]]
			payer.treasury = 1000000000
			var paid_request := request.duplicate()
			paid_request.allocation = 12345
			var paid := Rebuild.edit(paid_region, traffic, setup.clock.unix_seconds, previous_flow, paid_request)
			_check(not paid.get("edit_failed",false) and paid.region.neighborhoods[-1].development_plan.reserved == 12345, "Prepared approval did not reserve the requested funds")
			_check(paid.region.jurisdictions[payer.id].treasury == 1000000000-12345 and payer.treasury == 1000000000, "Fund reservation was not atomic")
			payer.treasury = 0
			var rejected := Rebuild.edit(paid_region, traffic, setup.clock.unix_seconds, previous_flow, paid_request)
			_check(rejected.get("edit_failed",false) and paid_region.neighborhoods.size() == region.neighborhoods.size(), "Insufficient funds accepted a prepared approval")
			var stale_region = Snapshot.copy_region(region)
			stale_region.road_geometry_revision += 1
			var stale := Rebuild.edit(stale_region, traffic, setup.clock.unix_seconds, previous_flow, request)
			_check(not stale.get("edit_failed", false) and stale.edit_outcome.stages_us.get("prepared", 0) == 0, "Stale geometry preparation was accepted")
			var full := Rebuild.build(result.region, traffic, setup.clock.unix_seconds)
			_check(full.errors.is_empty(), "Full rebuild invalid")
			_compare_flow(result.flow, full.flow)
			for i in range(result.region.accessibility.size()):
				_check(absf(result.region.accessibility[i]-full.region.accessibility[i]) < .001, "Accessibility differs from full rebuild")
			if not region.is_large_scale:
				_check(result.traffic_state.free_pair_times.size() == result.region.neighborhoods.size(), "Route table omitted new district")
				_check(_close(result.region.travel_times, full.region.travel_times), "Extended travel times differ from full routes")
				_check(_close(result.traffic_state.free_pair_times, full.traffic_state.free_pair_times), "Extended traffic routes differ from full routes")
		region = result.region
		previous_flow = result.flow
		traffic = result.traffic_state
		print("APPROVAL %d cities=%d warm=%.1f ms cold=%.1f ms stages=%s" % [step+1,cities,durations[-1],cold_durations[-1],result.stages_us])
		Planner.refresh_candidates(region, [city_id])
	durations.sort()
	cold_durations.sort()
	if not durations.is_empty(): print("Approval latency cities=%d: warm p95=%.1f ms; cold max=%.1f ms" % [cities,durations[mini(durations.size()-1,floori(durations.size()*.95))],cold_durations[-1]])
	if OS.get_cmdline_user_args().has("--enforce-latency") and not durations.is_empty():
		_check(durations[-1] <= 500.0 and cold_durations[-1] <= 1000.0, "Approval latency budget exceeded")
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(0 if errors.is_empty() else 1)

func _compare_flow(first, second) -> void:
	for property in first.get_property_list():
		if not int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE: continue
		var field: String = property.name
		if not (field.ends_with("_od") or field.ends_with("_trips") or field in ["compact_origin_daily", "compact_destination_daily"]): continue
		_check(_close(first.get(field),second.get(field)), "Flow differs from full rebuild: "+field)

func _close(a, b) -> bool:
	if a is Array or a is Dictionary or a is PackedFloat32Array:
		if a.size() != b.size(): return false
		if a is Dictionary:
			for key in a:
				if not b.has(key) or not _close(a[key], b[key]): return false
		else:
			for i in range(a.size()):
				if not _close(a[i], b[i]): return false
		return true
	if a is float or a is int: return absf(a-b) <= .001
	return a == b

func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message): errors.append(message)
