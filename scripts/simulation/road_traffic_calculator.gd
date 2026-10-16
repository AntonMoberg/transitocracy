extends RefCounted

const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadTrafficProfile = preload("res://scripts/simulation/road_traffic_profile.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

const MAX_ASSIGNMENT_PASSES = 12
const ASSIGNMENT_RELATIVE_GAP = 0.005
const FEEDBACK_PASSES = 2
const QUEUE_STEPS_PER_HOUR = 4


static func build_day(region, unix_seconds: int, previous_day_profile = null, full_feedback: bool = true, previous_traffic_profile = null) -> Dictionary:
	var flow_profile
	var traffic_profile
	var passes := FEEDBACK_PASSES if full_feedback else 1
	for feedback_pass in range(passes):
		flow_profile = TripFlowCalculator.build(region)
		TripFlowCalculator.populate_day(flow_profile, region.generation_seed, unix_seconds, CalendarClock.is_weekend_unix(unix_seconds), previous_day_profile)
		traffic_profile = assign_day(region, flow_profile, 24, previous_traffic_profile)
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
	profile.hourly_assignment_gap.resize(hours_to_assign)
	for link in region.road_links:
		profile.link_ids.append(link.id)
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var neighbors: Array = RoadGraph.adjacency(region)
	var count: int = region.neighborhoods.size()
	# A forest has one path per pair, so congestion cannot change route choice.
	var forest: bool = RoadGraph.is_forest(region)
	var assignment_passes := 1 if forest else MAX_ASSIGNMENT_PASSES
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
				hourly_results[hour] = _assign_hour(region, flow_profile, hour, free_costs, neighbors, count, assignment_passes, fixed_trees),
			hours_to_assign, workers, false, "Hourly road assignment")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for hour in range(hours_to_assign):
			hourly_results[hour] = _assign_hour(region, flow_profile, hour, free_costs, neighbors, count, assignment_passes, fixed_trees)
	for hour in range(hours_to_assign):
		var result: Dictionary = hourly_results[hour]
		profile.hourly_volumes.append(result["volumes"])
		profile.hourly_peak_ratio[hour] = result["peak_ratio"]
		profile.hourly_assignment_gap[hour] = result["gap"]
	var starting_queues: PackedVector2Array = carry_queues(profile.link_ids, warm_start_profile)
	var loading: Dictionary = load_queues(region, profile.hourly_volumes, starting_queues)
	profile.initial_queues = loading["initial_queues"]
	profile.quarter_hour_queues = loading["quarter_hour_queues"]
	profile.quarter_hour_served = loading["quarter_hour_served"]
	profile.quarter_hour_link_times = loading["quarter_hour_link_times"]
	profile.hourly_served = loading["hourly_served"]
	profile.hourly_link_times = loading["hourly_link_times"]
	profile.end_queues = loading["end_queues"]
	var pair_results: Array = []
	pair_results.resize(hours_to_assign)
	if parallel_hours and hours_to_assign >= 4 and count >= 32 and OS.get_processor_count() > 1:
		var workers := mini(8, mini(OS.get_processor_count(), hours_to_assign))
		var task_id := WorkerThreadPool.add_group_task(
			func(hour: int) -> void:
				pair_results[hour] = RoadGraph.route_pairs(region, profile.hourly_link_times[hour], neighbors, false)["times"],
			hours_to_assign, workers, false, "Hourly queued travel times")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for hour in range(hours_to_assign):
			pair_results[hour] = RoadGraph.route_pairs(region, profile.hourly_link_times[hour], neighbors, false)["times"]
	for hour in range(hours_to_assign):
		profile.hourly_pair_times.append(pair_results[hour])
	return profile


static func carry_queues(link_ids: PackedInt32Array, previous_profile) -> PackedVector2Array:
	var queues := PackedVector2Array()
	queues.resize(link_ids.size())
	if previous_profile == null or previous_profile.link_ids.size() != previous_profile.end_queues.size():
		return queues
	var previous_by_id: Dictionary = {}
	for index in range(previous_profile.link_ids.size()):
		previous_by_id[previous_profile.link_ids[index]] = previous_profile.end_queues[index]
	for index in range(link_ids.size()):
		if previous_by_id.has(link_ids[index]):
			queues[index] = previous_by_id[link_ids[index]]
	return queues


static func _assign_hour(region, flow_profile, hour: int, free_costs: PackedVector2Array, neighbors: Array, count: int, assignment_passes: int, fixed_trees: Array[Dictionary]) -> Dictionary:
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
	var volumes := PackedVector2Array()
	volumes.resize(region.road_links.size())
	for iteration in range(assignment_passes):
		var costs: PackedVector2Array = _congested_costs(region, free_costs, volumes)
		var assigned: PackedVector2Array = RoadGraph.assign_volumes(region, costs, demand, neighbors, fixed_trees)
		if iteration > 0 and _relative_assignment_gap(volumes, assigned, costs) <= ASSIGNMENT_RELATIVE_GAP:
			break
		var weight := 1.0 / float(iteration + 1)
		for link_index in range(volumes.size()):
			volumes[link_index] = volumes[link_index].lerp(assigned[link_index], weight)
	var final_costs: PackedVector2Array = _congested_costs(region, free_costs, volumes)
	var final_assigned: PackedVector2Array = RoadGraph.assign_volumes(region, final_costs, demand, neighbors, fixed_trees) if assignment_passes > 1 else volumes
	var gap: float = _relative_assignment_gap(volumes, final_assigned, final_costs)
	var peak_ratio := 0.0
	for link_index in range(volumes.size()):
		var capacity: float = RoadGraph.capacity_per_lane(region.road_links[link_index].road_class) * region.road_links[link_index].lanes_per_direction
		peak_ratio = maxf(peak_ratio, maxf(volumes[link_index].x, volumes[link_index].y) / capacity)
	return {"volumes": volumes, "peak_ratio": peak_ratio, "gap": gap}


static func _relative_assignment_gap(volumes: PackedVector2Array, shortest_volumes: PackedVector2Array, costs: PackedVector2Array) -> float:
	var actual_minutes := 0.0
	var shortest_minutes := 0.0
	for link_index in range(volumes.size()):
		actual_minutes += volumes[link_index].dot(costs[link_index])
		shortest_minutes += shortest_volumes[link_index].dot(costs[link_index])
	if actual_minutes <= 0.0001:
		return 0.0
	return maxf(0.0, (actual_minutes - shortest_minutes) / actual_minutes)


# Hourly route demand is assigned independently; this loading pass then carries
# each direction's unserved vehicles across quarter-hour bins and day boundaries.
static func load_queues(region, hourly_volumes: Array[PackedVector2Array], starting_queues: PackedVector2Array = PackedVector2Array()) -> Dictionary:
	var link_count: int = region.road_links.size()
	var queues := PackedVector2Array()
	queues.resize(link_count)
	if starting_queues.size() == link_count:
		queues = starting_queues.duplicate()
	var initial_queues: PackedVector2Array = queues.duplicate()
	var quarter_hour_queues: Array[PackedVector2Array] = []
	var quarter_hour_served: Array[PackedVector2Array] = []
	var quarter_hour_link_times: Array[PackedVector2Array] = []
	var hourly_served: Array[PackedVector2Array] = []
	var hourly_link_times: Array[PackedVector2Array] = []
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for hour in range(hourly_volumes.size()):
		var time_sum := PackedVector2Array()
		time_sum.resize(link_count)
		var served_sum := PackedVector2Array()
		served_sum.resize(link_count)
		for _step in range(QUEUE_STEPS_PER_HOUR):
			var step_queues := PackedVector2Array()
			var step_served := PackedVector2Array()
			var step_times := PackedVector2Array()
			for link_index in range(link_count):
				var link = region.road_links[link_index]
				var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
				var step_capacity: float = capacity / float(QUEUE_STEPS_PER_HOUR)
				var arrival: Vector2 = hourly_volumes[hour][link_index] / float(QUEUE_STEPS_PER_HOUR)
				var previous_queue: Vector2 = queues[link_index]
				var available: Vector2 = previous_queue + arrival
				var served := Vector2(minf(available.x, step_capacity), minf(available.y, step_capacity))
				var remaining: Vector2 = available - served
				step_queues.append(remaining)
				step_served.append(served)
				served_sum[link_index] += served
				var travel_time := Vector2(
					_queue_link_minutes(free_costs[link_index].x, previous_queue.x, remaining.x, served.x, capacity),
					_queue_link_minutes(free_costs[link_index].y, previous_queue.y, remaining.y, served.y, capacity))
				step_times.append(travel_time)
				time_sum[link_index] += travel_time
			queues = step_queues
			quarter_hour_queues.append(step_queues)
			quarter_hour_served.append(step_served)
			quarter_hour_link_times.append(step_times)
		for link_index in range(link_count):
			time_sum[link_index] /= float(QUEUE_STEPS_PER_HOUR)
		hourly_link_times.append(time_sum)
		hourly_served.append(served_sum)
	return {
		"initial_queues": initial_queues,
		"quarter_hour_queues": quarter_hour_queues,
		"quarter_hour_served": quarter_hour_served,
		"quarter_hour_link_times": quarter_hour_link_times,
		"hourly_served": hourly_served,
		"hourly_link_times": hourly_link_times,
		"end_queues": queues,
	}


static func _queue_link_minutes(free_minutes: float, previous_queue: float, remaining_queue: float, served: float, capacity: float) -> float:
	var moving_ratio: float = minf(1.0, served * float(QUEUE_STEPS_PER_HOUR) / capacity)
	var moving_minutes: float = free_minutes * (1.0 + 0.15 * pow(moving_ratio, 4.0))
	var waiting_minutes: float = 30.0 * (previous_queue + remaining_queue) / capacity
	return moving_minutes + waiting_minutes


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
