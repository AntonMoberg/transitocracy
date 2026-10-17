extends RefCounted

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const RollingTrafficCalculator = preload("res://scripts/simulation/rolling_traffic_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")


# The caller owns this region. A worker receives a detached copy, so UI reads
# and road or tax edits cannot race against the next day's calculations.
static func copy_region(source):
	if source is RegionData and source.is_large_scale:
		return _copy_large_region(source)
	return _copy_value(source)


static func _copy_large_region(source):
	# Packed geometry is immutable. Ownership lists may grow when zoning creates
	# a neighborhood, so worker snapshots need their own copies of those lists.
	var copy = RegionData.new()
	copy.generation_seed = source.generation_seed
	copy.starting_city_ids = source.starting_city_ids.duplicate()
	copy.neighborhood_development_connected = source.neighborhood_development_connected.duplicate()
	copy.is_large_scale = true
	copy.current_day_key = source.current_day_key
	copy.state_name = source.state_name
	copy.region_ids = source.region_ids.duplicate()
	copy.county_ids = source.county_ids.duplicate()
	copy.city_jurisdiction_ids = source.city_jurisdiction_ids.duplicate()
	copy.neighborhood_jurisdiction_ids = source.neighborhood_jurisdiction_ids.duplicate()
	copy.city_travel_times = source.city_travel_times.duplicate()
	copy.city_od_candidates = source.city_od_candidates.duplicate()
	copy.neighborhood_accessible = source.neighborhood_accessible.duplicate()
	copy.travel_times = source.travel_times.duplicate()
	copy.accessibility = source.accessibility.duplicate()
	copy.pending_policy_changes = source.pending_policy_changes.duplicate(true)
	copy.last_population_change = source.last_population_change
	copy.last_household_change = source.last_household_change
	copy.next_road_link_id = source.next_road_link_id
	copy.next_road_project_id = source.next_road_project_id
	copy.road_geometry_revision = source.road_geometry_revision
	copy.neighborhood_gateway_node_ids = source.neighborhood_gateway_node_ids.duplicate()
	copy.city_hub_node_ids = source.city_hub_node_ids.duplicate()
	copy.city_route_node_ids = source.city_route_node_ids.duplicate()
	copy.neighborhood_spoke_link_ids = source.neighborhood_spoke_link_ids.duplicate()
	copy.development_candidates = source.development_candidates.duplicate(true)
	copy.development_candidate_keys = source.development_candidate_keys.duplicate(true)
	copy.development_candidate_cells = source.development_candidate_cells.duplicate(true)
	copy.cities = source.cities.duplicate(true)
	for original in source.neighborhoods:
		var n = NeighborhoodData.new()
		n.id = original.id
		n.city_id = original.city_id
		n.county_id = original.county_id
		n.region_id = original.region_id
		n.jurisdiction_id = original.jurisdiction_id
		n.name = original.name
		n.position_km = original.position_km
		n.cell_grid = original.cell_grid
		n.land_area_ha = original.land_area_ha
		n.developable_area_ha = original.developable_area_ha
		n.zone_shares = original.zone_shares.duplicate()
		n.zone_density = original.zone_density.duplicate()
		n.housing_capacity = original.housing_capacity
		n.job_capacity = original.job_capacity
		n.households = original.households
		n.population = original.population
		n.jobs = original.jobs
		n.jobs_by_skill = original.jobs_by_skill.duplicate()
		n.shopping_attraction = original.shopping_attraction
		n.monthly_rent = original.monthly_rent
		n.assessed_home_value = original.assessed_home_value
		n.average_monthly_income = original.average_monthly_income
		n.average_household_wealth = original.average_household_wealth
		n.desirability = original.desirability
		n.people_per_household = original.people_per_household
		n.baseline_monthly_rent = original.baseline_monthly_rent
		n.baseline_occupancy = original.baseline_occupancy
		n.rent_level = original.rent_level
		n.migration_remainder = original.migration_remainder
		n.last_household_change = original.last_household_change
		n.last_population_change = original.last_population_change
		n.initially_developed = original.initially_developed
		n.development_approved = original.development_approved
		n.development_state = original.development_state
		n.development_jobs_by_skill = original.development_jobs_by_skill.duplicate()
		n.development_retail_share = original.development_retail_share
		n.development_income = original.development_income
		n.job_growth_remainder = original.job_growth_remainder
		copy.neighborhoods.append(n)
	for original in source.jurisdictions:
		var j = JurisdictionData.new()
		j.id = original.id
		j.kind = original.kind
		j.name = original.name
		j.parent_id = original.parent_id
		j.child_ids = original.child_ids.duplicate()
		j.neighborhood_ids = original.neighborhood_ids.duplicate()
		j.center_km = original.center_km
		j.bounds_km = original.bounds_km
		j.polygon_km = original.polygon_km
		j.generation_weight = original.generation_weight
		j.income_tax_rate = original.income_tax_rate
		j.property_tax_rate = original.property_tax_rate
		j.sales_tax_rate = original.sales_tax_rate
		j.parking_fee = original.parking_fee
		j.congestion_fee = original.congestion_fee
		j.congestion_start_hour = original.congestion_start_hour
		j.congestion_end_hour = original.congestion_end_hour
		j.treasury = original.treasury
		j.daily_income_revenue = original.daily_income_revenue
		j.daily_property_revenue = original.daily_property_revenue
		j.daily_sales_revenue = original.daily_sales_revenue
		j.daily_fee_revenue = original.daily_fee_revenue
		j.daily_grant_revenue = original.daily_grant_revenue
		j.daily_transfer_expense = original.daily_transfer_expense
		j.daily_road_upkeep = original.daily_road_upkeep
		j.last_fiscal_change = original.last_fiscal_change
		copy.jurisdictions.append(j)
	for original in source.road_nodes:
		var node = RoadNodeData.new()
		node.id = original.id
		node.position_km = original.position_km
		node.kind = original.kind
		node.neighborhood_id = original.neighborhood_id
		node.city_id = original.city_id
		node.is_interchange = original.is_interchange
		node.interchange_owner_jurisdiction_id = original.interchange_owner_jurisdiction_id
		copy.road_nodes.append(node)
	for original in source.road_links:
		var link = RoadLinkData.new()
		link.id = original.id
		link.from_node_id = original.from_node_id
		link.to_node_id = original.to_node_id
		link.road_class = original.road_class
		link.lanes_per_direction = original.lanes_per_direction
		link.points = original.points
		link.length_km = original.length_km
		link.owner_jurisdiction_id = original.owner_jurisdiction_id
		link.toll_forward = original.toll_forward
		link.toll_reverse = original.toll_reverse
		copy.road_links.append(link)
	copy.road_projects = source.road_projects.duplicate()
	return copy


static func release_retired_data(payload: Dictionary) -> void:
	payload.clear()


static func advance_day(region, day_key: int, previous_flow, previous_traffic, previous_state = null) -> Dictionary:
	region.current_day_key = day_key
	FiscalCalculator.apply_due_policies(region, day_key * 86400)
	var roads_changed: bool = RoadPlanner.advance_day(region, day_key)
	if roads_changed:
		DevelopmentPlanner.refresh_candidates(region)
		AccessibilityCalculator.recalculate(region)
	elif previous_flow != null and previous_traffic != null and previous_state != null and previous_state.next_bin >= 96:
		var weighted_times: Array[PackedFloat32Array] = RoadTrafficCalculator.generalized_travel_times(region, previous_flow, previous_traffic)
		region.travel_times = weighted_times
		AccessibilityCalculator.recalculate_jobs(region)
	NeighborhoodDynamics.advance_day(region)
	var flow_profile = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow_profile, region.generation_seed, day_key * 86400, CalendarClock.is_weekend_unix(day_key * 86400), previous_flow)
	var traffic_state = RollingTrafficCalculator.new_day(region, flow_profile, previous_state, roads_changed)
	RollingTrafficCalculator.advance_chunk(region, flow_profile, traffic_state, 1)
	NeighborhoodDynamics.refresh_desirability(region)
	RoadPlanner.refresh_regional_grants(region)
	return {"region": region, "flow": flow_profile, "traffic": traffic_state.profile, "traffic_state": traffic_state}


static func _copy_value(value):
	match typeof(value):
		TYPE_OBJECT:
			if value == null or value.get_script() == null:
				return value
			var copy = value.get_script().new()
			for property in value.get_property_list():
				if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					copy.set(property["name"], _copy_value(value.get(property["name"])))
			return copy
		TYPE_ARRAY:
			var copy: Array = value.duplicate(true)
			for index in range(value.size()):
				copy[index] = _copy_value(value[index])
			return copy
		TYPE_DICTIONARY:
			var copy: Dictionary = value.duplicate(true)
			for key in value:
				copy[key] = _copy_value(value[key])
			return copy
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return value.duplicate()
		_:
			return value
