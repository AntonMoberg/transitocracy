extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")


static func generate(region) -> void:
	region.road_geometry_revision += 1
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


static func _build_city_arterials(region, city: Dictionary) -> void:
	var neighborhood_ids: Array[int] = []
	for neighborhood_id in city["neighborhood_ids"]:
		if region.neighborhoods[neighborhood_id].initially_developed:
			neighborhood_ids.append(neighborhood_id)
	if neighborhood_ids.is_empty():
		return
	var city_id: int = city["id"]
	var hub_position: Vector2 = region.road_nodes[region.city_hub_node_ids[city_id]].position_km
	var farthest_id: int = neighborhood_ids[0]
	var farthest_distance := -1.0
	for neighborhood_id in neighborhood_ids:
		var distance: float = hub_position.distance_squared_to(region.neighborhoods[neighborhood_id].position_km)
		if distance > farthest_distance:
			farthest_distance = distance
			farthest_id = neighborhood_id
	var axis: Vector2 = (region.neighborhoods[farthest_id].position_km - hub_position).normalized()
	if axis == Vector2.ZERO:
		axis = Vector2.RIGHT
	var forward: Array[int] = []
	var reverse: Array[int] = []
	for neighborhood_id in neighborhood_ids:
		var delta: Vector2 = region.neighborhoods[neighborhood_id].position_km - hub_position
		if delta.dot(axis) < -0.05:
			reverse.append(neighborhood_id)
		else:
			forward.append(neighborhood_id)
	_build_arterial_arm(region, city_id, forward)
	_build_arterial_arm(region, city_id, reverse)


static func _build_arterial_arm(region, city_id: int, neighborhood_ids: Array[int]) -> void:
	if neighborhood_ids.is_empty():
		return
	var hub_id: int = region.city_hub_node_ids[city_id]
	var hub_position: Vector2 = region.road_nodes[hub_id].position_km
	var endpoint_id: int = neighborhood_ids[0]
	var farthest_distance := -1.0
	for neighborhood_id in neighborhood_ids:
		var distance: float = hub_position.distance_squared_to(region.neighborhoods[neighborhood_id].position_km)
		if distance > farthest_distance:
			farthest_distance = distance
			endpoint_id = neighborhood_id
	var endpoint_node_id: int = region.neighborhood_gateway_node_ids[endpoint_id]
	_add_link(region, hub_id, endpoint_node_id, RoadLinkData.ARTERIAL, 1)
	var trunk_link_id: int = region.next_road_link_id - 1
	var endpoint_spoke_id: int = trunk_link_id
	var trunk_points: PackedVector2Array = region.road_links[-1].points
	var trunk_length: float = region.road_links[-1].length_km
	var branches: Array[Dictionary] = []
	for neighborhood_id in neighborhood_ids:
		if neighborhood_id == endpoint_id:
			continue
		var gateway_id: int = region.neighborhood_gateway_node_ids[neighborhood_id]
		var distance_along: float = _distance_along_route(trunk_points, region.road_nodes[gateway_id].position_km)
		branches.append({"neighborhood_id": neighborhood_id, "distance": distance_along})
	# Splitting from the far end toward the hub leaves the original link ID on
	# the unsplit near-hub section for every subsequent junction.
	branches.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return float(first["distance"]) > float(second["distance"]))
	var parent_node_id: int = endpoint_node_id
	var parent_distance: float = trunk_length
	for branch in branches:
		var gateway_id: int = region.neighborhood_gateway_node_ids[int(branch["neighborhood_id"])]
		var junction_id: int = parent_node_id
		if trunk_length >= 0.5:
			var target_distance: float = clampf(float(branch["distance"]), 0.25, trunk_length - 0.25)
			if parent_distance - target_distance >= 0.25:
				var junction_position: Vector2 = _point_along_route(trunk_points, target_distance)
				junction_id = _split_starter_arterial(region, trunk_link_id, junction_position, city_id)
				if endpoint_spoke_id == trunk_link_id:
					endpoint_spoke_id = region.next_road_link_id - 1
				parent_node_id = junction_id
				parent_distance = target_distance
		_add_link(region, gateway_id, junction_id, RoadLinkData.ARTERIAL, 1)
		region.neighborhood_spoke_link_ids[int(branch["neighborhood_id"])] = region.next_road_link_id - 1
	region.neighborhood_spoke_link_ids[endpoint_id] = endpoint_spoke_id


static func _distance_along_route(points: PackedVector2Array, position: Vector2) -> float:
	var best_distance := INF
	var best_along := 0.0
	var traveled := 0.0
	for segment in range(1, points.size()):
		var first: Vector2 = points[segment - 1]
		var last: Vector2 = points[segment]
		var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(position, first, last)
		var distance: float = nearest.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best_along = traveled + first.distance_to(nearest)
		traveled += first.distance_to(last)
	return best_along


static func _point_along_route(points: PackedVector2Array, distance: float) -> Vector2:
	var traveled := 0.0
	for segment in range(1, points.size()):
		var first: Vector2 = points[segment - 1]
		var last: Vector2 = points[segment]
		var segment_length: float = first.distance_to(last)
		if traveled + segment_length >= distance:
			return first.lerp(last, (distance - traveled) / segment_length)
		traveled += segment_length
	return points[-1]


static func _split_starter_arterial(region, trunk_link_id: int, point: Vector2, city_id: int) -> int:
	var trunk = region.road_links[trunk_link_id]
	var split_segment := 1
	var best_distance := INF
	for segment in range(1, trunk.points.size()):
		var distance: float = Geometry2D.get_closest_point_to_segment(point, trunk.points[segment - 1], trunk.points[segment]).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			split_segment = segment
	var junction = RoadNodeData.new()
	junction.id = region.road_nodes.size()
	junction.position_km = point
	junction.city_id = city_id
	region.road_nodes.append(junction)
	var first := PackedVector2Array()
	var second := PackedVector2Array([point])
	for index in range(split_segment):
		first.append(trunk.points[index])
	first.append(point)
	for index in range(split_segment, trunk.points.size()):
		second.append(trunk.points[index])
	var old_destination: int = trunk.to_node_id
	trunk.to_node_id = junction.id
	trunk.points = first
	trunk.recalculate_length()
	trunk.owner_jurisdiction_id = region.road_owner_for_points(first, RoadLinkData.ARTERIAL)
	var continuation = RoadLinkData.new()
	continuation.id = region.next_road_link_id
	region.next_road_link_id += 1
	continuation.from_node_id = junction.id
	continuation.to_node_id = old_destination
	continuation.road_class = RoadLinkData.ARTERIAL
	continuation.lanes_per_direction = 1
	continuation.points = second
	continuation.recalculate_length()
	continuation.owner_jurisdiction_id = region.road_owner_for_points(second, RoadLinkData.ARTERIAL)
	region.road_links.append(continuation)
	return junction.id


static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int, from_tangent: Vector2 = Vector2.ZERO, to_tangent: Vector2 = Vector2.ZERO, land_certified: bool = false) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = RoadRouteBuilder.build(region, from_id, to_id, road_class, PackedVector2Array(), from_tangent, to_tangent, land_certified)
	link.recalculate_length()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points, road_class)
	region.road_links.append(link)
