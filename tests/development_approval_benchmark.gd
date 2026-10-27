extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const RoadRebuild = preload("res://scripts/simulation/road_rebuild.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var start: int = Time.get_ticks_usec()
	var large: bool = OS.get_cmdline_user_args().has("--large")
	var setup:Dictionary=preload("res://scripts/simulation/region_setup.gd").build(8752568,256 if large else 32,0.1)
	var region=setup.region
	print("Generate: %.1f ms" % [float(Time.get_ticks_usec() - start) / 1000.0])
	start = Time.get_ticks_usec()
	DevelopmentPlanner.refresh_candidates(region)
	print("First candidates: %.1f ms, %d total" % [float(Time.get_ticks_usec() - start) / 1000.0, region.development_candidates.size()])
	region.dev_mode = true
	var clock = setup.clock
	var flow = setup.flow
	var traffic = setup.traffic_state
	var city_id := -1
	for step in range(12):
		var candidate_id := -1
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0 and (city_id < 0 or int(candidate["city_id"]) == city_id):
				candidate_id = int(candidate["id"])
				city_id = int(candidate["city_id"])
				break
		if candidate_id < 0:
			push_error("No approvable growth proposal at step %d" % step)
			quit(1)
			return
		start = Time.get_ticks_usec()
		var approved: Dictionary = DevelopmentPlanner.set_approval(region, candidate_id, true)
		var approval_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
		print("Approval breakdown: %s"%approved.get("stages_us",{}))
		if not approved.get("ok", false):
			push_error("Approval %d failed: %s" % [step, approved])
			quit(1)
			return
		start = Time.get_ticks_usec()
		var result: Dictionary = RoadRebuild.build(region, traffic, clock.unix_seconds, [city_id], flow, true)
		print("Approval %d: action %.1f ms, rebuild %.1f ms, reused flow %s, stages %s, candidates %d" % [step + 1, approval_ms, float(Time.get_ticks_usec() - start) / 1000.0, result["reused_flow"], result["stages_us"], result["region"].development_candidates.size()])
		if not result["errors"].is_empty():
			push_error("Rebuild %d failed: %s" % [step, result["errors"]])
			quit(1)
			return
		if large and step < 2:
			var full: Dictionary = RoadRebuild.build(region, traffic, clock.unix_seconds, [city_id])
			if not result["reused_flow"] or not _same_profile(result, full):
				push_error("Approval %d local rebuild differs from a full traffic rebuild." % [step + 1])
				quit(1)
				return
		region = result["region"]
		traffic = result["traffic_state"]
		flow = result["flow"]
	quit(0)


func _same_profile(local: Dictionary, full: Dictionary) -> bool:
	if not full["errors"].is_empty() or local["region"].accessibility.size() != full["region"].accessibility.size():
		return false
	for index in range(local["region"].accessibility.size()):
		if absf(local["region"].accessibility[index] - full["region"].accessibility[index]) > 0.001:
			return false
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		for field in ["compact_origin_daily", "compact_destination_daily"]:
			if not _same_array(local["flow"].get(field)[purpose], full["flow"].get(field)[purpose]):
				return false
		for row_id in range(local["flow"].compact_city_od[purpose].size()):
			if not _same_array(local["flow"].compact_city_od[purpose][row_id], full["flow"].compact_city_od[purpose][row_id]):
				return false
	return _same_array(local["flow"].hourly_trips, full["flow"].hourly_trips)


func _same_array(first: PackedFloat32Array, second: PackedFloat32Array) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if absf(first[index] - second[index]) > 0.001:
			return false
	return true
