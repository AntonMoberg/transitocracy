extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const Budget = preload("res://scripts/simulation/development_budget.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const GraphGrowth = preload("res://scripts/simulation/graph_growth_planner.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")


static func refresh_candidates(region) -> void:
	var selected_designs: Dictionary = {}
	var selected_characters: Dictionary = {}
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0:
			continue
		if bool(candidate.get("design_override", false)):
			selected_designs[candidate["key"]] = int(candidate.get("design_variant", 0))
		selected_characters[candidate["key"]] = candidate.get("character_override", Character.AUTO)
	region.development_candidates.clear()
	region.development_candidate_keys.clear()
	region.development_candidate_cells.clear()
	region.development_candidate_city_ids.clear()
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		var frontage_id := -1
		if not neighborhood.street_layout.arterial_nodes.is_empty():
			var point: Vector2 = neighborhood.street_layout.nodes[neighborhood.street_layout.arterial_nodes[0]]
			for link_index in Spatial.near_links(region, point):
				var link = region.road_links[link_index]
				if link.road_class in [Roads.ARTERIAL, Roads.COLLECTOR] and RoadPlanner.closest_point(link.points, point).distance_to(point) < 0.03:
					frontage_id = link.id
					break
		_register_candidate(region, neighborhood.street_layout, neighborhood.id, frontage_id)
	for proposal in GraphGrowth.proposals(region):
		var sector: Vector2i = proposal["sector"]
		var city_id: int = proposal["layout"].city_id
		var key: String = proposal["layout"].key
		var variant: int = int(selected_designs.get(key, region.cities[city_id].get("urban_policy", {}).get("block_design", 0)))
		var generated: Dictionary = proposal if variant == 0 else UrbanGraph.make_layout(region, city_id, sector, variant)
		var layout = generated["layout"]
		if int(generated["frontage_id"]) < 0 or layout.core_paths.is_empty():
			continue
		_register_candidate(region, layout, -1, int(generated["frontage_id"]))
		var candidate: Dictionary = region.development_candidates[-1]
		candidate["urban_sector"] = sector
		candidate["urban_cells"] = UrbanGraph.district_cells(region, city_id, sector)
		candidate["design_variant"] = variant
		candidate["design_override"] = selected_designs.has(key)
		candidate["priority"] = proposal["priority"]
		region.development_candidates[-1] = candidate
		var profile: String = selected_characters.get(key, Character.AUTO)
		if profile != Character.AUTO:
			set_candidate_character(region, int(candidate["id"]), profile)


static func set_candidate_design(region, candidate_id: int, variant: int) -> bool:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size() or variant < 0 or variant > 2:
		return false
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate["neighborhood_id"]) >= 0 or not candidate.has("urban_sector"):
		return false
	if int(candidate.get("design_variant", 0)) == variant:
		return true
	var generated: Dictionary = UrbanGraph.make_layout(region, int(candidate["city_id"]), candidate["urban_sector"], variant)
	if int(generated["frontage_id"]) < 0 or generated["layout"].core_paths.is_empty():
		return false
	candidate["layout"] = generated["layout"]
	candidate["frontage_link_id"] = generated["frontage_id"]
	candidate["design_variant"] = variant
	candidate["design_override"] = true
	region.development_candidates[candidate_id] = candidate
	return true


static func _register_candidate(region, layout, neighborhood_id: int, frontage_id: int) -> void:
	var area = Jurisdiction.new()
	area.polygon_km = layout.polygon
	Geography.update_bounds(area)
	if not Jurisdiction.polygon_contains_point(area.center_km, layout.polygon):
		var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(layout.polygon)
		if triangles.size() >= 3:
			area.center_km = (layout.polygon[triangles[0]] + layout.polygon[triangles[1]] + layout.polygon[triangles[2]]) / 3.0
	var candidate_id: int = region.development_candidates.size()
	var grid: Vector2i = Geography.cell_grid_at_point(region.generation_seed, area.center_km)
	var character_profile: String
	if neighborhood_id >= 0:
		character_profile = region.neighborhoods[neighborhood_id].character_profile
	else:
		var defaults: Dictionary = RegionGenerator.zone_defaults(region, layout.city_id, grid)
		character_profile = Character.resolve(region, layout.city_id, area.center_km, layout.interior_style, defaults["shares"], defaults["density"])
	region.development_candidates.append({"id": candidate_id, "key": layout.key, "city_id": layout.city_id, "grid": grid, "polygon": layout.polygon, "center_km": area.center_km, "frontage_link_id": frontage_id, "neighborhood_id": neighborhood_id, "layout": layout, "character_override": Character.AUTO, "character_profile": character_profile})
	region.development_candidate_keys[layout.key] = candidate_id
	if not region.development_candidate_city_ids.has(layout.city_id):
		region.development_candidate_city_ids[layout.city_id] = []
	region.development_candidate_city_ids[layout.city_id].append(candidate_id)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in layout.polygon:
		var axial: Vector2 = Geography.cell_axial_coordinates(point)
		low = low.min(axial)
		high = high.max(axial)
	for cell_y in range(floori(low.y) - 1, ceili(high.y) + 2):
		for cell_x in range(floori(low.x) - 1, ceili(high.x) + 2):
			var cell_key: String = "%d:%d" % [cell_x, cell_y]
			if not region.development_candidate_cells.has(cell_key):
				region.development_candidate_cells[cell_key] = []
			region.development_candidate_cells[cell_key].append(candidate_id)


static func set_candidate_character(region, candidate_id: int, profile: String) -> bool:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size() or (profile != Character.AUTO and not Character.PROFILES.has(profile)):
		return false
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate["neighborhood_id"]) >= 0:
		return false
	var defaults: Dictionary = RegionGenerator.zone_defaults(region, int(candidate["city_id"]), candidate["grid"])
	candidate["character_override"] = profile
	candidate["character_profile"] = Character.resolve(region, int(candidate["city_id"]), candidate["center_km"], candidate["layout"].interior_style, defaults["shares"], defaults["density"], profile)
	region.development_candidates[candidate_id] = candidate
	return true


static func set_approval(region, candidate_id: int, approved: bool, allocation: int = -1, shares: Dictionary = {}, density: Dictionary = {}) -> Dictionary:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return {"ok": false, "reason": "Select a neighborhood plan."}
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	if approved and not shares.is_empty():
		var reason: String = Budget.validate_zoning(shares, density)
		if not reason.is_empty():
			return {"ok": false, "reason": reason}
	if not approved:
		if neighborhood_id < 0:
			return {"ok": false, "reason": "This land is not approved."}
		return Budget.cancel(region, neighborhood_id)
	var frontage_index: int = RoadGraph.link_index(region, int(candidate["frontage_link_id"]))
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	if frontage_index < 0 or region.road_links[frontage_index].road_class not in [Roads.ARTERIAL, Roads.COLLECTOR] or rooted[region.road_links[frontage_index].from_node_id] == 0 or rooted[region.road_links[frontage_index].to_node_id] == 0:
		return {"ok": false, "reason": "Connect the project to an established street."}
	var city = region.jurisdictions[region.city_jurisdiction_ids[candidate["city_id"]]]
	var estimate: int = candidate["layout"].total_cost()
	if neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_plan != null:
		estimate = Budget.remaining_cost(region.neighborhoods[neighborhood_id])
		if allocation < 0:
			allocation = maxi(0, estimate - region.neighborhoods[neighborhood_id].development_plan.reserved)
	if allocation < 0:
		allocation = estimate
	if region.dev_mode:
		allocation = 0
	if not region.dev_mode and allocation > city.treasury:
		return {"ok": false, "reason": "Insufficient city funds. Allocate a smaller phased budget."}
	var new_neighborhood: bool = neighborhood_id < 0
	var neighborhood
	if new_neighborhood:
		neighborhood = RegionGenerator.append_neighborhood(region, candidate["city_id"], candidate["polygon"], candidate["grid"])
		_initialize_empty(neighborhood)
		var final_shares: Dictionary = shares if not shares.is_empty() else neighborhood.zone_shares
		var final_density: Dictionary = density if not density.is_empty() else neighborhood.zone_density
		neighborhood.character_profile = Character.resolve(region, neighborhood.city_id, candidate["center_km"], candidate["layout"].interior_style, final_shares, final_density, candidate.get("character_override", Character.AUTO))
		var gateway = RoadNodeData.new()
		gateway.id = region.road_nodes.size()
		gateway.city_id = neighborhood.city_id
		gateway.neighborhood_id = neighborhood.id
		gateway.kind = "Neighborhood"
		gateway.position_km = neighborhood.position_km
		region.road_nodes.append(gateway)
		region.neighborhood_gateway_node_ids.append(gateway.id)
		region.neighborhood_spoke_link_ids.append(-1)
		region.neighborhood_development_connected.append(0)
		region.neighborhood_accessible.append(0)
		region.accessibility.append(0.0)
		StreetNetwork.attach(region, neighborhood, candidate["layout"])
		if candidate.has("urban_sector"):
			region.urban_sector_claims[UrbanGraph.sector_key(neighborhood.city_id, candidate["urban_sector"])] = neighborhood.id
			for cell in candidate.get("urban_cells", []):
				region.urban_block_claims[UrbanGraph.block_key(neighborhood.city_id, cell)] = neighborhood.id
			UrbanGraph.register_layout(region, neighborhood.street_layout, neighborhood.id)
		RoadLand.apply_to_new_neighborhood(region, neighborhood)
		candidate["neighborhood_id"] = neighborhood.id
	else:
		neighborhood = region.neighborhoods[neighborhood_id]
		if neighborhood.street_layout == null:
			StreetNetwork.attach(region, neighborhood, candidate["layout"])
	neighborhood.development_approved = true
	if neighborhood.households == 0:
		neighborhood.development_state = "Developing"
	neighborhood.development_plan.active = true
	neighborhood.development_plan.reserved += allocation
	neighborhood.development_plan.status = "Approved"
	city.treasury -= allocation
	if not shares.is_empty():
		Budget.queue_zoning(region, neighborhood.id, shares, density, region.current_day_key)
	region.road_geometry_revision += 1
	return {"ok": true, "new_neighborhood": new_neighborhood, "allocated": allocation}


static func advance_growth_policies(_region, _day_key: int) -> bool:
	# New land enters the city only through an explicit approval.
	return false


static func _initialize_empty(neighborhood) -> void:
	neighborhood.development_jobs_by_skill = neighborhood.jobs_by_skill.duplicate()
	neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
	neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
	neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
	neighborhood.baseline_occupancy = 0.75
	neighborhood.rent_level = float(neighborhood.monthly_rent)
	var weighted_income := 0.0
	for skill in neighborhood.jobs_by_skill:
		weighted_income += neighborhood.jobs_by_skill[skill] * {"Entry": 3000.0, "Skilled": 4300.0, "Professional": 6500.0}[skill]
	neighborhood.development_income = roundi(weighted_income / maxf(1.0, float(neighborhood.jobs)) * 1.1)
	neighborhood.households = 0
	neighborhood.population = 0
	neighborhood.jobs = 0
	neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
	neighborhood.shopping_attraction = 0.0
	neighborhood.monthly_rent = 0
	neighborhood.development_state = "Developing"
