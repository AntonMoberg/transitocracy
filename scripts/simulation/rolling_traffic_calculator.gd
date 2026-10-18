extends RefCounted

const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadTrafficProfile = preload("res://scripts/simulation/road_traffic_profile.gd")
const RollingTrafficState = preload("res://scripts/simulation/rolling_traffic_state.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const LocalStreetTraffic = preload("res://scripts/simulation/local_street_traffic.gd")

const BINS_PER_HOUR = 4
const BINS_PER_DAY = 96
const DOLLARS_PER_MINUTE = 0.40
const CAR_FEE_SENSITIVITY = 10.0
const COARSE_CAR_THRESHOLD = 0.5


static func new_day(region, flow_profile, previous_state = null, replan_paths: bool = false):
	var state = RollingTrafficState.new()
	state.day_key = flow_profile.active_day_key
	state.profile = RoadTrafficProfile.new()
	state.profile.active_day_key = state.day_key
	state.profile.recorded_bin = 0
	var link_count: int = region.road_links.size()
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for link in region.road_links:
		state.link_ids.append(link.id)
		state.profile.link_ids.append(link.id)
		state.queues.append([])
		state.queues.append([])
	if previous_state != null:
		var index_by_id: Dictionary = {}
		for index in range(link_count):
			index_by_id[state.link_ids[index]] = index
		for old_index in range(previous_state.link_ids.size()):
			if index_by_id.has(previous_state.link_ids[old_index]):
				var new_index: int = index_by_id[previous_state.link_ids[old_index]]
				state.queues[new_index * 2] = previous_state.queues[old_index * 2].duplicate(true)
				state.queues[new_index * 2 + 1] = previous_state.queues[old_index * 2 + 1].duplicate(true)
		state.scheduled = previous_state.scheduled.duplicate(true)
		state.departed_cars = previous_state.departed_cars
		state.completed_cars = previous_state.completed_cars
		state.stranded = previous_state.stranded.duplicate(true)
	if replan_paths:
		var old_queues: Array = previous_state.queues.duplicate(true)
		var old_scheduled: Dictionary = state.scheduled.duplicate(true)
		var old_stranded: Array = state.stranded.duplicate(true)
		for lane_index in range(state.queues.size()):
			state.queues[lane_index] = []
		state.scheduled.clear()
		state.stranded.clear()
		var path_cache: Dictionary = {}
		var replan_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
		for lane in old_queues:
			for cohort in lane:
				var rerouted: Dictionary = _repath_cohort(region, cohort, replan_costs, path_cache)
				if rerouted["path"].is_empty():
					state.stranded.append(rerouted)
				else:
					var edge: Vector2i = rerouted["path"][0]
					state.queues[edge.x * 2 + edge.y].append(rerouted)
		for cohort in old_stranded:
			var rerouted: Dictionary = _repath_cohort(region, cohort, replan_costs, path_cache)
			if rerouted["path"].is_empty():
				state.stranded.append(rerouted)
			else:
				var edge: Vector2i = rerouted["path"][0]
				state.queues[edge.x * 2 + edge.y].append(rerouted)
		for tick in old_scheduled:
			for cohort in old_scheduled[tick]:
				var rerouted: Dictionary = _repath_cohort(region, cohort, replan_costs, path_cache)
				if rerouted["path"].is_empty() and int(rerouted["current_node_id"]) != region.neighborhood_gateway_node_ids[int(rerouted["destination_id"])]:
					state.stranded.append(rerouted)
				else:
					if not state.scheduled.has(tick):
						state.scheduled[tick] = []
					state.scheduled[tick].append(rerouted)
	var initial_queues := PackedVector2Array()
	initial_queues.resize(link_count)
	for index in range(link_count):
		initial_queues[index] = Vector2(_queue_total(state.queues[index * 2]), _queue_total(state.queues[index * 2 + 1]))
	state.profile.initial_queues = initial_queues
	state.profile.end_queues = initial_queues.duplicate()
	state.profile.hourly_peak_ratio.resize(24)
	state.profile.hourly_assignment_gap.resize(24)
	for _hour in range(24):
		state.profile.hourly_volumes.append(_empty_vectors(link_count))
		state.profile.hourly_served.append(_empty_vectors(link_count))
		state.profile.hourly_link_times.append(free_costs.duplicate())
		state.profile.hourly_pair_times.append(region.travel_times.duplicate(true))
	for _bin in range(BINS_PER_DAY):
		state.profile.quarter_hour_queues.append(_empty_vectors(link_count))
		state.profile.quarter_hour_served.append(_empty_vectors(link_count))
		state.profile.quarter_hour_link_times.append(free_costs.duplicate())
	LocalStreetTraffic.prepare(region, state, previous_state, state.day_key * 86400)
	state.checkpoints[0] = {
		"local_districts": LocalStreetTraffic.copy_districts(state.local_districts),
		"local_clock": state.local_clock,
		"next_bin": 0,
		"queues": state.queues.duplicate(true),
		"scheduled": state.scheduled.duplicate(true),
		"stranded": state.stranded.duplicate(true),
		"departed_cars": state.departed_cars,
		"completed_cars": state.completed_cars,
		"hourly_volumes": state.profile.hourly_volumes.duplicate(true),
		"hourly_served": state.profile.hourly_served.duplicate(true),
		"hourly_link_times": state.profile.hourly_link_times.duplicate(true),
		"hourly_peak_ratio": state.profile.hourly_peak_ratio.duplicate(),
	}
	return state


static func advance_chunk(region, flow_profile, state, target_bin: int):
	while state.next_bin < mini(BINS_PER_DAY, target_bin):
		step_bin(region, flow_profile, state)
	return state


static func advance_chunk_with_fork(region, flow_profile, state, target_bin: int) -> Dictionary:
	advance_chunk(region, flow_profile, state, target_bin)
	return {"state": state, "next": fork_for_worker(state) if state.next_bin < BINS_PER_DAY else null}


# Fork only mutable traffic data before a worker takes ownership. Completed
# checkpoint payloads and OD route paths are immutable; copying them recursively
# on the UI thread was hundreds of milliseconds per eight-bin chunk.
static func fork_for_worker(state):
	var fork = RollingTrafficState.new()
	fork.local_districts = LocalStreetTraffic.copy_districts(state.local_districts)
	fork.local_clock = state.local_clock
	fork.day_key = state.day_key
	fork.next_bin = state.next_bin
	fork.first_recorded_bin = state.first_recorded_bin
	fork.link_ids = state.link_ids.duplicate()
	# Cohort dictionaries and their paths are read only during a traffic chunk.
	# Give the worker separate queue and arrival containers so appends and erases
	# cannot touch the visible checkpoint, without cloning every in-flight car.
	for lane in state.queues:
		fork.queues.append(lane.duplicate())
	for tick in state.scheduled:
		fork.scheduled[tick] = state.scheduled[tick].duplicate()
	fork.stranded = state.stranded.duplicate()
	fork.revenue_by_bin = state.revenue_by_bin.duplicate()
	fork.checkpoints = state.checkpoints.duplicate()
	fork.route_hour = state.route_hour
	fork.route_paths = state.route_paths.duplicate()
	fork.departure_templates = state.departure_templates.duplicate()
	fork.noncar_sales = state.noncar_sales.duplicate()
	fork.departed_cars = state.departed_cars
	fork.completed_cars = state.completed_cars
	var source_profile = state.profile
	var profile = RoadTrafficProfile.new()
	profile.active_day_key = source_profile.active_day_key
	profile.first_recorded_bin = source_profile.first_recorded_bin
	profile.recorded_bin = source_profile.recorded_bin
	profile.link_ids = source_profile.link_ids.duplicate()
	profile.hourly_volumes = source_profile.hourly_volumes.duplicate(true)
	profile.hourly_served = source_profile.hourly_served.duplicate(true)
	profile.hourly_link_times = source_profile.hourly_link_times.duplicate(true)
	profile.hourly_pair_times = source_profile.hourly_pair_times.duplicate()
	profile.hourly_peak_ratio = source_profile.hourly_peak_ratio.duplicate()
	profile.hourly_assignment_gap = source_profile.hourly_assignment_gap.duplicate()
	profile.initial_queues = source_profile.initial_queues.duplicate()
	profile.end_queues = source_profile.end_queues.duplicate()
	profile.quarter_hour_queues = source_profile.quarter_hour_queues.duplicate()
	profile.quarter_hour_served = source_profile.quarter_hour_served.duplicate()
	profile.quarter_hour_link_times = source_profile.quarter_hour_link_times.duplicate()
	fork.profile = profile
	return fork


static func start_at_bin(state, bin_index: int) -> void:
	state.next_bin = clampi(bin_index, 0, BINS_PER_DAY - 1)
	state.first_recorded_bin = state.next_bin
	state.profile.first_recorded_bin = state.next_bin
	state.profile.recorded_bin = state.next_bin
	state.local_clock = state.day_key * 86400 + state.next_bin * 900
	state.checkpoints[state.next_bin] = state.checkpoints[0]
	state.checkpoints[state.next_bin]["next_bin"] = state.next_bin
	state.checkpoints[state.next_bin]["local_clock"] = state.local_clock
	state.checkpoints.erase(0)


static func step_bin(region, flow_profile, state) -> void:
	var bin_index: int = state.next_bin
	if bin_index >= BINS_PER_DAY:
		return
	var hour: int = bin_index / BINS_PER_HOUR
	var absolute_tick: int = state.day_key * BINS_PER_DAY + bin_index
	if FiscalCalculator.apply_due_policies(region, absolute_tick * 900):
		state.route_hour = -1
	if state.route_hour != hour:
		var costs: PackedVector2Array = _route_costs(region, state, hour)
		state.route_paths = RoadGraph.route_pairs(region, costs, [], true)["paths"]
		state.route_hour = hour
		_build_departure_templates(region, flow_profile, state, hour)
	var arriving: Array = state.scheduled.get(absolute_tick, [])
	state.scheduled.erase(absolute_tick)
	for cohort in arriving:
		if int(cohort["step_index"]) >= cohort["path"].size():
			_complete(region, state, bin_index, cohort)
		else:
			_enqueue(state, cohort, bin_index)
	_add_departures(region, flow_profile, state, bin_index, hour)
	var queued_snapshot := PackedVector2Array()
	var served_snapshot := PackedVector2Array()
	var time_snapshot := PackedVector2Array()
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for link_index in range(region.road_links.size()):
		var link = region.road_links[link_index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction / BINS_PER_HOUR
		var served_forward: float = _serve_lane(region, state, bin_index, absolute_tick, link_index, 0, capacity, free_costs[link_index].x)
		var served_reverse: float = _serve_lane(region, state, bin_index, absolute_tick, link_index, 1, capacity, free_costs[link_index].y)
		var forward_queue: float = _queue_total(state.queues[link_index * 2])
		var reverse_queue: float = _queue_total(state.queues[link_index * 2 + 1])
		queued_snapshot.append(Vector2(forward_queue, reverse_queue))
		served_snapshot.append(Vector2(served_forward, served_reverse))
		var times := Vector2(free_costs[link_index].x + 15.0 * forward_queue / maxf(1.0, capacity), free_costs[link_index].y + 15.0 * reverse_queue / maxf(1.0, capacity))
		time_snapshot.append(times)
		state.profile.hourly_served[hour][link_index] += Vector2(served_forward, served_reverse)
		var previous_mean: Vector2 = state.profile.hourly_link_times[hour][link_index]
		var steps_so_far: int = bin_index % BINS_PER_HOUR
		state.profile.hourly_link_times[hour][link_index] = (previous_mean * float(steps_so_far) + times) / float(steps_so_far + 1)
		state.profile.hourly_peak_ratio[hour] = maxf(state.profile.hourly_peak_ratio[hour], maxf(served_forward, served_reverse) / maxf(1.0, capacity))
	state.profile.quarter_hour_queues[bin_index] = queued_snapshot
	state.profile.quarter_hour_served[bin_index] = served_snapshot
	state.profile.quarter_hour_link_times[bin_index] = time_snapshot
	state.profile.end_queues = queued_snapshot.duplicate()
	if bin_index % BINS_PER_HOUR == BINS_PER_HOUR - 1:
		state.profile.hourly_pair_times[hour] = RoadGraph.route_pairs(region, state.profile.hourly_link_times[hour], [], false)["times"]
	state.next_bin += 1
	state.profile.recorded_bin = state.next_bin
	LocalStreetTraffic.advance_to(region, flow_profile, state, state.day_key * 86400 + state.next_bin * 900)
	state.checkpoints[state.next_bin] = {
		"local_districts": LocalStreetTraffic.copy_districts(state.local_districts),
		"local_clock": state.local_clock,
		"next_bin": state.next_bin,
		"queues": _copy_queue_containers(state.queues),
		"scheduled": _copy_scheduled_containers(state.scheduled),
		"stranded": state.stranded.duplicate(),
		"departed_cars": state.departed_cars,
		"completed_cars": state.completed_cars,
		"hourly_volumes": state.profile.hourly_volumes.duplicate(true),
		"hourly_served": state.profile.hourly_served.duplicate(true),
		"hourly_link_times": state.profile.hourly_link_times.duplicate(true),
		"hourly_peak_ratio": state.profile.hourly_peak_ratio.duplicate(),
	}


static func restore_checkpoint(region, state, checkpoint: Dictionary) -> void:
	state.local_districts = LocalStreetTraffic.copy_districts(checkpoint["local_districts"])
	state.local_clock = checkpoint["local_clock"]
	state.next_bin = checkpoint["next_bin"]
	state.profile.recorded_bin = state.next_bin
	state.queues = checkpoint["queues"].duplicate(true)
	state.scheduled = checkpoint["scheduled"].duplicate(true)
	state.stranded = checkpoint["stranded"].duplicate(true)
	state.departed_cars = checkpoint["departed_cars"]
	state.completed_cars = checkpoint["completed_cars"]
	state.route_hour = -1
	state.route_paths.clear()
	state.departure_templates.clear()
	state.noncar_sales.clear()
	state.profile.hourly_volumes = checkpoint["hourly_volumes"].duplicate(true)
	state.profile.hourly_served = checkpoint["hourly_served"].duplicate(true)
	state.profile.hourly_link_times = checkpoint["hourly_link_times"].duplicate(true)
	state.profile.hourly_peak_ratio = checkpoint["hourly_peak_ratio"].duplicate()
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for bin_index in range(state.next_bin, BINS_PER_DAY):
		state.profile.quarter_hour_queues[bin_index] = _empty_vectors(region.road_links.size())
		state.profile.quarter_hour_served[bin_index] = _empty_vectors(region.road_links.size())
		state.profile.quarter_hour_link_times[bin_index] = free_costs.duplicate()
		state.revenue_by_bin.erase(bin_index)
		state.checkpoints.erase(bin_index + 1)
	for hour in range(state.next_bin / BINS_PER_HOUR, 24):
		state.profile.hourly_pair_times[hour] = region.travel_times.duplicate(true)
	state.profile.end_queues.resize(region.road_links.size())
	for index in range(region.road_links.size()):
		state.profile.end_queues[index] = Vector2(_queue_total(state.queues[index * 2]), _queue_total(state.queues[index * 2 + 1]))


static func after_network_edit(region, flow_profile, old_state, checkpoint: Dictionary):
	var state = new_day(region, flow_profile)
	state.local_districts = LocalStreetTraffic.copy_districts(checkpoint["local_districts"])
	LocalStreetTraffic.prepare(region, state, state, checkpoint["local_clock"])
	var start_bin: int = checkpoint["next_bin"]
	state.next_bin = start_bin
	state.first_recorded_bin = old_state.first_recorded_bin
	state.profile.first_recorded_bin = state.first_recorded_bin
	state.profile.recorded_bin = start_bin
	state.departed_cars = checkpoint["departed_cars"]
	state.completed_cars = checkpoint["completed_cars"]
	state.revenue_by_bin = old_state.revenue_by_bin.duplicate(true)
	for bin_index in range(start_bin, BINS_PER_DAY):
		state.revenue_by_bin.erase(bin_index)
	var index_by_id: Dictionary = {}
	for index in range(state.link_ids.size()):
		index_by_id[state.link_ids[index]] = index
	for old_index in range(old_state.link_ids.size()):
		if not index_by_id.has(old_state.link_ids[old_index]):
			continue
		var new_index: int = index_by_id[old_state.link_ids[old_index]]
		for hour in range((start_bin + 3) / BINS_PER_HOUR):
			state.profile.hourly_volumes[hour][new_index] = checkpoint["hourly_volumes"][hour][old_index]
			state.profile.hourly_served[hour][new_index] = checkpoint["hourly_served"][hour][old_index]
			state.profile.hourly_link_times[hour][new_index] = checkpoint["hourly_link_times"][hour][old_index]
		for bin_index in range(start_bin):
			state.profile.quarter_hour_queues[bin_index][new_index] = old_state.profile.quarter_hour_queues[bin_index][old_index]
			state.profile.quarter_hour_served[bin_index][new_index] = old_state.profile.quarter_hour_served[bin_index][old_index]
			state.profile.quarter_hour_link_times[bin_index][new_index] = old_state.profile.quarter_hour_link_times[bin_index][old_index]
	for hour in range(start_bin / BINS_PER_HOUR):
		state.profile.hourly_pair_times[hour] = old_state.profile.hourly_pair_times[hour]
	state.profile.hourly_peak_ratio = checkpoint["hourly_peak_ratio"].duplicate()
	var free_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var path_cache: Dictionary = {}
	for old_lane in checkpoint["queues"]:
		for cohort in old_lane:
			var rerouted: Dictionary = _repath_cohort(region, cohort, free_costs, path_cache)
			if rerouted["path"].is_empty():
				state.stranded.append(rerouted)
			else:
				var edge: Vector2i = rerouted["path"][0]
				state.queues[edge.x * 2 + edge.y].append(rerouted)
	for cohort in checkpoint["stranded"]:
		var rerouted: Dictionary = _repath_cohort(region, cohort, free_costs, path_cache)
		if rerouted["path"].is_empty():
			state.stranded.append(rerouted)
		else:
			var edge: Vector2i = rerouted["path"][0]
			state.queues[edge.x * 2 + edge.y].append(rerouted)
	for tick in checkpoint["scheduled"]:
		for cohort in checkpoint["scheduled"][tick]:
			var rerouted: Dictionary = _repath_cohort(region, cohort, free_costs, path_cache)
			if rerouted["path"].is_empty() and int(rerouted["current_node_id"]) != region.neighborhood_gateway_node_ids[int(rerouted["destination_id"])]:
				state.stranded.append(rerouted)
				continue
			if not state.scheduled.has(tick):
				state.scheduled[tick] = []
			state.scheduled[tick].append(rerouted)
	for index in range(region.road_links.size()):
		state.profile.end_queues[index] = Vector2(_queue_total(state.queues[index * 2]), _queue_total(state.queues[index * 2 + 1]))
	state.checkpoints.clear()
	state.checkpoints[start_bin] = {
		"local_districts": LocalStreetTraffic.copy_districts(state.local_districts), "local_clock": state.local_clock,
		"next_bin": start_bin, "queues": state.queues.duplicate(true), "scheduled": state.scheduled.duplicate(true), "stranded": state.stranded.duplicate(true),
		"departed_cars": state.departed_cars, "completed_cars": state.completed_cars,
		"hourly_volumes": state.profile.hourly_volumes.duplicate(true), "hourly_served": state.profile.hourly_served.duplicate(true),
		"hourly_link_times": state.profile.hourly_link_times.duplicate(true), "hourly_peak_ratio": state.profile.hourly_peak_ratio.duplicate(),
	}
	return state


static func _repath_cohort(region, cohort: Dictionary, costs: PackedVector2Array, path_cache: Dictionary) -> Dictionary:
	var rerouted: Dictionary = cohort.duplicate(true)
	var source_node: int = int(cohort["current_node_id"])
	var destination_node: int = region.neighborhood_gateway_node_ids[int(cohort["destination_id"])]
	var key: Vector2i = Vector2i(source_node, destination_node)
	if not path_cache.has(key):
		path_cache[key] = RoadGraph.route_from_node(region, costs, source_node, destination_node)
	rerouted["path"] = path_cache[key]
	rerouted["step_index"] = 0
	return rerouted


static func _add_departures(region, flow_profile, state, bin_index: int, hour: int) -> void:
	for area_id in state.noncar_sales:
		_credit(state, bin_index, int(area_id), "sales", float(state.noncar_sales[area_id]) / BINS_PER_HOUR)
	for template in state.departure_templates:
		var cohort: Dictionary = template.duplicate()
		cohort["count"] = float(template["count"]) / BINS_PER_HOUR
		state.departed_cars += float(cohort["count"])
		_enqueue(state, cohort, bin_index)


static func _build_departure_templates(region, flow_profile, state, hour: int, parallel_legs: bool = true) -> void:
	state.departure_templates.clear()
	state.noncar_sales.clear()
	var city_representatives: Array[int] = []
	for city in region.cities:
		city_representatives.append(city["neighborhood_ids"][0])
	var leg_groups: Array = [
		[flow_profile.hourly_work_outbound_od[hour], "Work", true],
		[flow_profile.hourly_work_return_od[hour], "Work", false],
		[flow_profile.hourly_shopping_outbound_od[hour], "Commercial", true],
		[flow_profile.hourly_shopping_return_od[hour], "Commercial", false],
		[flow_profile.hourly_social_outbound_od[hour], "Social", true],
		[flow_profile.hourly_social_return_od[hour], "Social", false],
	]
	var results: Array = []
	results.resize(leg_groups.size())
	if parallel_legs and OS.get_processor_count() > 1:
		var workers: int = mini(leg_groups.size(), OS.get_processor_count())
		var task_id: int = WorkerThreadPool.add_group_task(
			func(group_index: int) -> void:
				results[group_index] = _build_leg_templates(region, state.route_paths, leg_groups[group_index], hour, city_representatives),
			leg_groups.size(), workers, false, "Traffic departure templates")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for group_index in range(leg_groups.size()):
			results[group_index] = _build_leg_templates(region, state.route_paths, leg_groups[group_index], hour, city_representatives)
	for result in results:
		state.departure_templates.append_array(result["templates"])
		for area_id in result["noncar_sales"]:
			state.noncar_sales[area_id] = float(state.noncar_sales.get(area_id, 0.0)) + float(result["noncar_sales"][area_id])
	for result in results:
		for bucket in result["coarse_buckets"].values():
			bucket["credit_base_count"] = bucket["count"]
			state.departure_templates.append(bucket)


static func _build_leg_templates(region, route_paths: Array, group: Array, hour: int, city_representatives: Array[int]) -> Dictionary:
	var matrix: Array = group[0]
	var purpose: String = group[1]
	var outbound: bool = group[2]
	var templates: Array = []
	var coarse_buckets: Dictionary = {}
	var noncar_sales: Dictionary = {}
	for origin_id in range(region.neighborhoods.size()):
		for destination_id in range(region.neighborhoods.size()):
			var trips: float = matrix[origin_id][destination_id]
			if trips <= 0.00001:
				continue
			var home_id: int = origin_id if outbound else destination_id
			if origin_id == destination_id:
				if purpose == "Commercial" and outbound:
					_accumulate_noncar_sales(region, noncar_sales, origin_id, destination_id, trips)
				continue
			var origin_city: int = region.neighborhoods[origin_id].city_id
			var destination_city: int = region.neighborhoods[destination_id].city_id
			var coarse: bool = origin_city != destination_city and trips * 0.9 / BINS_PER_HOUR < COARSE_CAR_THRESHOLD
			var path: Array = route_paths[city_representatives[origin_city]][city_representatives[destination_city]] if coarse else route_paths[origin_id][destination_id]
			if path.is_empty():
				continue
			var distance: float = region.neighborhoods[origin_id].position_km.distance_to(region.neighborhoods[destination_id].position_km)
			var base_share: float = clampf(0.20 + 0.035 * distance, 0.20, 0.90)
			var fee: float = _journey_fee(region, path, destination_id, home_id, hour)
			var odds: float = base_share / (1.0 - base_share) * exp(-fee / CAR_FEE_SENSITIVITY)
			var car_share: float = odds / (1.0 + odds)
			var cars: float = trips * car_share / (1.2 if purpose == "Work" else (1.5 if purpose == "Commercial" else 1.8))
			if purpose == "Commercial" and outbound:
				_accumulate_noncar_sales(region, noncar_sales, origin_id, destination_id, trips * (1.0 - car_share))
			if cars <= 0.00001:
				continue
			if coarse:
				var key: String = "%d:%d:%s:%s" % [origin_city, destination_city, purpose, str(outbound)]
				if not coarse_buckets.has(key):
					coarse_buckets[key] = {"origin_id": city_representatives[origin_city], "destination_id": city_representatives[destination_city], "home_id": -1, "purpose": purpose, "outbound": outbound, "count": 0.0, "path": path, "step_index": 0, "bucket": true, "parking_credits": {}, "sales_credits": {}, "current_node_id": region.neighborhood_gateway_node_ids[city_representatives[origin_city]]}
				var bucket: Dictionary = coarse_buckets[key]
				bucket["count"] += cars
				if outbound:
					var city = region.jurisdiction_for_neighborhood(destination_id, "City")
					var district = region.jurisdiction_for_neighborhood(destination_id, "Neighborhood")
					bucket["parking_credits"][city.id] = float(bucket["parking_credits"].get(city.id, 0.0)) + cars * city.parking_fee
					bucket["parking_credits"][district.id] = float(bucket["parking_credits"].get(district.id, 0.0)) + cars * district.parking_fee
				if purpose == "Commercial" and outbound:
					var county = region.jurisdiction_for_neighborhood(destination_id, "County")
					bucket["sales_credits"][county.id] = float(bucket["sales_credits"].get(county.id, 0.0)) + trips * car_share * FiscalCalculator.shopping_spend(region, origin_id) * county.sales_tax_rate
				continue
			var cohort := {"origin_id": origin_id, "destination_id": destination_id, "home_id": home_id, "purpose": purpose, "outbound": outbound, "count": cars, "visits_per_car": trips * car_share / cars, "path": path, "step_index": 0, "current_node_id": region.neighborhood_gateway_node_ids[origin_id]}
			templates.append(cohort)
	return {"templates": templates, "coarse_buckets": coarse_buckets, "noncar_sales": noncar_sales}


static func _accumulate_noncar_sales(region, sales: Dictionary, origin_id: int, destination_id: int, visits: float) -> void:
	var county = region.jurisdiction_for_neighborhood(destination_id, "County")
	sales[county.id] = float(sales.get(county.id, 0.0)) + visits * FiscalCalculator.shopping_spend(region, origin_id) * county.sales_tax_rate


static func _enqueue(state, cohort: Dictionary, bin_index: int) -> void:
	var edge: Vector2i = cohort["path"][cohort["step_index"]]
	state.queues[edge.x * 2 + edge.y].append(cohort)
	var current: Vector2 = state.profile.hourly_volumes[bin_index / BINS_PER_HOUR][edge.x]
	if edge.y == 0:
		current.x += float(cohort["count"])
	else:
		current.y += float(cohort["count"])
	state.profile.hourly_volumes[bin_index / BINS_PER_HOUR][edge.x] = current


static func _serve_lane(region, state, bin_index: int, absolute_tick: int, link_index: int, direction: int, capacity: float, free_minutes: float) -> float:
	var lane_index: int = link_index * 2 + direction
	var queue: Array = state.queues[lane_index]
	var served_total := 0.0
	var remaining: Array = []
	for cohort in queue:
		var count: float = float(cohort["count"])
		var served: float = minf(count, maxf(0.0, capacity - served_total))
		if served > 0.0:
			var moving: Dictionary = cohort.duplicate()
			moving["count"] = served
			moving["step_index"] = int(cohort["step_index"]) + 1
			var delay_bins: int = maxi(1, ceili(free_minutes / 15.0))
			var arrival_tick: int = absolute_tick + delay_bins
			if not state.scheduled.has(arrival_tick):
				state.scheduled[arrival_tick] = []
			state.scheduled[arrival_tick].append(moving)
			var link = region.road_links[link_index]
			moving["current_node_id"] = link.to_node_id if direction == 0 else link.from_node_id
			_credit(state, bin_index, link.owner_jurisdiction_id, "fee", served * (link.toll_forward if direction == 0 else link.toll_reverse))
			var from_city: int = _node_city(region, link.from_node_id if direction == 0 else link.to_node_id)
			var to_city: int = _node_city(region, link.to_node_id if direction == 0 else link.from_node_id)
			if from_city != to_city:
				var city = region.jurisdictions[region.city_jurisdiction_ids[to_city]]
				if city.is_congestion_hour(bin_index / BINS_PER_HOUR):
					_credit(state, bin_index, city.id, "fee", served * city.congestion_fee)
			served_total += served
		if count - served > 0.000001:
			var waiting: Dictionary = cohort.duplicate()
			waiting["count"] = count - served
			remaining.append(waiting)
	state.queues[lane_index] = remaining
	return served_total


static func _complete(region, state, bin_index: int, cohort: Dictionary) -> void:
	var cars: float = cohort["count"]
	state.completed_cars += cars
	if cohort.get("bucket", false):
		var fraction: float = cars / maxf(0.000001, float(cohort["credit_base_count"]))
		for area_id in cohort["parking_credits"]:
			_credit(state, bin_index, int(area_id), "fee", float(cohort["parking_credits"][area_id]) * fraction)
		for area_id in cohort["sales_credits"]:
			_credit(state, bin_index, int(area_id), "sales", float(cohort["sales_credits"][area_id]) * fraction)
		return
	var destination_id: int = cohort["destination_id"]
	if destination_id != int(cohort["home_id"]):
		var city = region.jurisdiction_for_neighborhood(destination_id, "City")
		var district = region.jurisdiction_for_neighborhood(destination_id, "Neighborhood")
		_credit(state, bin_index, city.id, "fee", cars * city.parking_fee)
		_credit(state, bin_index, district.id, "fee", cars * district.parking_fee)
	if cohort["purpose"] == "Commercial" and cohort["outbound"]:
		_credit_sales(region, state, bin_index, cohort["origin_id"], destination_id, cars * float(cohort["visits_per_car"]))


static func _credit_sales(region, state, bin_index: int, origin_id: int, destination_id: int, visits: float) -> void:
	var county = region.jurisdiction_for_neighborhood(destination_id, "County")
	_credit(state, bin_index, county.id, "sales", visits * FiscalCalculator.shopping_spend(region, origin_id) * county.sales_tax_rate)


static func _credit(state, bin_index: int, area_id: int, category: String, amount: float) -> void:
	if amount <= 0.0:
		return
	if not state.revenue_by_bin.has(bin_index):
		state.revenue_by_bin[bin_index] = {}
	if not state.revenue_by_bin[bin_index].has(area_id):
		state.revenue_by_bin[bin_index][area_id] = {"sales": 0.0, "fee": 0.0}
	state.revenue_by_bin[bin_index][area_id][category] += amount


static func _route_costs(region, state, hour: int) -> PackedVector2Array:
	var costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var costs_for_link: Vector2 = costs[index]
		costs_for_link.x += link.toll_forward / DOLLARS_PER_MINUTE
		costs_for_link.y += link.toll_reverse / DOLLARS_PER_MINUTE
		var from_city: int = _node_city(region, link.from_node_id)
		var to_city: int = _node_city(region, link.to_node_id)
		if from_city != to_city:
			var forward_city = region.jurisdictions[region.city_jurisdiction_ids[to_city]]
			var reverse_city = region.jurisdictions[region.city_jurisdiction_ids[from_city]]
			if forward_city.is_congestion_hour(hour):
				costs_for_link.x += forward_city.congestion_fee / DOLLARS_PER_MINUTE
			if reverse_city.is_congestion_hour(hour):
				costs_for_link.y += reverse_city.congestion_fee / DOLLARS_PER_MINUTE
		var queue: Vector2 = state.profile.end_queues[index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		costs_for_link += Vector2(15.0 * queue.x / maxf(1.0, capacity), 15.0 * queue.y / maxf(1.0, capacity))
		costs[index] = costs_for_link
	return costs


static func _journey_fee(region, path: Array, destination_id: int, home_id: int, hour: int) -> float:
	var fee := 0.0
	for edge in path:
		var link = region.road_links[edge.x]
		fee += link.toll_forward if edge.y == 0 else link.toll_reverse
		var from_city: int = _node_city(region, link.from_node_id if edge.y == 0 else link.to_node_id)
		var to_city: int = _node_city(region, link.to_node_id if edge.y == 0 else link.from_node_id)
		if from_city != to_city:
			var city = region.jurisdictions[region.city_jurisdiction_ids[to_city]]
			if city.is_congestion_hour(hour):
				fee += city.congestion_fee
	if destination_id != home_id:
		fee += region.jurisdiction_for_neighborhood(destination_id, "City").parking_fee
		fee += region.jurisdiction_for_neighborhood(destination_id, "Neighborhood").parking_fee
	return fee


static func _node_city(region, node_id: int) -> int:
	var node = region.road_nodes[node_id]
	return node.city_id if node.city_id >= 0 else region.neighborhoods[region.nearest_neighborhood_id(node.position_km)].city_id


static func _queue_total(cohorts: Array) -> float:
	var total := 0.0
	for cohort in cohorts:
		total += float(cohort["count"])
	return total


static func _copy_queue_containers(queues: Array) -> Array:
	var copied: Array = []
	for lane in queues:
		copied.append(lane.duplicate())
	return copied


static func _copy_scheduled_containers(scheduled: Dictionary) -> Dictionary:
	var copied: Dictionary = {}
	for tick in scheduled:
		copied[tick] = scheduled[tick].duplicate()
	return copied


static func _empty_vectors(count: int) -> PackedVector2Array:
	var values := PackedVector2Array()
	values.resize(count)
	return values
