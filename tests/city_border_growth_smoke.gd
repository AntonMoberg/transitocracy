extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const NodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const BorderSeams = preload("res://scripts/simulation/city_border_seams.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Growth = preload("res://scripts/simulation/graph_growth_planner.gd")
const UrbanRouting = preload("res://scripts/simulation/urban_routing.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionData.new()
	region.generation_seed = 7241
	var state = _area(0, Jurisdiction.STATE, -1, _rect(0.0, 0.0, 8.0, 4.0))
	var west = _area(1, Jurisdiction.CITY, 0, _rect(0.0, 0.0, 4.0, 4.0))
	var east = _area(2, Jurisdiction.CITY, 0, _rect(4.0, 0.0, 8.0, 4.0))
	region.jurisdictions = [state, west, east]
	region.city_jurisdiction_ids.assign([1, 2])
	region.cities.assign([
		{"id": 0, "center_km": Vector2(3.0, 2.0), "neighborhood_ids": [0]},
		{"id": 1, "center_km": Vector2(4.9, 2.0), "neighborhood_ids": []},
	])
	region.starting_city_ids.assign([0])
	region.city_hub_node_ids.assign([0, -1])
	var hub = _node(0, Vector2(3.5, 2.0), 0)
	var approach = _node(1, Vector2(3.7, 2.0), 0)
	region.road_nodes = [hub, approach]
	var access = Roads.new()
	access.id = 0
	access.from_node_id = 0
	access.to_node_id = 1
	access.road_class = Roads.COLLECTOR
	access.points = PackedVector2Array([hub.position_km, approach.position_km])
	access.recalculate_length()
	region.road_links = [access]
	region.next_road_link_id = 1
	var layout = Layout.new()
	layout.city_id = 0
	layout.polygon = _rect(2.8, 1.5, 3.84, 2.5)
	layout.bounds = Geography._bounds(layout.polygon)
	layout.nodes = PackedVector2Array([approach.position_km, hub.position_km])
	layout.core_paths = [{"from": 0, "to": 1, "phase": 1}]
	BorderSeams.plan(region, layout)
	if layout.border_seams.is_empty() or layout.phase_costs[0] <= 0:
		_fail("Border frontage was not planned and charged to the first city.")
		return
	var neighborhood = Neighborhood.new()
	neighborhood.id = 0
	neighborhood.city_id = 0
	neighborhood.street_layout = layout
	neighborhood.development_plan = Plan.new()
	neighborhood.development_plan.completed_phase = 1
	neighborhood.development_plan.core_node_ids[0] = 1
	region.neighborhoods = [neighborhood]
	var resolve_node: Callable = func(point: Vector2, city_id: int) -> int: return StreetNetwork.ensure_node(region, point, city_id)
	BorderSeams.install(region, neighborhood, resolve_node)
	if region.city_border_seams.size() != layout.border_seams.size():
		_fail("Shared collector pieces were not installed exactly once.")
		return
	var link_count: int = region.road_links.size()
	BorderSeams.install(region, neighborhood, resolve_node)
	if region.road_links.size() != link_count:
		_fail("Installing the same city border twice duplicated roads.")
		return
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var found_border := false
	for link in region.road_links:
		if link.border_city_ids == Vector2i(0, 1) and rooted[link.from_node_id] != 0 and rooted[link.to_node_id] != 0:
			found_border = true
	if not found_border:
		_fail("The shared collector is not connected to the first city.")
		return
	var east_layout = Layout.new()
	east_layout.city_id = 1
	east_layout.polygon = _rect(4.16, 1.5, 5.2, 2.5)
	east_layout.bounds = Geography._bounds(east_layout.polygon)
	east_layout.nodes = PackedVector2Array([Vector2(4.3, 2.0), Vector2(4.5, 2.0)])
	east_layout.core_paths = [{"from": 0, "to": 1, "phase": 1}]
	BorderSeams.plan(region, east_layout)
	if east_layout.border_seams.is_empty():
		_fail("The neighboring city's frontage did not find the same shared collector.")
		return
	for seam in east_layout.border_seams:
		if seam["costed"]:
			_fail("The neighboring city was charged for an already built border collector.")
			return
	UrbanRouting.prepare(region)
	if not region.urban_route_cache.has(1):
		_fail("The neighboring city's routing graph cannot use the shared collector.")
		return
	var east_growth := false
	var east_candidate = null
	for proposal in Growth.proposals(region):
		if proposal["layout"].city_id == 1:
			east_growth = true
			east_candidate = proposal
			break
	if not east_growth:
		_fail("The neighboring city did not receive a buildable district from the border collector.")
		return
	var fringe_count := 0
	for block in east_candidate["layout"].blocks:
		if block.get("fringe", false):
			fringe_count += 1
	var missed_frontage := 0
	for seam in east_candidate["layout"].border_seams:
		for fraction in [0.25, 0.5, 0.75]:
			var sample: Vector2 = seam["from"].lerp(seam["to"], fraction) + Vector2(0.05, 0.0)
			var inside: bool = Geometry2D.is_point_in_polygon(sample, east_candidate["layout"].polygon)
			if not inside:
				missed_frontage += 1
	if fringe_count == 0 or missed_frontage > 2:
		_fail("The neighboring city's border road extends beyond its developed frontage.")
		return
	region.urban_sector_claims["1:2:2"] = 0
	east_growth = false
	for proposal in Growth.proposals(region):
		if proposal["layout"].city_id == 1:
			east_growth = true
			break
	if not east_growth:
		_fail("A city with existing districts lost its border growth opportunity.")
		return
	region.urban_sector_claims.erase("1:2:2")
	var east_neighborhood = Neighborhood.new()
	east_neighborhood.id = 1
	east_neighborhood.city_id = 1
	east_neighborhood.street_layout = east_candidate["layout"]
	east_neighborhood.development_plan = Plan.new()
	region.neighborhoods.append(east_neighborhood)
	region.cities[1]["neighborhood_ids"].append(1)
	region.neighborhood_gateway_node_ids.assign([-1, -1])
	region.neighborhood_spoke_link_ids.assign([-1, -1])
	if not StreetNetwork.open_phase(region, east_neighborhood, 1):
		_fail("A neighboring city could not open its first district phase from the shared collector.")
		return
	rooted = RoadGraph.nodes_connected_to_start(region)
	var east_access := false
	for node_id in east_neighborhood.access_node_ids:
		if rooted[node_id] != 0:
			east_access = true
	if not east_access:
		_fail("The neighboring district's streets are not connected across the city border.")
		return
	var direct_crossing := false
	for node in region.road_nodes:
		if absf(node.position_km.x - 4.0) > 0.005:
			continue
		var east_connector := false
		var shared_collector := false
		for link in region.road_links:
			if link.from_node_id != node.id and link.to_node_id != node.id:
				continue
			if link.border_city_ids == Vector2i(0, 1):
				shared_collector = true
			if link.managed_neighborhood_id >= 0 and region.neighborhoods[link.managed_neighborhood_id].city_id == 1:
				east_connector = true
		if shared_collector and east_connector and rooted[node.id] != 0:
			direct_crossing = true
			break
	if not direct_crossing:
		_fail("The neighboring city's streets do not join the rooted border collector.")
		return
	if not _generated_city_border_can_be_planned():
		_fail("Generated city polygons did not admit a shared border collector.")
		return
	if not _arterial_endpoint_seeds_existing_city():
		_fail("A rooted arterial near approved land did not seed growth across the city line.")
		return
	print("Shared city collector is funded once, connected, and seeds neighboring growth.")
	quit(0)


func _generated_city_border_can_be_planned() -> bool:
	var generated = RegionGenerator.generate_region(42)
	for city_id in range(generated.cities.size()):
		var first = generated.jurisdictions[generated.city_jurisdiction_ids[city_id]]
		for edge_id in range(first.polygon_km.size()):
			var a: Vector2 = first.polygon_km[edge_id]
			var b: Vector2 = first.polygon_km[(edge_id + 1) % first.polygon_km.size()]
			if a.distance_to(b) < 0.75:
				continue
			var midpoint: Vector2 = (a + b) * 0.5
			for other_id in range(generated.cities.size()):
				if other_id == city_id or not generated.jurisdictions[generated.city_jurisdiction_ids[other_id]].contains_point(midpoint):
					continue
				var layout = Layout.new()
				layout.city_id = city_id
				layout.polygon = _rect(midpoint.x - 0.25, midpoint.y - 0.25, midpoint.x + 0.25, midpoint.y + 0.25)
				layout.bounds = Geography._bounds(layout.polygon)
				layout.nodes = PackedVector2Array([midpoint, midpoint + Vector2(0.1, 0.0)])
				layout.core_paths = [{"from": 0, "to": 1, "phase": 1}]
				BorderSeams.plan(generated, layout)
				if not layout.border_seams.is_empty():
					return true
	return false


func _arterial_endpoint_seeds_existing_city() -> bool:
	var region = RegionData.new()
	region.generation_seed = 7241
	region.jurisdictions = [
		_area(0, Jurisdiction.STATE, -1, _rect(0.0, 0.0, 8.0, 4.0)),
		_area(1, Jurisdiction.CITY, 0, _rect(0.0, 0.0, 4.0, 4.0)),
		_area(2, Jurisdiction.CITY, 0, _rect(4.0, 0.0, 8.0, 4.0)),
	]
	region.city_jurisdiction_ids.assign([1, 2])
	region.cities.assign([
		{"id": 0, "center_km": Vector2(3.0, 2.0), "neighborhood_ids": [0]},
		{"id": 1, "center_km": Vector2(6.0, 2.0), "neighborhood_ids": []},
	])
	region.starting_city_ids.assign([0])
	region.city_hub_node_ids.assign([0, -1])
	var developed = Neighborhood.new()
	developed.id = 0
	developed.city_id = 0
	developed.jurisdiction_id = 1
	developed.development_approved = true
	developed.position_km = Vector2(3.7, 2.0)
	region.neighborhoods = [developed]
	region.urban_sector_claims["1:50:50"] = 0
	region.road_nodes = [_node(0, Vector2(3.5, 2.0), 0), _node(1, Vector2(3.7, 2.0), 0), _node(2, Vector2(4.4, 2.0), 1)]
	var access = Roads.new()
	access.id = 0
	access.from_node_id = 0
	access.to_node_id = 1
	access.road_class = Roads.COLLECTOR
	access.points = PackedVector2Array([region.road_nodes[0].position_km, region.road_nodes[1].position_km])
	access.recalculate_length()
	var arterial = Roads.new()
	arterial.id = 1
	arterial.from_node_id = 1
	arterial.to_node_id = 2
	arterial.road_class = Roads.ARTERIAL
	arterial.points = PackedVector2Array([region.road_nodes[1].position_km, region.road_nodes[2].position_km])
	arterial.recalculate_length()
	region.road_links = [access, arterial]
	for proposal in Growth.proposals(region, [1]):
		if proposal["layout"].city_id == 1 and proposal["layout"].bounds.get_center().distance_to(region.road_nodes[2].position_km) < 1.5:
			return true
	return false


func _area(id: int, kind: String, parent: int, polygon: PackedVector2Array):
	var area = Jurisdiction.new()
	area.id = id
	area.kind = kind
	area.parent_id = parent
	area.polygon_km = polygon
	Geography.update_bounds(area)
	return area


func _node(id: int, point: Vector2, city_id: int):
	var node = NodeData.new()
	node.id = id
	node.position_km = point
	node.city_id = city_id
	return node


func _rect(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
