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
const GridFamily = preload("res://scripts/simulation/grid_family_layout.gd")


static func refresh_candidates(region, changed_city_ids: Array[int] = []) -> void:
	var selected_designs: Dictionary = {}
	var selected_characters: Dictionary = {}
	var previous_candidates: Array = region.development_candidates.duplicate()
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
	if not changed_city_ids.is_empty():
		for candidate in previous_candidates:
			if not changed_city_ids.has(int(candidate["city_id"])):
				_index_candidate(region, candidate.duplicate())
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null or not changed_city_ids.is_empty() and not changed_city_ids.has(neighborhood.city_id):
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
	var proposals: Array[Dictionary] = GraphGrowth.proposals(region, changed_city_ids)
	for proposal in proposals:
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
		var owned_cells: Array[Vector2i] = UrbanGraph.district_cells(region, city_id, sector).duplicate()
		owned_cells.append_array(layout.border_cells)
		candidate["urban_cells"] = owned_cells
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
	_index_candidate(region, {"id": candidate_id, "key": layout.key, "city_id": layout.city_id, "grid": grid, "polygon": layout.polygon, "center_km": area.center_km, "frontage_link_id": frontage_id, "neighborhood_id": neighborhood_id, "layout": layout, "character_override": Character.AUTO, "character_profile": character_profile})
	region.development_candidates[-1]["claims_stamp"] = hash([GridFamily.POLICY_VERSION, region.road_geometry_revision, region.urban_sector_claims, region.urban_block_claims])


static func _index_candidate(region, candidate: Dictionary) -> void:
	var candidate_id: int = region.development_candidates.size()
	candidate["id"] = candidate_id
	region.development_candidates.append(candidate)
	region.development_candidate_keys[candidate["key"]] = candidate_id
	var city_id: int = int(candidate["city_id"])
	if not region.development_candidate_city_ids.has(city_id):
		region.development_candidate_city_ids[city_id] = []
	region.development_candidate_city_ids[city_id].append(candidate_id)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in candidate["polygon"]:
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


static func set_approval(region, candidate_id: int, approved: bool, allocation: int = -1, shares: Dictionary = {}, density: Dictionary = {}, prepared: Dictionary = {}) -> Dictionary:
	var approval_started:=Time.get_ticks_usec()
	var stages:Dictionary={}
	if candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return {"ok": false, "reason": "Select a neighborhood plan."}
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	var prepared_matches: bool = not prepared.is_empty() and prepared.get("stamp", -1) == preparation_stamp(region, candidate, shares, density)
	# The packet already validated this layout against the same road/claim
	# inputs. Rechecking access and funds below is sufficient when it matches.
	if approved and not prepared_matches and not ensure_candidate(region, candidate_id):
		return {"ok": false, "reason": "This proposal changed. Select a current suggestion."}
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
		StreetNetwork.attach(region, neighborhood, candidate["layout"], false, false)
		stages["attach"]=Time.get_ticks_usec()-approval_started
		if candidate.has("urban_sector"):
			region.urban_sector_claims[UrbanGraph.sector_key(neighborhood.city_id, candidate["urban_sector"])] = neighborhood.id
			for cell in candidate.get("urban_cells", []):
				region.urban_block_claims[UrbanGraph.block_key(neighborhood.city_id, cell)] = neighborhood.id
			UrbanGraph.register_layout(region, neighborhood.street_layout, neighborhood.id)
		if prepared_matches:
			var ready = prepared.neighborhood
			for field in ["street_layout", "baseline_developable_area_ha", "developable_area_ha", "base_housing_capacity", "base_job_capacity", "housing_capacity", "job_capacity", "buildings", "building_model_version", "building_geometry_revision", "building_plan_signature", "block_zoning"]:
				var value = ready.get(field)
				neighborhood.set(field, value.duplicate(true) if value is Array or value is Dictionary else value)
			neighborhood.development_plan = ready.development_plan.copy()
			neighborhood.development_plan.reserved = 0
			neighborhood.development_plan.pending_zoning = {}
			neighborhood.development_plan.zoning_day = -1
			stages["prepared"] = 1
		else:
			RoadLand.apply_to_new_neighborhood(region, neighborhood,stages)
		neighborhood.development_plan.design_demand=maxf(1,neighborhood.development_plan.target_housing*2+neighborhood.development_plan.target_jobs)
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
	return {"ok": true, "new_neighborhood": new_neighborhood, "allocated": allocation,"stages_us":stages}


static func planning_stamp(region) -> int:
	var policies: Array = []
	for city in region.cities: policies.append(city.get("urban_policy", {}))
	var designs: Array = []
	for candidate in region.development_candidates:
		if int(candidate.neighborhood_id) < 0:
			designs.append([candidate.key, candidate.get("design_variant", 0), candidate.get("character_override", "Auto")])
	return hash([GridFamily.POLICY_VERSION, region.generation_seed, region.terrain.get_instance_id() if region.terrain != null else 0, region.road_geometry_revision, region.neighborhoods.size(), region.urban_sector_claims, region.urban_block_claims, region.urban_corridors, region.rail_reservations, region.station_sites, policies, designs])


static func preparation_stamp(region, candidate: Dictionary, shares: Dictionary, density: Dictionary) -> int:
	return hash([planning_stamp(region), candidate.key, region.neighborhoods.size(), candidate.layout.nodes, candidate.layout.classes, shares, density, region.building_model_version])


static func prepare_approval(region, candidate_id: int, shares: Dictionary, density: Dictionary) -> Dictionary:
	if not ensure_candidate(region, candidate_id): return {}
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate.neighborhood_id) >= 0: return {}
	var stamp := preparation_stamp(region, candidate, shares, density)
	var result := set_approval(region, candidate_id, true, 0, shares, density)
	if not result.get("ok", false): return {}
	return {"stamp": stamp, "neighborhood": region.neighborhoods[-1]}


static func ensure_candidate(region, candidate_id: int) -> bool:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size(): return false
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate.neighborhood_id) >= 0 or not candidate.has("urban_sector"): return true
	var stamp := hash([GridFamily.POLICY_VERSION, region.road_geometry_revision, region.urban_sector_claims, region.urban_block_claims])
	if candidate.get("claims_stamp", -1) == stamp: return true
	if region.urban_sector_claims.has(UrbanGraph.sector_key(candidate.city_id, candidate.urban_sector)): return false
	var generated := UrbanGraph.make_layout(region, candidate.city_id, candidate.urban_sector, int(candidate.get("design_variant", 0)))
	if generated.frontage_id < 0 or generated.layout.blocks.is_empty() or generated.layout.core_paths.is_empty(): return false
	var cells := UrbanGraph.district_cells(region, candidate.city_id, candidate.urban_sector).duplicate()
	cells.append_array(generated.layout.border_cells)
	for cell in cells:
		if region.urban_block_claims.has(UrbanGraph.block_key(candidate.city_id, cell)): return false
	candidate.layout = generated.layout
	candidate.polygon = generated.layout.polygon
	candidate.frontage_link_id = generated.frontage_id
	candidate.urban_cells = cells
	candidate["claims_stamp"] = stamp
	return true


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
