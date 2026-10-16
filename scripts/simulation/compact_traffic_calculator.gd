extends RefCounted

const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")


static func prepare_routes(region, state, previous_state = null) -> void:
	var link_indices: Dictionary = {}
	for index in range(state.link_ids.size()):
		link_indices[state.link_ids[index]] = index
	state.spoke_indices.resize(region.neighborhood_spoke_link_ids.size())
	for neighborhood_id in range(region.neighborhood_spoke_link_ids.size()):
		state.spoke_indices[neighborhood_id] = int(link_indices.get(region.neighborhood_spoke_link_ids[neighborhood_id], -1))
	if previous_state != null and previous_state.link_ids == state.link_ids and not previous_state.compact_trees_by_mode.is_empty():
		state.compact_trees_by_mode = previous_state.compact_trees_by_mode
		return
	var city_nodes := PackedInt32Array()
	for node_id in region.city_hub_node_ids:
		city_nodes.append(node_id)
	var region_nodes := PackedInt32Array()
	var found := PackedByteArray()
	found.resize(region.region_ids.size())
	for city in region.cities:
		var region_id: int = city["region_id"]
		if found[region_id] == 0:
			found[region_id] = 1
			region_nodes.append(region.city_hub_node_ids[city["id"]])
	var costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	state.compact_trees_by_mode = {
		"city_nodes": city_nodes,
		"region_nodes": region_nodes,
		"city_trees": RoadGraph.group_route_trees(region, costs, city_nodes),
		"region_trees": RoadGraph.group_route_trees(region, costs, region_nodes),
	}


static func build_hour(region, profile, state, mode: int, hour: int) -> void:
	if mode == 2 and hour >= 0 and hour < state.compact_hourly_links.size() and not state.compact_hourly_links[hour].is_empty():
		state.cached_links = state.compact_hourly_links[hour]
		state.profile.hourly_volumes[hour] = state.cached_links
		state.cached_revenue = state.compact_hourly_revenue[hour]
		state.cached_hour = hour
		state.cached_mode = mode
		return
	if state.compact_trees_by_mode.is_empty():
		prepare_routes(region, state)
	var stage_start: int = Time.get_ticks_usec()
	var region_mode: bool = mode == 3
	var group_count: int = region.region_ids.size() if region_mode else region.cities.size()
	var grouped: Array[PackedFloat32Array] = []
	var daily_od: Dictionary = profile.compact_region_od if region_mode else profile.compact_city_od
	var work_daily: Array = daily_od[FlowProfile.WORK]
	var shopping_daily: Array = daily_od[FlowProfile.COMMERCIAL]
	var social_daily: Array = daily_od[FlowProfile.SOCIAL]
	var work_curves: Dictionary = profile.compact_curves[FlowProfile.WORK]
	var shopping_curves: Dictionary = profile.compact_curves[FlowProfile.COMMERCIAL]
	var social_curves: Dictionary = profile.compact_curves[FlowProfile.SOCIAL]
	var work_out: float = 1.0 / 24.0 if hour == 24 else work_curves["out"][hour]
	var work_back: float = 1.0 / 24.0 if hour == 24 else work_curves["back"][hour]
	var shopping_out: float = 1.0 / 24.0 if hour == 24 else shopping_curves["out"][hour]
	var shopping_back: float = 1.0 / 24.0 if hour == 24 else shopping_curves["back"][hour]
	var social_out: float = 1.0 / 24.0 if hour == 24 else social_curves["out"][hour]
	var social_back: float = 1.0 / 24.0 if hour == 24 else social_curves["back"][hour]
	var centers := PackedVector2Array()
	centers.resize(group_count)
	for _group_id in range(group_count):
		var row := PackedFloat32Array()
		row.resize(group_count)
		grouped.append(row)
		centers[_group_id] = region.jurisdictions[region.region_ids[_group_id]].center_km if region_mode else region.cities[_group_id]["center_km"]
	for origin_group in range(group_count):
		var work_origin: PackedFloat32Array = work_daily[origin_group]
		var shopping_origin: PackedFloat32Array = shopping_daily[origin_group]
		var social_origin: PackedFloat32Array = social_daily[origin_group]
		var grouped_origin: PackedFloat32Array = grouped[origin_group]
		for destination_group in range(group_count):
			if origin_group == destination_group and not region_mode:
				continue
			var work: float = work_origin[destination_group] * work_out + work_daily[destination_group][origin_group] * work_back
			var shopping: float = shopping_origin[destination_group] * shopping_out + shopping_daily[destination_group][origin_group] * shopping_back
			var social: float = social_origin[destination_group] * social_out + social_daily[destination_group][origin_group] * social_back
			if work + shopping + social < 0.00001:
				continue
			var distance: float = centers[origin_group].distance_to(centers[destination_group])
			var car_share: float = clampf(0.20 + 0.035 * distance, 0.20, 0.90)
			grouped_origin[destination_group] = car_share * (work / 1.2 + shopping / 1.5 + social / 1.8)
	_record_stage(state, "group_demand", stage_start)
	stage_start = Time.get_ticks_usec()
	var node_key: String = "region_nodes" if region_mode else "city_nodes"
	var tree_key: String = "region_trees" if region_mode else "city_trees"
	var volumes: PackedVector2Array = RoadGraph.assign_group_volumes(region, state.compact_trees_by_mode[node_key], grouped, state.compact_trees_by_mode[tree_key])
	_record_stage(state, "group_routes", stage_start)
	stage_start = Time.get_ticks_usec()
	if region_mode:
		_add_internal_region_load(region, grouped, volumes)
	_record_stage(state, "internal_load", stage_start)
	stage_start = Time.get_ticks_usec()
	_add_neighborhood_spokes(region, profile, state, hour, volumes)
	_record_stage(state, "local_spokes", stage_start)
	stage_start = Time.get_ticks_usec()
	state.cached_links = volumes
	if hour < 24:
		state.profile.hourly_volumes[hour] = volumes.duplicate()
	state.cached_revenue = _hourly_revenue(region, profile, hour)
	_record_stage(state, "revenue", stage_start)
	state.cached_hour = hour
	state.cached_mode = mode


static func _add_internal_region_load(region, grouped: Array[PackedFloat32Array], volumes: PackedVector2Array) -> void:
	var capacity_by_region := PackedFloat32Array()
	capacity_by_region.resize(region.region_ids.size())
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var from_city: int = region.road_nodes[link.from_node_id].city_id
		var to_city: int = region.road_nodes[link.to_node_id].city_id
		if from_city < 0 or to_city < 0 or from_city == to_city:
			continue
		var from_region: int = region.cities[from_city]["region_id"]
		if from_region == region.cities[to_city]["region_id"]:
			capacity_by_region[from_region] += RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var from_city: int = region.road_nodes[link.from_node_id].city_id
		var to_city: int = region.road_nodes[link.to_node_id].city_id
		if from_city < 0 or to_city < 0 or from_city == to_city:
			continue
		var group_id: int = region.cities[from_city]["region_id"]
		if group_id != region.cities[to_city]["region_id"] or capacity_by_region[group_id] <= 0.0:
			continue
		var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
		var estimated: float = 0.5 * grouped[group_id][group_id] * capacity / capacity_by_region[group_id]
		volumes[index] += Vector2(estimated, estimated)


static func _add_neighborhood_spokes(region, profile, state, hour: int, volumes: PackedVector2Array) -> void:
	var work_origin: PackedFloat32Array = profile.compact_origin_daily[FlowProfile.WORK]
	var work_destination: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.WORK]
	var shopping_origin: PackedFloat32Array = profile.compact_origin_daily[FlowProfile.COMMERCIAL]
	var shopping_destination: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.COMMERCIAL]
	var social_origin: PackedFloat32Array = profile.compact_origin_daily[FlowProfile.SOCIAL]
	var social_destination: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.SOCIAL]
	var work_out: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.WORK]["out"][hour]
	var work_back: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.WORK]["back"][hour]
	var shopping_out: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.COMMERCIAL]["out"][hour]
	var shopping_back: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.COMMERCIAL]["back"][hour]
	var social_out: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.SOCIAL]["out"][hour]
	var social_back: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.SOCIAL]["back"][hour]
	for neighborhood in region.neighborhoods:
		var neighborhood_id: int = neighborhood.id
		var spoke_index: int = state.spoke_indices[neighborhood_id]
		if spoke_index < 0:
			continue
		var outward: float = 0.5 * ((work_origin[neighborhood_id] * work_out + work_destination[neighborhood_id] * work_back) / 1.2 + (shopping_origin[neighborhood_id] * shopping_out + shopping_destination[neighborhood_id] * shopping_back) / 1.5 + (social_origin[neighborhood_id] * social_out + social_destination[neighborhood_id] * social_back) / 1.8)
		var inward: float = 0.5 * ((work_destination[neighborhood_id] * work_out + work_origin[neighborhood_id] * work_back) / 1.2 + (shopping_destination[neighborhood_id] * shopping_out + shopping_origin[neighborhood_id] * shopping_back) / 1.5 + (social_destination[neighborhood_id] * social_out + social_origin[neighborhood_id] * social_back) / 1.8)
		volumes[spoke_index] += Vector2(outward, inward)


static func _hourly_revenue(region, profile, hour: int) -> Dictionary:
	var fiscal: Dictionary = {}
	var shopping_curve: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.COMMERCIAL]["out"][hour]
	var work_curve: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.WORK]["out"][hour]
	var social_curve: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[FlowProfile.SOCIAL]["out"][hour]
	var shopping_destinations: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.COMMERCIAL]
	var work_destinations: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.WORK]
	var social_destinations: PackedFloat32Array = profile.compact_destination_daily[FlowProfile.SOCIAL]
	var sales_base := PackedFloat32Array()
	var city_arrivals := PackedFloat32Array()
	sales_base.resize(region.county_ids.size())
	city_arrivals.resize(region.cities.size())
	for neighborhood in region.neighborhoods:
		var neighborhood_id: int = neighborhood.id
		var destination_visits: float = shopping_destinations[neighborhood_id] * shopping_curve
		sales_base[neighborhood.county_id] += destination_visits * maxf(10.0, float(neighborhood.average_monthly_income) * FiscalCalculator.SHOPPING_SPEND_INCOME_SHARE)
		var arrivals: float = 0.5 * (work_destinations[neighborhood_id] * work_curve + destination_visits + social_destinations[neighborhood_id] * social_curve)
		city_arrivals[neighborhood.city_id] += arrivals
		var district = region.jurisdictions[neighborhood.jurisdiction_id]
		if district.parking_fee > 0.0:
			_credit(fiscal, district.id, "fee", arrivals * district.parking_fee)
	for county_index in range(region.county_ids.size()):
		var county_id: int = region.county_ids[county_index]
		_credit(fiscal, county_id, "sales", sales_base[county_index] * region.jurisdictions[county_id].sales_tax_rate)
	for city_index in range(region.cities.size()):
		var city_id: int = region.city_jurisdiction_ids[city_index]
		if region.jurisdictions[city_id].parking_fee > 0.0:
			_credit(fiscal, city_id, "fee", city_arrivals[city_index] * region.jurisdictions[city_id].parking_fee)
	return fiscal


static func _credit(fiscal: Dictionary, area_id: int, kind: String, amount: float) -> void:
	if amount <= 0.0:
		return
	if not fiscal.has(area_id):
		fiscal[area_id] = {"sales": 0.0, "fee": 0.0}
	fiscal[area_id][kind] += amount


static func _record_stage(state, label: String, started: int) -> void:
	state.stage_totals_us[label] = int(state.stage_totals_us.get(label, 0)) + Time.get_ticks_usec() - started
