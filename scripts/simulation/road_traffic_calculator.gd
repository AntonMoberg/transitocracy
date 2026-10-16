extends RefCounted

const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadTrafficProfile = preload("res://scripts/simulation/road_traffic_profile.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

const ASSIGNMENT_PASSES = 4
const FEEDBACK_PASSES = 2


static func build_day(region, unix_seconds: int, previous_day_profile = null, full_feedback: bool = true, previous_traffic_profile = null) -> Dictionary:
	var flow_profile
	var traffic_profile
	var passes := FEEDBACK_PASSES if full_feedback else 1
	for feedback_pass in range(passes):
		flow_profile = TripFlowCalculator.build(region)
		TripFlowCalculator.populate_day(flow_profile, region.generation_seed, unix_seconds, CalendarClock.is_weekend_unix(unix_seconds), previous_day_profile)
		traffic_profile = assign_day(region, flow_profile, 24, previous_traffic_profile if not full_feedback else null)
		var weighted_times: Array[PackedFloat32Array] = generalized_travel_times(region, flow_profile, traffic_profile)
		for origin_id in range(region.neighborhoods.size()):
			for destination_id in range(region.neighborhoods.size()):
				var blend := 1.0 if feedback_pass == passes - 1 else 0.65
				region.travel_times[origin_id][destination_id] = lerpf(region.travel_times[origin_id][destination_id], weighted_times[origin_id][destination_id], blend)
		AccessibilityCalculator.recalculate_jobs(region)
	return {"flow": flow_profile, "traffic": traffic_profile}


static func assign_day(region, flow_profile, hours_to_assign: int = 24, warm_start_profile = null, parallel_hours: bool = true):
	var profile = RoadTrafficProfile.new()
	profile.active_day_key = flow_profile.active_day_key
	profile.hourly_peak_ratio.resize(hours_to_assign)
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var neighbors: Array = RoadGraph.adjacency(region)
	var count: int = region.neighborhoods.size()
	var can_warm_start: bool = hours_to_assign > 0 and warm_start_profile != null and warm_start_profile.hourly_volumes.size() >= hours_to_assign and warm_start_profile.hourly_volumes[0].size() == region.road_links.size()
	# A forest has one path per pair, so congestion cannot change route choice.
	var forest: bool = RoadGraph.is_forest(region)
	var assignment_passes := 1 if forest else (2 if can_warm_start else ASSIGNMENT_PASSES)
	var fixed_trees: Array[Dictionary] = []
	if forest and hours_to_assign > 1:
		fixed_trees = RoadGraph.assignment_trees(region, free_costs, neighbors)
	var hourly_results: Array = []
	hourly_results.resize(hours_to_assign)
	# Workers only read the region and write separate slots in this fixed-size array.
	if parallel_hours and hours_to_assign >= 4 and count >= 32 and OS.get_processor_count() > 1:
		var workers := mini(8, mini(OS.get_processor_count(), hours_to_assign))
		var task_id := WorkerThreadPool.add_group_task(
			func(hour: int) -> void:
				hourly_results[hour] = _assign_hour(region, flow_profile, hour, free_costs, neighbors, count, can_warm_start, warm_start_profile, assignment_passes, fixed_trees),
			hours_to_assign, workers, false, "Hourly road assignment")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for hour in range(hours_to_assign):
			hourly_results[hour] = _assign_hour(region, flow_profile, hour, free_costs, neighbors, count, can_warm_start, warm_start_profile, assignment_passes, fixed_trees)
	for hour in range(hours_to_assign):
		var result: Dictionary = hourly_results[hour]
		profile.hourly_volumes.append(result["volumes"])
		profile.hourly_link_times.append(result["link_times"])
		profile.hourly_pair_times.append(result["pair_times"])
		profile.hourly_peak_ratio[hour] = result["peak_ratio"]
	return profile


static func _assign_hour(region, flow_profile, hour: int, free_costs: PackedVector2Array, neighbors: Array, count: int, can_warm_start: bool, warm_start_profile, assignment_passes: int, fixed_trees: Array[Dictionary]) -> Dictionary:
	var demand: Array[PackedFloat32Array] = []
	for origin_id in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		for destination_id in range(count):
			if origin_id == destination_id:
				continue
			var distance: float = region.neighborhoods[origin_id].position_km.distance_to(region.neighborhoods[destination_id].position_km)
			var car_share: float = clampf(0.20 + 0.035 * distance, 0.20, 0.90)
			row[destination_id] = car_share * (
				flow_profile.hourly_work_od[hour][origin_id][destination_id] / 1.2
				+ flow_profile.hourly_shopping_od[hour][origin_id][destination_id] / 1.5
				+ flow_profile.hourly_social_od[hour][origin_id][destination_id] / 1.8)
		demand.append(row)
	var volumes: PackedVector2Array = warm_start_profile.hourly_volumes[hour].duplicate() if can_warm_start else PackedVector2Array()
	if not can_warm_start:
		volumes.resize(region.road_links.size())
	for iteration in range(assignment_passes):
		var costs: PackedVector2Array = _congested_costs(region, free_costs, volumes)
		var assigned: PackedVector2Array = RoadGraph.assign_volumes(region, costs, demand, neighbors, fixed_trees)
		var weight := 1.0 / float(iteration + 1)
		for link_index in range(volumes.size()):
			volumes[link_index] = volumes[link_index].lerp(assigned[link_index], weight)
	var final_costs: PackedVector2Array = _congested_costs(region, free_costs, volumes)
	var final_routes: Dictionary = RoadGraph.route_pairs(region, final_costs, neighbors, false)
	var peak_ratio := 0.0
	for link_index in range(volumes.size()):
		var capacity: float = RoadGraph.capacity_per_lane(region.road_links[link_index].road_class) * region.road_links[link_index].lanes_per_direction
		peak_ratio = maxf(peak_ratio, maxf(volumes[link_index].x, volumes[link_index].y) / capacity)
	return {"volumes": volumes, "link_times": final_costs, "pair_times": final_routes["times"], "peak_ratio": peak_ratio}


static func generalized_travel_times(region, flow_profile, traffic_profile) -> Array[PackedFloat32Array]:
	var count: int = region.neighborhoods.size()
	var free_times: Array = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region), [], false)["times"]
	var result: Array[PackedFloat32Array] = []
	for origin_id in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		for destination_id in range(count):
			if origin_id == destination_id:
				row[destination_id] = RoadGraph.LOCAL_ACCESS_MINUTES
				continue
			var weighted_minutes := 0.0
			var total_trips := 0.0
			for hour in range(24):
				var trips: float = flow_profile.hourly_od[hour][origin_id][destination_id]
				weighted_minutes += trips * traffic_profile.hourly_pair_times[hour][origin_id][destination_id]
				total_trips += trips
			row[destination_id] = weighted_minutes / total_trips if total_trips > 0.01 else free_times[origin_id][destination_id]
		result.append(row)
	return result


static func _congested_costs(region, free_costs: PackedVector2Array, volumes: PackedVector2Array) -> PackedVector2Array:
	var costs := PackedVector2Array()
	for link_index in range(region.road_links.size()):
		var link = region.road_links[link_index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		var forward_ratio: float = volumes[link_index].x / capacity
		var reverse_ratio: float = volumes[link_index].y / capacity
		costs.append(Vector2(
			free_costs[link_index].x * minf(6.0, 1.0 + 0.15 * pow(forward_ratio, 4.0)),
			free_costs[link_index].y * minf(6.0, 1.0 + 0.15 * pow(reverse_ratio, 4.0))))
	return costs
