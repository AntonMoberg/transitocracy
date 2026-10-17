extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")

const CELL_SIZE_KM = StateGeography.CELL_SIZE_KM


static func refresh_candidates(region) -> void:
	for candidate in region.development_candidates:
		candidate["frontage_link_id"] = -1
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var occupied: Dictionary = {}
	for neighborhood in region.neighborhoods:
		var grid: Vector2i = neighborhood.cell_grid
		occupied["%d:%d:%d" % [neighborhood.city_id, grid.x, grid.y]] = neighborhood.id
	for link in region.road_links:
		if link.road_class != RoadLinkData.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		var from_city: int = region.road_nodes[link.from_node_id].city_id
		var to_city: int = region.road_nodes[link.to_node_id].city_id
		var local_city = region.jurisdictions[region.city_jurisdiction_ids[from_city]] if from_city >= 0 and from_city == to_city else null
		for segment in range(1, link.points.size()):
			var first: Vector2 = link.points[segment - 1]
			var last: Vector2 = link.points[segment]
			var direction: Vector2 = (last - first).normalized().orthogonal() * 0.6
			var steps: int = maxi(1, ceili(first.distance_to(last) / CELL_SIZE_KM))
			for step in range(steps + 1):
				var along: Vector2 = first.lerp(last, float(step) / float(steps))
				for side in [-1.0, 0.0, 1.0]:
					var point: Vector2 = along + direction * side
					var grid: Vector2i = StateGeography.cell_grid_at_point(region.generation_seed, point)
					var center: Vector2 = StateGeography.cell_site(region.generation_seed, grid)
					var city_id: int = from_city if local_city != null and local_city.contains_point(center) else region.city_id_at_point(center)
					if city_id < 0:
						continue
					var key: String = "%d:%d:%d" % [city_id, grid.x, grid.y]
					if region.development_candidate_keys.has(key):
						var candidate: Dictionary = region.development_candidates[region.development_candidate_keys[key]]
						candidate["frontage_link_id"] = link.id
						continue
					var polygon: PackedVector2Array = StateGeography.cell_polygon(region, city_id, grid)
					if StateGeography.polygon_area(polygon) < 0.4:
						continue
					var candidate_id: int = region.development_candidates.size()
					region.development_candidates.append({
						"id": candidate_id, "key": key, "city_id": city_id, "grid": grid,
						"polygon": polygon, "center_km": center, "frontage_link_id": link.id,
						"neighborhood_id": int(occupied.get(key, -1)),
					})
					region.development_candidate_keys[key] = candidate_id
					var cell_key: String = "%d:%d" % [grid.x, grid.y]
					if not region.development_candidate_cells.has(cell_key):
						region.development_candidate_cells[cell_key] = []
					region.development_candidate_cells[cell_key].append(candidate_id)


static func set_approval(region, candidate_id: int, approved: bool) -> Dictionary:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return {"ok": false, "reason": "Select a neighborhood candidate."}
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	if not approved:
		if neighborhood_id < 0:
			return {"ok": false, "reason": "This land is not approved."}
		var neighborhood = region.neighborhoods[neighborhood_id]
		neighborhood.development_approved = false
		neighborhood.migration_remainder = minf(neighborhood.migration_remainder, 0.0)
		neighborhood.job_growth_remainder = minf(neighborhood.job_growth_remainder, 0.0)
		return {"ok": true, "new_neighborhood": false}
	if neighborhood_id >= 0:
		region.neighborhoods[neighborhood_id].development_approved = true
		return {"ok": true, "new_neighborhood": false}
	var link_index: int = RoadGraph.link_index(region, int(candidate["frontage_link_id"]))
	if link_index < 0 or region.road_links[link_index].road_class != RoadLinkData.ARTERIAL:
		return {"ok": false, "reason": "This land needs a connected arterial."}
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var frontage = region.road_links[link_index]
	if rooted[frontage.from_node_id] == 0 or rooted[frontage.to_node_id] == 0:
		return {"ok": false, "reason": "Connect this arterial to an established city."}
	var polygon: PackedVector2Array = candidate["polygon"]
	var center: Vector2 = candidate["center_km"]
	var access_point: Vector2 = RoadPlanner.closest_point(frontage.points, center)
	var access_node_id: int = -1
	for node_id in [frontage.from_node_id, frontage.to_node_id]:
		if region.road_nodes[node_id].position_km.distance_to(access_point) < 0.2:
			access_node_id = node_id
			break
	if access_node_id < 0:
		var junction: Dictionary = RoadPlanner.add_junction(region, access_point, frontage.id)
		if not junction["ok"]:
			return junction
		access_node_id = junction["node_id"]
	var neighborhood = RegionGenerator.append_neighborhood(region, candidate["city_id"], polygon, candidate["grid"])
	neighborhood.development_approved = true
	neighborhood.development_state = "Developing"
	neighborhood.development_jobs_by_skill = neighborhood.jobs_by_skill.duplicate()
	neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
	neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
	neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
	neighborhood.baseline_occupancy = 0.75
	neighborhood.rent_level = float(neighborhood.monthly_rent)
	var total_jobs := 0
	var weighted_income := 0.0
	for skill in ["Entry", "Skilled", "Professional"]:
		var count: int = neighborhood.jobs_by_skill[skill]
		total_jobs += count
		weighted_income += float(count) * float({"Entry": 3000.0, "Skilled": 4300.0, "Professional": 6500.0}[skill])
	neighborhood.development_income = roundi(weighted_income / maxf(1.0, float(total_jobs)) * 1.1)
	neighborhood.households = 0
	neighborhood.population = 0
	neighborhood.jobs = 0
	neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
	neighborhood.shopping_attraction = 0.0
	neighborhood.monthly_rent = 0
	candidate["neighborhood_id"] = neighborhood.id
	var gateway = RoadNodeData.new()
	gateway.id = region.road_nodes.size()
	gateway.kind = "Neighborhood"
	gateway.neighborhood_id = neighborhood.id
	gateway.city_id = neighborhood.city_id
	gateway.position_km = neighborhood.position_km
	if gateway.position_km.distance_to(region.road_nodes[access_node_id].position_km) < 0.05:
		for vertex in polygon:
			if vertex.distance_to(region.road_nodes[access_node_id].position_km) >= 0.05:
				gateway.position_km = vertex
				break
	region.road_nodes.append(gateway)
	region.neighborhood_gateway_node_ids.append(gateway.id)
	region.neighborhood_spoke_link_ids.append(region.next_road_link_id)
	var spoke = RoadLinkData.new()
	spoke.id = region.next_road_link_id
	region.next_road_link_id += 1
	spoke.from_node_id = gateway.id
	spoke.to_node_id = access_node_id
	spoke.road_class = RoadLinkData.ARTERIAL
	spoke.lanes_per_direction = 1
	spoke.points = RoadRouteBuilder.build(region, gateway.id, access_node_id, spoke.road_class)
	spoke.recalculate_length()
	spoke.owner_jurisdiction_id = region.road_owner_for_points(spoke.points, spoke.road_class)
	region.road_links.append(spoke)
	region.road_geometry_revision += 1
	region.neighborhood_development_connected.append(0)
	region.neighborhood_accessible.append(0)
	region.accessibility.append(0.0)
	RoadPlanner.refresh_upkeep(region)
	return {"ok": true, "new_neighborhood": true}
