extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const Budget = preload("res://scripts/simulation/development_budget.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const CELL_SIZE_KM = LayoutGenerator.FRONTAGE_KM


static func refresh_candidates(region) -> void:
	for candidate in region.development_candidates:
		candidate["frontage_link_id"] = -1
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var corridors: Dictionary = {}
	var occupied: Dictionary = {}
	var claimed: Dictionary = {}
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		occupied[neighborhood.street_layout.key] = neighborhood.id
		if not claimed.has(neighborhood.city_id):
			claimed[neighborhood.city_id] = []
		claimed[neighborhood.city_id].append(neighborhood.street_layout.polygon)
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		var corridor_id: int = link.corridor_id if link.corridor_id >= 0 else link.id
		if not corridors.has(corridor_id):
			corridors[corridor_id] = []
		corridors[corridor_id].append(link)
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		var layout = neighborhood.street_layout
		var frontage_id := -1
		for link_index in Spatial.near_links(region, layout.nodes[layout.arterial_nodes[0]]):
			var link = region.road_links[link_index]
			if link.road_class == Roads.ARTERIAL and rooted[link.from_node_id] != 0 and rooted[link.to_node_id] != 0 and RoadPlanner.closest_point(link.points, layout.nodes[layout.arterial_nodes[0]]).distance_to(layout.nodes[layout.arterial_nodes[0]]) < 0.02:
				frontage_id = link.id
				break
		if region.development_candidate_keys.has(layout.key):
			region.development_candidates[region.development_candidate_keys[layout.key]]["frontage_link_id"] = frontage_id
		else:
			_register_candidate(region, layout, neighborhood.id, frontage_id)
	for corridor_id in corridors:
		var links: Array = corridors[corridor_id]
		links.sort_custom(func(first, second) -> bool: return first.corridor_start_km < second.corridor_start_km)
		var route := PackedVector2Array()
		var length := 0.0
		var start_station: float = links[0].corridor_start_km
		for link in links:
			if not route.is_empty() and route[-1].distance_to(link.points[0]) > 0.02:
				continue
			length += link.length_km
			route.append_array(link.points if route.is_empty() else link.points.slice(1))
		for slot in range(floori(start_station / CELL_SIZE_KM), ceili((start_station + length) / CELL_SIZE_KM)):
			var start: float = maxf(0.0, float(slot) * CELL_SIZE_KM - start_station)
			var finish: float = minf(length, float(slot + 1) * CELL_SIZE_KM - start_station)
			if finish - start < 0.6:
				continue
			var frontage: PackedVector2Array = LayoutGenerator.frontage(route, start, finish)
			var center: Vector2 = LayoutGenerator._along(frontage, (finish - start) * 0.5)
			var city_id: int = region.city_id_at_point(center)
			if city_id < 0:
				continue
			var key: String = "%d:%d:%d" % [city_id, corridor_id, slot]
			var frontage_id := -1
			for link in links:
				if RoadPlanner.closest_point(link.points, center).distance_to(center) < 0.02:
					frontage_id = link.id
					break
			if frontage_id < 0:
				continue
			if region.development_candidate_keys.has(key):
				var existing: Dictionary = region.development_candidates[region.development_candidate_keys[key]]
				existing["frontage_link_id"] = frontage_id
				if not claimed.has(city_id):
					claimed[city_id] = []
				if int(existing["neighborhood_id"]) < 0:
					claimed[city_id].append(existing["polygon"])
				continue
			var neighborhood_id: int = occupied.get(key, -1)
			if neighborhood_id < 0 and _frontage_occupied(frontage, center, claimed.get(city_id, [])):
				continue
			var layout = region.neighborhoods[neighborhood_id].street_layout if neighborhood_id >= 0 else LayoutGenerator.generate(region, city_id, frontage, key, claimed.get(city_id, []))
			if layout.polygon.size() < 3:
				continue
			_register_candidate(region, layout, neighborhood_id, frontage_id)
			if not claimed.has(city_id):
				claimed[city_id] = []
			if neighborhood_id < 0:
				claimed[city_id].append(layout.polygon)


static func _frontage_occupied(frontage: PackedVector2Array, center: Vector2, claimed: Array) -> bool:
	var normal: Vector2 = (frontage[-1] - frontage[0]).normalized().orthogonal() * LayoutGenerator.DEPTH_KM * 0.5
	for point in [center + normal, center - normal]:
		var occupied := false
		for polygon in claimed:
			if Jurisdiction.polygon_contains_point(point, polygon):
				occupied = true
				break
		if not occupied:
			return false
	return true


static func _register_candidate(region, layout, neighborhood_id: int, frontage_id: int) -> void:
	var area = Jurisdiction.new()
	area.polygon_km = layout.polygon
	Geography.update_bounds(area)
	var candidate_id: int = region.development_candidates.size()
	var grid: Vector2i = Geography.cell_grid_at_point(region.generation_seed, area.center_km)
	region.development_candidates.append({"id": candidate_id, "key": layout.key, "city_id": layout.city_id, "grid": grid, "polygon": layout.polygon, "center_km": area.center_km, "frontage_link_id": frontage_id, "neighborhood_id": neighborhood_id, "layout": layout})
	region.development_candidate_keys[layout.key] = candidate_id
	var cell_key: String = "%d:%d" % [grid.x, grid.y]
	if not region.development_candidate_cells.has(cell_key):
		region.development_candidate_cells[cell_key] = []
	region.development_candidate_cells[cell_key].append(candidate_id)


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
	if frontage_index < 0 or region.road_links[frontage_index].road_class != Roads.ARTERIAL or rooted[region.road_links[frontage_index].from_node_id] == 0 or rooted[region.road_links[frontage_index].to_node_id] == 0:
		return {"ok": false, "reason": "Connect this arterial to an established city."}
	var city = region.jurisdictions[region.city_jurisdiction_ids[candidate["city_id"]]]
	var estimate: int = candidate["layout"].total_cost()
	if neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_plan != null:
		estimate = Budget.remaining_cost(region.neighborhoods[neighborhood_id])
		if allocation < 0:
			allocation = maxi(0, estimate - region.neighborhoods[neighborhood_id].development_plan.reserved)
	if allocation < 0:
		allocation = estimate
	if allocation > city.treasury:
		return {"ok": false, "reason": "Insufficient city funds. Allocate a smaller phased budget."}
	var new_neighborhood: bool = neighborhood_id < 0
	var neighborhood
	if new_neighborhood:
		neighborhood = RegionGenerator.append_neighborhood(region, candidate["city_id"], candidate["polygon"], candidate["grid"])
		_initialize_empty(neighborhood)
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
