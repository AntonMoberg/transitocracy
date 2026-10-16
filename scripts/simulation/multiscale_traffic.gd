extends RefCounted

const State = preload("res://scripts/simulation/multiscale_traffic_state.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadTrafficProfile = preload("res://scripts/simulation/road_traffic_profile.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")

const SECOND = 0
const MINUTE = 1
const HOUR = 2
const DAY = 3
const SECONDS_PER_DAY = 86400


static func new_day(region, flow_profile, unix_seconds: int, previous_state = null):
	var state = State.new()
	state.unix_seconds = unix_seconds
	state.day_key = unix_seconds / SECONDS_PER_DAY
	var links: int = region.road_links.size()
	state.queues.resize(links)
	state.last_arrivals.resize(links)
	state.last_served.resize(links)
	state.last_speed_kmh.resize(links)
	var previous_by_id: Dictionary = {}
	if previous_state != null:
		for index in range(previous_state.link_ids.size()):
			previous_by_id[previous_state.link_ids[index]] = previous_state.queues[index]
	for index in range(links):
		var link = region.road_links[index]
		state.link_ids.append(link.id)
		state.queues[index] = previous_by_id.get(link.id, Vector2.ZERO)
		state.last_speed_kmh[index] = Vector2(RoadGraph.free_speed_kmh(link.road_class), RoadGraph.free_speed_kmh(link.road_class))
	if previous_state != null and previous_state.link_ids == state.link_ids and not previous_state.free_pair_times.is_empty():
		state.free_pair_times = previous_state.free_pair_times
		state.paths_by_mode = previous_state.paths_by_mode.duplicate()
	else:
		var free_routes: Dictionary = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region), [], true)
		state.free_pair_times = free_routes["times"]
		state.paths_by_mode[0] = free_routes["paths"]
	_prepare_junctions(region, state)
	state.profile = _new_profile(region, state)
	_precompute_demand(region, flow_profile, state)
	state.first_recorded_bin = clampi((unix_seconds % SECONDS_PER_DAY) / 900, 0, 95)
	state.next_bin = state.first_recorded_bin + 1
	state.profile.first_recorded_bin = state.first_recorded_bin
	state.profile.recorded_bin = state.next_bin
	return state


static func _prepare_junctions(region, state) -> void:
	state.junction_capacity_hr.resize(region.road_nodes.size())
	var approaches := PackedInt32Array()
	approaches.resize(region.road_nodes.size())
	for link in region.road_links:
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		state.junction_capacity_hr[link.from_node_id] += capacity
		state.junction_capacity_hr[link.to_node_id] += capacity
		approaches[link.from_node_id] += 1
		approaches[link.to_node_id] += 1
	for node_index in range(region.road_nodes.size()):
		if approaches[node_index] >= 3 and not region.road_nodes[node_index].is_interchange:
			state.junction_capacity_hr[node_index] *= 0.75


static func _new_profile(region, state):
	var profile = RoadTrafficProfile.new()
	profile.active_day_key = state.day_key
	profile.link_ids = state.link_ids.duplicate()
	profile.initial_queues = state.queues.duplicate()
	profile.end_queues = state.queues.duplicate()
	var empty := PackedVector2Array()
	empty.resize(state.link_ids.size())
	var free: PackedVector2Array = RoadGraph.free_flow_costs(region)
	profile.hourly_peak_ratio.resize(24)
	profile.hourly_assignment_gap.resize(24)
	for hour in range(24):
		profile.hourly_volumes.append(empty.duplicate())
		profile.hourly_served.append(empty.duplicate())
		profile.hourly_link_times.append(free.duplicate())
		profile.hourly_pair_times.append(state.free_pair_times)
	for bin_index in range(96):
		profile.quarter_hour_queues.append(state.queues.duplicate())
		profile.quarter_hour_served.append(empty.duplicate())
		profile.quarter_hour_link_times.append(free.duplicate())
	return profile


static func fork_for_day(state):
	# The worker reads a detached traffic snapshot while the UI remains free to
	# change mode or queue a policy at the day boundary.
	var fork = State.new()
	fork.link_ids = state.link_ids.duplicate()
	fork.queues = state.queues.duplicate()
	fork.free_pair_times = state.free_pair_times
	fork.paths_by_mode = state.paths_by_mode.duplicate()
	fork.profile = RoadTrafficProfile.new()
	fork.profile.hourly_pair_times = state.profile.hourly_pair_times.duplicate(true)
	return fork


static func fork_for_week(state):
	# Daily playback and the week producer advance independently. OD demand,
	# routes, and completed pair-time rows are immutable and can be shared.
	var fork = State.new()
	fork.unix_seconds = state.unix_seconds
	fork.day_key = state.day_key
	fork.next_bin = state.next_bin
	fork.first_recorded_bin = state.first_recorded_bin
	fork.link_ids = state.link_ids.duplicate()
	fork.queues = state.queues.duplicate()
	fork.last_arrivals = state.last_arrivals.duplicate()
	fork.last_served = state.last_served.duplicate()
	fork.last_speed_kmh = state.last_speed_kmh.duplicate()
	fork.cached_hour = state.cached_hour
	fork.cached_mode = state.cached_mode
	fork.cached_links = state.cached_links.duplicate()
	fork.cached_revenue = state.cached_revenue.duplicate(true)
	fork.paths_by_mode = state.paths_by_mode.duplicate()
	fork.free_pair_times = state.free_pair_times
	fork.junction_capacity_hr = state.junction_capacity_hr
	fork.hourly_demand = state.hourly_demand.duplicate()
	fork.hourly_fiscal_base = state.hourly_fiscal_base.duplicate()
	fork.departed_trips = state.departed_trips
	fork.served_cars = state.served_cars
	fork.estimated = state.estimated
	var profile = RoadTrafficProfile.new()
	var old = state.profile
	profile.active_day_key = old.active_day_key
	profile.first_recorded_bin = old.first_recorded_bin
	profile.recorded_bin = old.recorded_bin
	profile.link_ids = old.link_ids.duplicate()
	profile.hourly_volumes = old.hourly_volumes.duplicate()
	profile.hourly_link_times = old.hourly_link_times.duplicate()
	profile.hourly_pair_times = old.hourly_pair_times.duplicate()
	profile.hourly_peak_ratio = old.hourly_peak_ratio.duplicate()
	profile.hourly_assignment_gap = old.hourly_assignment_gap.duplicate()
	profile.initial_queues = old.initial_queues.duplicate()
	profile.quarter_hour_queues = old.quarter_hour_queues.duplicate()
	for row in old.quarter_hour_served:
		profile.quarter_hour_served.append(row.duplicate())
	for row in old.quarter_hour_link_times:
		profile.quarter_hour_link_times.append(row.duplicate())
	for row in old.hourly_served:
		profile.hourly_served.append(row.duplicate())
	profile.end_queues = old.end_queues.duplicate()
	fork.profile = profile
	return fork


static func invalidate(state) -> void:
	state.cached_hour = -1
	state.paths_by_mode.clear()


static func change_mode(region, flow_profile, state, old_mode: int, new_mode: int) -> void:
	state.cached_hour = -1
	state.cached_mode = -1
	if old_mode >= HOUR and new_mode <= MINUTE:
		# Retain the number of queued cars while distributing them over the
		# currently likely local roads. This seeds detailed flow after a macro run.
		var total: float = state.queued_cars()
		_build_hour(region, flow_profile, state, new_mode, (state.unix_seconds % SECONDS_PER_DAY) / 3600)
		var weights := PackedVector2Array()
		weights.resize(state.queues.size())
		var weight_total := 0.0
		for index in range(weights.size()):
			var link = region.road_links[index]
			var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
			var volume: Vector2 = state.cached_links[index]
			var weight := Vector2(maxf(0.001, volume.x / capacity), maxf(0.001, volume.y / capacity))
			weights[index] = weight
			weight_total += weight.x + weight.y
		for index in range(weights.size()):
			state.queues[index] = weights[index] * (total / maxf(0.001, weight_total))
		state.profile.end_queues = state.queues.duplicate()
		var current_bin: int = clampi((state.unix_seconds % SECONDS_PER_DAY) / 900, 0, 95)
		state.profile.quarter_hour_queues[current_bin] = state.queues.duplicate()
	state.estimated = new_mode >= HOUR


static func advance(region, flow_profile, state, target_seconds: int, mode: int) -> void:
	var day_end: int = (state.day_key + 1) * SECONDS_PER_DAY
	while state.unix_seconds < mini(target_seconds, day_end):
		if FiscalCalculator.apply_due_policies(region, state.unix_seconds):
			invalidate(state)
		var hour: int = (state.unix_seconds % SECONDS_PER_DAY) / 3600
		if state.cached_hour != hour or state.cached_mode != mode:
			_build_hour(region, flow_profile, state, mode, hour)
		var hour_end: int = state.day_key * SECONDS_PER_DAY + (hour + 1) * 3600
		var bin_end: int = ((state.unix_seconds / 900) + 1) * 900
		var quantum: int = 1 if mode == SECOND else (60 if mode == MINUTE else 900)
		var step_end: int = mini(target_seconds, mini(day_end, mini(hour_end, mini(bin_end, state.unix_seconds + quantum))))
		if step_end <= state.unix_seconds:
			break
		_advance_links(region, flow_profile, state, hour, step_end - state.unix_seconds)
		state.unix_seconds = step_end
		state.next_bin = mini(96, (state.unix_seconds - state.day_key * SECONDS_PER_DAY) / 900 + 1)
		state.profile.recorded_bin = state.next_bin
		if state.unix_seconds == hour_end:
			_finish_hour(region, state, hour)


static func _advance_links(region, flow_profile, state, hour: int, duration: int) -> void:
	var fraction: float = float(duration) / 3600.0
	var bin_index: int = clampi((state.unix_seconds % SECONDS_PER_DAY) / 900, 0, 95)
	var queued: PackedVector2Array = state.queues
	var served_bin: PackedVector2Array = state.profile.quarter_hour_served[bin_index]
	var served_hour: PackedVector2Array = state.profile.hourly_served[hour]
	var time_bin: PackedVector2Array = state.profile.quarter_hour_link_times[bin_index]
	var free: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var provisional := PackedVector2Array()
	provisional.resize(region.road_links.size())
	var node_load := PackedFloat32Array()
	node_load.resize(region.road_nodes.size())
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		var available: Vector2 = queued[index] + state.cached_links[index] * fraction
		var limit: float = capacity * fraction
		var candidate := Vector2(minf(available.x, limit), minf(available.y, limit))
		provisional[index] = candidate
		node_load[link.to_node_id] += candidate.x
		node_load[link.from_node_id] += candidate.y
	var node_scale := PackedFloat32Array()
	node_scale.resize(region.road_nodes.size())
	for node_index in range(node_scale.size()):
		node_scale[node_index] = minf(1.0, state.junction_capacity_hr[node_index] * fraction / maxf(0.000001, node_load[node_index]))
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		var arrivals: Vector2 = state.cached_links[index] * fraction
		var candidate: Vector2 = provisional[index]
		var served := Vector2(candidate.x * node_scale[link.to_node_id], candidate.y * node_scale[link.from_node_id])
		var remaining: Vector2 = queued[index] + arrivals - served
		queued[index] = remaining
		served_bin[index] += served
		served_hour[index] += served
		state.last_arrivals[index] = arrivals / maxf(0.000001, fraction)
		state.last_served[index] = served / maxf(0.000001, fraction)
		var minutes := Vector2(free[index].x + 60.0 * remaining.x / maxf(1.0, capacity), free[index].y + 60.0 * remaining.y / maxf(1.0, capacity))
		time_bin[index] = minutes
		state.last_speed_kmh[index] = Vector2(link.length_km * 60.0 / maxf(0.01, minutes.x), link.length_km * 60.0 / maxf(0.01, minutes.y))
		state.profile.hourly_peak_ratio[hour] = maxf(state.profile.hourly_peak_ratio[hour], maxf(arrivals.x, arrivals.y) / maxf(1.0, capacity * fraction))
		var owner = region.jurisdictions[link.owner_jurisdiction_id]
		owner.daily_fee_revenue += served.x * link.toll_forward + served.y * link.toll_reverse
		var first_city: int = _node_city(region, link.from_node_id)
		var second_city: int = _node_city(region, link.to_node_id)
		if first_city != second_city:
			var forward_city = region.jurisdictions[region.city_jurisdiction_ids[second_city]]
			var reverse_city = region.jurisdictions[region.city_jurisdiction_ids[first_city]]
			if forward_city.is_congestion_hour(hour):
				forward_city.daily_fee_revenue += served.x * forward_city.congestion_fee
			if reverse_city.is_congestion_hour(hour):
				reverse_city.daily_fee_revenue += served.y * reverse_city.congestion_fee
		state.served_cars += served.x + served.y
	state.queues = queued
	state.profile.quarter_hour_queues[bin_index] = queued.duplicate()
	state.profile.quarter_hour_served[bin_index] = served_bin
	state.profile.quarter_hour_link_times[bin_index] = time_bin
	state.profile.hourly_served[hour] = served_hour
	state.profile.end_queues = queued.duplicate()
	state.departed_trips += float(flow_profile.hourly_trips[hour]) * fraction
	for area_id in state.cached_revenue:
		var revenue: Dictionary = state.cached_revenue[area_id]
		var area = region.jurisdictions[int(area_id)]
		area.daily_sales_revenue += float(revenue.get("sales", 0.0)) * fraction
		area.daily_fee_revenue += float(revenue.get("fee", 0.0)) * fraction


static func _finish_hour(region, state, hour: int) -> void:
	var time_sum := PackedVector2Array()
	time_sum.resize(state.queues.size())
	for quarter in range(4):
		var row: PackedVector2Array = state.profile.quarter_hour_link_times[hour * 4 + quarter]
		for index in range(row.size()):
			time_sum[index] += row[index] * 0.25
	state.profile.hourly_link_times[hour] = time_sum
	var mode: int = state.cached_mode
	var group_count: int = region.neighborhoods.size() if mode <= MINUTE else (region.cities.size() if mode == HOUR else region.region_ids.size())
	var representatives: Array[int] = []
	if mode <= MINUTE:
		for index in range(group_count):
			representatives.append(index)
	elif mode == HOUR:
		for city in region.cities:
			representatives.append(city["neighborhood_ids"][0])
	else:
		for area_id in region.region_ids:
			representatives.append(region.jurisdictions[area_id].neighborhood_ids[0])
	var paths: Array = state.paths_by_mode.get(0, [])
	var internal_ratio := PackedFloat32Array()
	var internal_length := PackedFloat32Array()
	internal_ratio.resize(group_count)
	internal_length.resize(group_count)
	if mode >= HOUR:
		for index in range(region.road_links.size()):
			var link = region.road_links[index]
			var from_group: int = _group_for_node(region, link.from_node_id, mode)
			if from_group != _group_for_node(region, link.to_node_id, mode):
				continue
			var free_minutes: float = link.length_km * 60.0 / RoadGraph.free_speed_kmh(link.road_class)
			internal_ratio[from_group] += link.length_km * 0.5 * (time_sum[index].x + time_sum[index].y) / maxf(0.01, free_minutes)
			internal_length[from_group] += link.length_km
	var factors: Array[PackedFloat32Array] = []
	for source_group in range(group_count):
		var factor_row := PackedFloat32Array()
		factor_row.resize(group_count)
		for target_group in range(group_count):
			if mode >= HOUR and source_group == target_group and internal_length[source_group] > 0.0:
				factor_row[target_group] = clampf(internal_ratio[source_group] / internal_length[source_group], 1.0, 4.0)
				continue
			var source_id: int = representatives[source_group]
			var target_id: int = representatives[target_group]
			var free_minutes: float = state.free_pair_times[source_id][target_id]
			var actual_minutes: float = RoadGraph.LOCAL_ACCESS_MINUTES
			if not paths.is_empty():
				for edge in paths[source_id][target_id]:
					actual_minutes += time_sum[edge.x].x if edge.y == 0 else time_sum[edge.x].y
			factor_row[target_group] = clampf(actual_minutes / maxf(0.01, free_minutes), 1.0, 4.0)
		factors.append(factor_row)
	var pair_times: Array = []
	for origin in range(region.neighborhoods.size()):
		var origin_group: int = origin if mode <= MINUTE else (region.neighborhoods[origin].city_id if mode == HOUR else region.neighborhoods[origin].region_id)
		var adjusted := PackedFloat32Array()
		adjusted.resize(region.neighborhoods.size())
		for destination in range(region.neighborhoods.size()):
			var destination_group: int = destination if mode <= MINUTE else (region.neighborhoods[destination].city_id if mode == HOUR else region.neighborhoods[destination].region_id)
			adjusted[destination] = state.free_pair_times[origin][destination] * factors[origin_group][destination_group]
		pair_times.append(adjusted)
	state.profile.hourly_pair_times[hour] = pair_times


static func _precompute_demand(region, flow_profile, state) -> void:
	var results: Array = []
	results.resize(24)
	if region.neighborhoods.size() >= 32 and OS.get_processor_count() > 1:
		var workers: int = mini(6, maxi(1, OS.get_processor_count() - 1))
		var task_id: int = WorkerThreadPool.add_group_task(
			func(hour_index: int) -> void:
				results[hour_index] = _build_hour_demand(region, flow_profile, hour_index),
			24, workers, false, "Daily trip aggregation")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for hour_index in range(24):
			results[hour_index] = _build_hour_demand(region, flow_profile, hour_index)
	state.hourly_demand[MINUTE] = []
	state.hourly_demand[HOUR] = []
	state.hourly_demand[DAY] = []
	for result in results:
		state.hourly_demand[MINUTE].append(result["detailed"])
		state.hourly_demand[HOUR].append(result["city"])
		state.hourly_demand[DAY].append(result["region"])
		state.hourly_fiscal_base.append(result["fiscal"])


static func _build_hour_demand(region, flow_profile, hour: int) -> Dictionary:
	var neighborhood_count: int = region.neighborhoods.size()
	var city_count: int = region.cities.size()
	var region_count: int = region.region_ids.size()
	var detailed: Array[PackedFloat32Array] = []
	var city: Array[PackedFloat32Array] = []
	var planning_region: Array[PackedFloat32Array] = []
	for _index in range(neighborhood_count):
		var row := PackedFloat32Array()
		row.resize(neighborhood_count)
		detailed.append(row)
	for _index in range(city_count):
		var row := PackedFloat32Array()
		row.resize(city_count)
		city.append(row)
	for _index in range(region_count):
		var row := PackedFloat32Array()
		row.resize(region_count)
		planning_region.append(row)
	var fiscal: Dictionary = {"shopping": {}, "city_parking": {}, "neighborhood_parking": {}}
	for origin in range(neighborhood_count):
		var home = region.neighborhoods[origin]
		for destination in range(neighborhood_count):
			if origin == destination:
				var local_shop: float = flow_profile.hourly_shopping_outbound_od[hour][origin][destination]
				if local_shop > 0.0:
					var local_county_id: int = region.jurisdiction_for_neighborhood(destination, "County").id
					fiscal["shopping"][local_county_id] = float(fiscal["shopping"].get(local_county_id, 0.0)) + local_shop * FiscalCalculator.shopping_spend(region, origin)
				continue
			var work: float = flow_profile.hourly_work_od[hour][origin][destination]
			var shop: float = flow_profile.hourly_shopping_od[hour][origin][destination]
			var social: float = flow_profile.hourly_social_od[hour][origin][destination]
			if work + shop + social < 0.00001:
				continue
			var destination_neighborhood = region.neighborhoods[destination]
			var distance: float = home.position_km.distance_to(destination_neighborhood.position_km)
			var share: float = clampf(0.20 + 0.035 * distance, 0.20, 0.90)
			var cars: float = share * (work / 1.2 + shop / 1.5 + social / 1.8)
			var detailed_row: PackedFloat32Array = detailed[origin]
			detailed_row[destination] = cars
			detailed[origin] = detailed_row
			var city_row: PackedFloat32Array = city[home.city_id]
			city_row[destination_neighborhood.city_id] += cars
			city[home.city_id] = city_row
			var region_row: PackedFloat32Array = planning_region[home.region_id]
			region_row[destination_neighborhood.region_id] += cars
			planning_region[home.region_id] = region_row
			var outbound_shop: float = flow_profile.hourly_shopping_outbound_od[hour][origin][destination]
			var county_id: int = region.jurisdiction_for_neighborhood(destination, "County").id
			fiscal["shopping"][county_id] = float(fiscal["shopping"].get(county_id, 0.0)) + outbound_shop * FiscalCalculator.shopping_spend(region, origin)
			var outbound: float = share * (flow_profile.hourly_work_outbound_od[hour][origin][destination] / 1.2 + outbound_shop / 1.5 + flow_profile.hourly_social_outbound_od[hour][origin][destination] / 1.8)
			var city_id: int = region.city_jurisdiction_ids[destination_neighborhood.city_id]
			var neighborhood_id: int = destination_neighborhood.jurisdiction_id
			fiscal["city_parking"][city_id] = float(fiscal["city_parking"].get(city_id, 0.0)) + outbound
			fiscal["neighborhood_parking"][neighborhood_id] = float(fiscal["neighborhood_parking"].get(neighborhood_id, 0.0)) + outbound
	return {"detailed": detailed, "city": city, "region": planning_region, "fiscal": fiscal}


static func _build_hour(region, flow_profile, state, mode: int, hour: int) -> void:
	state.cached_hour = hour
	state.cached_mode = mode
	var group_mode: int = MINUTE if mode <= MINUTE else mode
	var grouped: Array = state.hourly_demand[group_mode][hour]
	var group_count: int = grouped.size()
	var representatives: Array[int] = []
	if group_mode == MINUTE:
		for index in range(group_count):
			representatives.append(index)
	elif group_mode == HOUR:
		for city in region.cities:
			representatives.append(city["neighborhood_ids"][0])
	else:
		for area_id in region.region_ids:
			representatives.append(region.jurisdictions[area_id].neighborhood_ids[0])
	var fiscal_base: Dictionary = state.hourly_fiscal_base[hour]
	var fiscal: Dictionary = {}
	for area_id in fiscal_base["shopping"]:
		_credit(fiscal, area_id, "sales", float(fiscal_base["shopping"][area_id]) * region.jurisdictions[area_id].sales_tax_rate)
	for area_id in fiscal_base["city_parking"]:
		_credit(fiscal, area_id, "fee", float(fiscal_base["city_parking"][area_id]) * region.jurisdictions[area_id].parking_fee)
	for area_id in fiscal_base["neighborhood_parking"]:
		_credit(fiscal, area_id, "fee", float(fiscal_base["neighborhood_parking"][area_id]) * region.jurisdictions[area_id].parking_fee)
	state.cached_revenue = fiscal
	var volume := PackedVector2Array()
	volume.resize(region.road_links.size())
	var routes: Array = state.paths_by_mode.get(0, [])
	if routes.is_empty():
		var costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
		for index in range(costs.size()):
			var link = region.road_links[index]
			var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
			costs[index] += Vector2(link.toll_forward, link.toll_reverse) * 0.3 + state.queues[index] * (60.0 / maxf(1.0, capacity))
		routes = RoadGraph.route_pairs(region, costs, [], true)["paths"]
		state.paths_by_mode[0] = routes
	for origin_group in range(group_count):
		for destination_group in range(group_count):
			var cars: float = grouped[origin_group][destination_group]
			if origin_group == destination_group or cars < 0.00001:
				continue
			for edge in routes[representatives[origin_group]][representatives[destination_group]]:
				var value: Vector2 = volume[edge.x]
				if edge.y == 0:
					value.x += cars
				else:
					value.y += cars
				volume[edge.x] = value
	if group_mode >= HOUR:
		_add_internal_group_load(region, group_mode, grouped, volume)
	state.cached_links = volume
	state.profile.hourly_volumes[hour] = volume.duplicate()


static func _add_internal_group_load(region, mode: int, grouped: Array, volume: PackedVector2Array) -> void:
	# The aggregate OD matrix keeps same-city or same-region trips on its diagonal.
	# Estimate their road use with two city hops or four regional hops per trip.
	# This keeps local traffic in the capacity calculation without routing each OD.
	var count: int = grouped.size()
	var internal_capacity := PackedFloat32Array()
	internal_capacity.resize(count)
	var link_groups := PackedInt32Array()
	link_groups.resize(region.road_links.size())
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var from_group: int = _group_for_node(region, link.from_node_id, mode)
		var to_group: int = _group_for_node(region, link.to_node_id, mode)
		link_groups[index] = from_group if from_group == to_group else -1
		if link_groups[index] >= 0:
			internal_capacity[link_groups[index]] += RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
	var estimated_hops: float = 2.0 if mode == HOUR else 4.0
	for index in range(region.road_links.size()):
		var group_id: int = link_groups[index]
		if group_id < 0 or internal_capacity[group_id] <= 0.0:
			continue
		var internal_cars: float = grouped[group_id][group_id]
		if internal_cars <= 0.0:
			continue
		var link = region.road_links[index]
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		var direction_load: float = 0.5 * internal_cars * estimated_hops * capacity / internal_capacity[group_id]
		volume[index] += Vector2(direction_load, direction_load)


static func _credit(fiscal: Dictionary, area_id: int, kind: String, amount: float) -> void:
	if amount <= 0.0:
		return
	if not fiscal.has(area_id):
		fiscal[area_id] = {"sales": 0.0, "fee": 0.0}
	fiscal[area_id][kind] += amount


static func _group_for_node(region, node_id: int, mode: int) -> int:
	var city_id: int = _node_city(region, node_id)
	return city_id if mode == HOUR else region.cities[city_id]["region_id"]


static func _node_city(region, node_id: int) -> int:
	var node = region.road_nodes[node_id]
	return node.city_id if node.city_id >= 0 else region.neighborhoods[region.nearest_neighborhood_id(node.position_km)].city_id
