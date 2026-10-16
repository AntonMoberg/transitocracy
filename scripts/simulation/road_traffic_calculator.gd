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


static func assign_day(region, flow_profile, hours_to_assign: int = 24, warm_start_profile = null):
	var profile = RoadTrafficProfile.new()
	profile.active_day_key = flow_profile.active_day_key
	profile.hourly_peak_ratio.resize(hours_to_assign)
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var neighbors: Array = RoadGraph.adjacency(region)
	var count: int = region.neighborhoods.size()
	var can_warm_start: bool = warm_start_profile != null and warm_start_profile.hourly_volumes.size() >= hours_to_assign and warm_start_profile.hourly_volumes[0].size() == region.road_links.size()
	var assignment_passes := 2 if can_warm_start else ASSIGNMENT_PASSES
	for hour in range(hours_to_assign):
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
			var routes: Dictionary = RoadGraph.route_pairs(region, costs, neighbors)
			var assigned := PackedVector2Array()
			assigned.resize(region.road_links.size())
			for origin_id in range(count):
				for destination_id in range(count):
					var vehicles: float = demand[origin_id][destination_id]
					if vehicles <= 0.0:
						continue
					for edge in routes["paths"][origin_id][destination_id]:
						var value: Vector2 = assigned[edge.x]
						if edge.y == 0:
							value.x += vehicles
						else:
							value.y += vehicles
						assigned[edge.x] = value
			var weight := 1.0 / float(iteration + 1)
			for link_index in range(volumes.size()):
				volumes[link_index] = volumes[link_index].lerp(assigned[link_index], weight)
		var final_costs: PackedVector2Array = _congested_costs(region, free_costs, volumes)
		var final_routes: Dictionary = RoadGraph.route_pairs(region, final_costs, neighbors)
		var peak_ratio := 0.0
		for link_index in range(volumes.size()):
			var capacity: float = RoadGraph.capacity_per_lane(region.road_links[link_index].road_class) * region.road_links[link_index].lanes_per_direction
			peak_ratio = maxf(peak_ratio, maxf(volumes[link_index].x, volumes[link_index].y) / capacity)
		profile.hourly_volumes.append(volumes)
		profile.hourly_link_times.append(final_costs)
		profile.hourly_pair_times.append(final_routes["times"])
		profile.hourly_peak_ratio[hour] = peak_ratio
	return profile


static func generalized_travel_times(region, flow_profile, traffic_profile) -> Array[PackedFloat32Array]:
	var count: int = region.neighborhoods.size()
	var free_times: Array = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region))["times"]
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
