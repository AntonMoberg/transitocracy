extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const StreetLayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")


static func generate(region) -> void:
	region.road_geometry_revision += 1
	region.street_spatial_cache = {}
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.city_hub_node_ids.clear()
	region.city_route_node_ids.clear()
	region.neighborhood_development_connected.clear()
	region.neighborhood_spoke_link_ids.clear()
	region.next_road_link_id = 0
	region.next_road_project_id = 0
	for neighborhood in region.neighborhoods:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = neighborhood.position_km
		node.kind = "Neighborhood"
		node.neighborhood_id = neighborhood.id
		node.city_id = neighborhood.city_id
		region.road_nodes.append(node)
		region.neighborhood_gateway_node_ids.append(node.id)
		region.neighborhood_spoke_link_ids.append(-1)
	for city in region.cities:
		var hub = RoadNodeData.new()
		hub.id = region.road_nodes.size()
		hub.position_km = city["center_km"]
		hub.kind = "City"
		hub.city_id = city["id"]
		hub.is_interchange = region.starting_city_ids.has(city["id"])
		hub.interchange_owner_jurisdiction_id = city["jurisdiction_id"] if hub.is_interchange else -1
		region.road_nodes.append(hub)
		region.city_hub_node_ids.append(hub.id)
	for city in region.cities:
		_build_city_arterials(region, city)
	var connected: Array[int] = [region.starting_city_ids[0]]
	var highway_edges: Array[Vector2i] = []
	while connected.size() < region.starting_city_ids.size():
		var best_from := -1
		var best_to := -1
		var best_distance := INF
		for from_city in connected:
			for to_city in region.starting_city_ids:
				if connected.has(to_city):
					continue
				var distance: float = region.cities[from_city]["center_km"].distance_squared_to(region.cities[to_city]["center_km"])
				if distance < best_distance:
					best_distance = distance
					best_from = from_city
					best_to = to_city
		highway_edges.append(Vector2i(best_from, best_to))
		connected.append(best_to)
	var highway_approaches: Dictionary = {}
	for city_id in region.starting_city_ids:
		var neighbors: Array[int] = []
		for edge in highway_edges:
			if edge.x == city_id:
				neighbors.append(edge.y)
			elif edge.y == city_id:
				neighbors.append(edge.x)
		if neighbors.size() < 2:
			continue
		var center: Vector2 = region.cities[city_id]["center_km"]
		var best_first := 0
		var best_second := 1
		var best_dot := INF
		for first_index in range(neighbors.size()):
			var first_direction: Vector2 = (region.cities[neighbors[first_index]]["center_km"] - center).normalized()
			for second_index in range(first_index + 1, neighbors.size()):
				var second_direction: Vector2 = (region.cities[neighbors[second_index]]["center_km"] - center).normalized()
				var alignment: float = first_direction.dot(second_direction)
				if alignment < best_dot:
					best_dot = alignment
					best_first = first_index
					best_second = second_index
		var first: Vector2 = (region.cities[neighbors[best_first]]["center_km"] - center).normalized()
		var second: Vector2 = (region.cities[neighbors[best_second]]["center_km"] - center).normalized()
		# One pair is the continuous through road; further links are branches.
		var through: Vector2 = second - first
		if through.length_squared() < 0.000001:
			through = first.orthogonal()
		var axis: Vector2 = through.normalized()
		highway_approaches[city_id] = {neighbors[best_first]: -axis, neighbors[best_second]: axis}
	for edge in highway_edges:
		var from_approaches: Dictionary = highway_approaches.get(edge.x, {})
		var to_approaches: Dictionary = highway_approaches.get(edge.y, {})
		var from_tangent: Vector2 = from_approaches.get(edge.y, Vector2.ZERO)
		var to_tangent: Vector2 = -to_approaches.get(edge.x, Vector2.ZERO)
		_add_link(region, region.city_hub_node_ids[edge.x], region.city_hub_node_ids[edge.y], RoadLinkData.HIGHWAY, 2, from_tangent, to_tangent)
	for link in region.road_links:
		if link.road_class != RoadLinkData.COLLECTOR:
			link.owner_jurisdiction_id = region.road_owner_for_points(link.points, link.road_class)


static func _build_city_arterials(region, city: Dictionary) -> void:
	var neighborhood_ids: Array[int] = []
	for neighborhood_id in city["neighborhood_ids"]:
		if region.neighborhoods[neighborhood_id].initially_developed:
			neighborhood_ids.append(neighborhood_id)
	if neighborhood_ids.is_empty():
		return
	var city_id: int = city["id"]
	var area = region.jurisdictions[city["jurisdiction_id"]]
	var hub_id: int = region.city_hub_node_ids[city_id]
	var center: Vector2 = region.road_nodes[hub_id].position_km
	if neighborhood_ids.size() > 4:
		center = area.center_km
		city["center_km"] = center
		region.road_nodes[hub_id].position_km = center
		preload("res://scripts/simulation/street_spatial_index.gd").index_node(preload("res://scripts/simulation/street_spatial_index.gd").cache(region), region.road_nodes[hub_id])
	var columns: int = ceili(sqrt(float(neighborhood_ids.size())))
	var rows: int = ceili(float(neighborhood_ids.size()) / columns)
	var span: float = StreetLayoutGenerator.FRONTAGE_KM
	var depth: float = StreetLayoutGenerator.DEPTH_KM * 2.0
	var axis := Vector2.RIGHT
	var best_score := -1
	for attempt in range(12):
		var trial := Vector2.from_angle(float(attempt) * PI / 12.0 + float(city_id % 7) * 0.1)
		var normal := Vector2(-trial.y, trial.x)
		var score := 0
		for across in [-0.5, 0.5]:
			for along in [-0.5, 0.5]:
				if area.contains_point(center + trial * across * columns * span + normal * along * rows * depth):
					score += 1
		if score > best_score:
			best_score = score
			axis = trial
	var normal := Vector2(-axis.y, axis.x)
	var trunk_column: int = columns / 2
	var trunk_row: int = rows / 2
	var origin: Vector2 = center - axis * trunk_column * span - normal * trunk_row * depth
	var arterial_rows: Array[int] = []
	for row in range(rows + 1):
		if posmod(row - trunk_row, 2) == 0:
			arterial_rows.append(row)
	var shape_rng := RandomNumberGenerator.new()
	shape_rng.seed = hash("%d:city-streets:%d" % [region.generation_seed, city_id])
	var style: int = 0 if region.starting_city_ids.find(city_id) % 5 == 4 else shape_rng.randi_range(1, 4)
	var bend_phase: float = shape_rng.randf_range(0.0, TAU)
	var grid: Dictionary = {}
	var positions: Dictionary = {}
	var horizontal: Dictionary = {}
	var vertical: Dictionary = {}
	var built_horizontal: Dictionary = {}
	var built_vertical: Dictionary = {}
	for row in range(-1, rows + 2):
		for column in range(-1, columns + 2):
			var point: Vector2 = origin + axis * column * span + normal * row * depth
			if style != 0 and column != trunk_column and not arterial_rows.has(row):
				var across: float = float(column) - float(columns) * 0.5
				var inward: float = float(row) - float(rows) * 0.5
				point += axis * span * 0.18 * (sin(inward * 1.1 + bend_phase) - sin(bend_phase) + sin(across * 1.4) * 0.5)
				point += normal * depth * 0.16 * (cos(across * 1.2 + bend_phase) - cos(bend_phase) + sin(inward * 1.5) * 0.5)
			positions[Vector2i(column, row)] = point
			if column != trunk_column and not arterial_rows.has(row):
				continue
			if not region.jurisdictions[0].contains_point(point):
				continue
			grid[Vector2i(column, row)] = StreetNetwork.ensure_node(region, point, city_id)
	for row in range(-1, rows + 2):
		var corridor_id: int = region.next_road_link_id
		var station := 0.0
		for column in range(-1, columns + 1):
			var first := Vector2i(column, row)
			var second := Vector2i(column + 1, row)
			var first_point: Vector2 = positions[first]
			var second_point: Vector2 = positions[second]
			var points: PackedVector2Array = _urban_boundary_points(first_point, second_point, 0 if arterial_rows.has(row) else style, shape_rng, region.jurisdictions[0].polygon_km)
			horizontal[first] = points
			if not arterial_rows.has(row):
				continue
			if not grid.has(first) or not grid.has(second):
				continue
			if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, first_point, second_point):
				continue
			_add_street_arterial(region, grid[first], grid[second], corridor_id, station, points)
			station += region.road_links[-1].length_km
			built_horizontal[first] = true
	for column in range(-1, columns + 2):
		var corridor_id: int = region.next_road_link_id
		var station := 0.0
		for row in range(-1, rows + 1):
			var first := Vector2i(column, row)
			var second := Vector2i(column, row + 1)
			var first_point: Vector2 = positions[first]
			var second_point: Vector2 = positions[second]
			var points: PackedVector2Array = _urban_boundary_points(first_point, second_point, 0 if column == trunk_column else style, shape_rng, region.jurisdictions[0].polygon_km)
			vertical[first] = points
			if column != trunk_column:
				continue
			if not grid.has(first) or not grid.has(second):
				continue
			if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, first_point, second_point):
				continue
			_add_street_arterial(region, grid[first], grid[second], corridor_id, station, points)
			station += region.road_links[-1].length_km
			built_vertical[first] = true
	for local_id in range(neighborhood_ids.size()):
		var address := Vector2i(local_id % columns, local_id / columns)
		if not horizontal.has(address) or not horizontal.has(address + Vector2i.DOWN) or not vertical.has(address) or not vertical.has(address + Vector2i.RIGHT):
			continue
		var key: String = "starter:%d:%d" % [city_id, local_id]
		var boundaries: Array = [horizontal[address], vertical[address + Vector2i.RIGHT], horizontal[address + Vector2i.DOWN], vertical[address]]
		var arterial_sides := PackedByteArray([int(built_horizontal.has(address)), int(built_vertical.has(address + Vector2i.RIGHT)), int(built_horizontal.has(address + Vector2i.DOWN)), int(built_vertical.has(address))])
		var layout = StreetLayoutGenerator.generate(region, city_id, horizontal[address], key, [], true, boundaries, arterial_sides)
		if layout.polygon.size() >= 3:
			StreetNetwork.attach(region, region.neighborhoods[neighborhood_ids[local_id]], layout, true)
	if not grid.values().has(hub_id):
		var nearest_id := -1
		var nearest_distance := INF
		for node_id in grid.values():
			var distance: float = region.road_nodes[node_id].position_km.distance_to(center)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_id = node_id
		if nearest_id >= 0:
			_add_link(region, hub_id, nearest_id, RoadLinkData.ARTERIAL, 1)


static func _urban_boundary_points(first: Vector2, last: Vector2, style: int, rng: RandomNumberGenerator, land: PackedVector2Array) -> PackedVector2Array:
	if style < 2:
		return PackedVector2Array([first, last])
	var direction: Vector2 = last - first
	var offset: Vector2 = direction.normalized().orthogonal() * direction.length() * rng.randf_range(0.06, 0.12) * (-1.0 if rng.randf() < 0.5 else 1.0)
	var points: PackedVector2Array = PackedVector2Array([first, first.lerp(last, 0.35) + offset, first.lerp(last, 0.70) + offset, last]) if style == 3 else PackedVector2Array([first, first.lerp(last, rng.randf_range(0.35, 0.65)) + offset, last])
	for segment in range(1, points.size()):
		if not StateGeography.segment_on_land(land, points[segment - 1], points[segment]):
			return PackedVector2Array([first, last])
	return points


static func _add_street_arterial(region, first: int, last: int, corridor_id: int, station: float, points: PackedVector2Array) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = first
	link.to_node_id = last
	link.road_class = RoadLinkData.ARTERIAL
	link.points = points
	link.corridor_id = corridor_id
	link.corridor_start_km = station
	link.owner_jurisdiction_id = region.city_jurisdiction_ids[region.road_nodes[first].city_id]
	link.recalculate_length()
	region.road_links.append(link)




static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int, from_tangent: Vector2 = Vector2.ZERO, to_tangent: Vector2 = Vector2.ZERO, land_certified: bool = false) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.corridor_id = link.id
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = RoadRouteBuilder.build(region, from_id, to_id, road_class, PackedVector2Array(), from_tangent, to_tangent, land_certified)
	link.recalculate_length()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points, road_class)
	region.road_links.append(link)
