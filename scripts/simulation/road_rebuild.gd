extends RefCounted

const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const CompactFlow = preload("res://scripts/simulation/compact_trip_flow_calculator.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")


static func build(source_region, previous_state, unix_seconds: int, changed_city_ids: Array[int] = [], previous_flow = null, new_district_only: bool = false, owned:bool=false) -> Dictionary:
	var started: int = Time.get_ticks_usec()
	var stages_us: Dictionary = {}
	var region = source_region if owned else RegionSnapshot.copy_region(source_region)
	stages_us["copy"] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	DevelopmentPlanner.refresh_candidates(region, changed_city_ids)
	stages_us["candidates"] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var reuse_flow: bool = new_district_only and _can_reuse_empty_district_flow(region, previous_state, previous_flow, unix_seconds)
	if not reuse_flow:
		region.city_od_candidates.clear()
		AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.refresh_desirability(region)
	stages_us["accessibility"] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var flow
	if reuse_flow:
		flow = CompactFlow.extend_for_empty_districts(previous_flow, region)
	else:
		flow = TripFlowCalculator.build(region)
		TripFlowCalculator.populate_day(flow, region.generation_seed, unix_seconds, CalendarClock.is_weekend_unix(unix_seconds))
	stages_us["flow"] = Time.get_ticks_usec() - started
	started = Time.get_ticks_usec()
	var traffic_state = MultiScaleTraffic.new_day(region, flow, unix_seconds, previous_state)
	stages_us["traffic"] = Time.get_ticks_usec() - started
	return {"region": region, "flow": flow, "traffic_state": traffic_state, "errors": region.validation_errors(), "stages_us": stages_us, "reused_flow": reuse_flow}

static func edit(source_region, previous_state, unix_seconds:int, previous_flow, request:Dictionary) -> Dictionary:
	# Copy and mutate on the worker. The UI keeps the old world until the
	# complete transaction (including traffic/access) can be published.
	var start:=Time.get_ticks_usec()
	var region=RegionSnapshot.copy_region(source_region)
	var copied:=Time.get_ticks_usec()-start
	start=Time.get_ticks_usec()
	var outcome:Dictionary
	var cities:Array[int]=[]
	var new_district:=false
	if request.kind=="approvals":
		var approved:=0
		var reason:=""
		new_district=true
		for key in request["keys"]:
			var id:int=int(region.development_candidate_keys.get(key,-1))
			if id<0: continue
			var trial:Dictionary=DevelopmentPlanner.set_approval(region,id,true)
			if trial.get("ok",false):
				approved+=1
				new_district=new_district and trial.get("new_neighborhood",false)
				var city:int=region.development_candidates[id].city_id
				if not cities.has(city): cities.append(city)
			else: reason=trial.get("reason","")
		outcome={"ok":approved>0,"reason":reason,"approved":approved}
	elif request.kind=="approval":
		outcome=DevelopmentPlanner.set_approval(region,request.candidate_id,request.approved,request.allocation,request.shares,request.density)
		if outcome.get("ok",false): cities.append(int(region.development_candidates[request.candidate_id].city_id))
		new_district=outcome.get("new_neighborhood",false)
	else:
		var planner=preload("res://scripts/simulation/road_planner.gd")
		outcome=planner.demolish(region,request.preview.target_link_id) if request.preview.get("kind","")==planner.DEMOLISH else planner.commit(region,request.preview,request.day_key)
	if not outcome.get("ok",false): return {"edit_failed":true,"reason":outcome.get("reason","Edit failed."),"edit_kind":request.kind}
	var edit_us:=Time.get_ticks_usec()-start
	var result:=build(region,previous_state,unix_seconds,cities,previous_flow,new_district,true)
	result.stages_us["copy"]=copied
	result.stages_us["edit"]=edit_us
	result["edit_kind"]=request.kind
	result["edit_outcome"]=outcome
	return result


static func _can_reuse_empty_district_flow(region, previous_state, previous_flow, unix_seconds: int) -> bool:
	if not region.is_large_scale or previous_state == null or previous_flow == null or not previous_flow.is_compact:
		return false
	if previous_flow.active_day_key != floori(float(unix_seconds) / 86400.0) or previous_flow.active_weekend != CalendarClock.is_weekend_unix(unix_seconds):
		return false
	var old_count: int = previous_flow.compact_origin_daily.get(FlowProfile.WORK, PackedFloat32Array()).size()
	if old_count >= region.neighborhoods.size() or region.accessibility.size() != region.neighborhoods.size() or region.neighborhood_accessible.size() != region.neighborhoods.size() or region.neighborhood_development_connected.size() != region.neighborhoods.size():
		return false
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		if previous_flow.compact_origin_daily.get(purpose, PackedFloat32Array()).size() != old_count or previous_flow.compact_destination_daily.get(purpose, PackedFloat32Array()).size() != old_count:
			return false
	for neighborhood_id in range(old_count, region.neighborhoods.size()):
		var neighborhood = region.neighborhoods[neighborhood_id]
		if neighborhood.households != 0 or neighborhood.jobs != 0 or neighborhood.population != 0 or neighborhood.shopping_attraction != 0.0 or region.neighborhood_development_connected[neighborhood_id] != 0 or region.neighborhood_accessible[neighborhood_id] != 0:
			return false
	if previous_state.link_ids.size() != region.road_links.size() or region.city_travel_times.size() != region.cities.size():
		return false
	for link_index in range(region.road_links.size()):
		if previous_state.link_ids[link_index] != region.road_links[link_index].id:
			return false
	return true
