extends RefCounted

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
	copy.dev_mode = source.dev_mode
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
	copy.accessibility_cost_revision = source.accessibility_cost_revision
	copy.accessibility_link_costs = source.accessibility_link_costs.duplicate()
	copy.neighborhood_gateway_node_ids = source.neighborhood_gateway_node_ids.duplicate()
	copy.city_hub_node_ids = source.city_hub_node_ids.duplicate()
	copy.city_highway_access_node_ids = source.city_highway_access_node_ids.duplicate()
	copy.city_route_node_ids = source.city_route_node_ids.duplicate()
	copy.neighborhood_spoke_link_ids = source.neighborhood_spoke_link_ids.duplicate()
	copy.development_candidates = source.development_candidates.duplicate(true)
	copy.development_candidate_keys = source.development_candidate_keys.duplicate(true)
	copy.development_candidate_cells = source.development_candidate_cells.duplicate(true)
	copy.development_candidate_city_ids = source.development_candidate_city_ids.duplicate(true)
	copy.road_reservations = source.road_reservations.duplicate(true)
	copy.urban_sector_claims = source.urban_sector_claims.duplicate(true)
	copy.urban_block_claims = source.urban_block_claims.duplicate(true)
	copy.urban_plan_edges = source.urban_plan_edges.duplicate(true)
	copy.urban_locked_junctions = source.urban_locked_junctions.duplicate(true)
	copy.urban_grid_domains = source.urban_grid_domains.duplicate(true)
	copy.urban_sector_merges = source.urban_sector_merges.duplicate(true)
	copy.urban_sector_merge_members = source.urban_sector_merge_members.duplicate(true)
	copy.urban_district_cells = source.urban_district_cells.duplicate(true)
	copy.city_border_seams = source.city_border_seams.duplicate(true)
	copy.urban_corridors = source.urban_corridors.duplicate(true)
	copy.rail_reservations = source.rail_reservations.duplicate(true)
	copy.station_sites = source.station_sites.duplicate(true)
	copy.urban_route_revision = source.urban_route_revision
	for city_id in source.urban_route_cache:
		var graph: Dictionary = source.urban_route_cache[city_id].duplicate()
		graph["trees"] = graph["trees"].duplicate()
		copy.urban_route_cache[city_id] = graph
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
		n.baseline_developable_area_ha = original.baseline_developable_area_ha
		n.base_housing_capacity = original.base_housing_capacity
		n.base_job_capacity = original.base_job_capacity
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
		n.street_layout = original.street_layout
		n.development_plan = original.development_plan.copy() if original.development_plan != null else null
		n.access_node_ids = original.access_node_ids.duplicate()
		n.access_minutes = original.access_minutes
		n.built_fraction = original.built_fraction
		n.block_zoning = original.block_zoning.duplicate()
		n.character_profile = original.character_profile
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
		node.managed_neighborhood_id = original.managed_neighborhood_id
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
		link.corridor_id = original.corridor_id
		link.corridor_start_km = original.corridor_start_km
		link.managed_neighborhood_id = original.managed_neighborhood_id
		link.crossings = original.crossings.duplicate(true)
		link.border_city_ids = original.border_city_ids
		link.border_seam_key = original.border_seam_key
		copy.road_links.append(link)
	copy.road_projects = []
	for original in source.road_projects:
		copy.road_projects.append(_copy_value(original))
	return copy


static func release_retired_data(payload: Dictionary) -> void:
	payload.clear()


static func _copy_value(value):
	match typeof(value):
		TYPE_OBJECT:
			if value == null or value.get_script() == null:
				return value
			if value.get_script() == preload("res://scripts/simulation/street_layout.gd"):
				return value
			var copy = value.get_script().new()
			for property in value.get_property_list():
				if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					if property["name"] in ["street_spatial_cache", "road_corridor_cache", "neighborhood_spatial_cache", "urban_district_owner_cache", "urban_valid_junction_cache", "urban_route_cache", "urban_route_revision"]:
						continue
					copy.set(property["name"], _copy_value(value.get(property["name"])))
			return copy
		TYPE_ARRAY:
			var copy: Array = value.duplicate()
			for index in range(value.size()):
				copy[index] = _copy_value(value[index])
			return copy
		TYPE_DICTIONARY:
			var copy: Dictionary = value.duplicate()
			for key in value:
				copy[key] = _copy_value(value[key])
			return copy
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return value.duplicate()
		_:
			return value
