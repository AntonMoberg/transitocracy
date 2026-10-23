extends RefCounted

const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


static func _mark_canonical_edges(layout) -> void:
	for edge_id in range(layout.edges.size()):
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if not layout.canonical_nodes.has(first) or not layout.canonical_nodes.has(last):
			continue
		var first_key: String = layout.canonical_nodes[first]
		var last_key: String = layout.canonical_nodes[last]
		layout.canonical_edges[edge_id] = "%s|%s" % [first_key, last_key] if first_key < last_key else "%s|%s" % [last_key, first_key]


static func _layout_edge_path(layout, edge_id: int) -> PackedVector2Array:
	if layout.edge_paths.has(edge_id):
		return layout.edge_paths[edge_id]
	var edge: Vector2 = layout.edges[edge_id]
	return PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]])


static func _near_field_arterial(first: Vector2, last: Vector2, field_context: Dictionary, tolerance: float) -> bool:
	var direction: Vector2 = (last - first).normalized()
	if direction == Vector2.ZERO:
		return false
	for road in field_context.get("roads", []):
		if absf(direction.dot(road["axis"])) < 0.93:
			continue
		var close := true
		for t in [0.25, 0.5, 0.75]:
			var point: Vector2 = first.lerp(last, t)
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, road["first"], road["last"])) >= tolerance:
				close = false
				break
		if close:
			return true
	return false


static func triangulate(polygon: PackedVector2Array) -> PackedInt32Array:
	var local := PackedVector2Array()
	for point in polygon:
		local.append(point - polygon[0])
	return Geometry2D.triangulate_polygon(local)


static func _append_edge(layout, first: int, last: int, road_class: String, phase: int) -> void:
	layout.edges.append(Vector2(first, last))
	layout.classes.append(road_class)
	layout.phases.append(phase)
	var length: float = layout.nodes[first].distance_to(layout.nodes[last])
	layout.lengths.append(length)
	if road_class != Roads.ARTERIAL:
		layout.phase_costs[phase - 1] += roundi(length * Roads.construction_cost(road_class))
		layout.phase_upkeep[phase - 1] += length * Roads.upkeep(road_class)


static func _append_block_polygon(layout, polygon: PackedVector2Array, nodes: PackedInt32Array, phase: int, seed_value: int, park: bool, fringe: bool) -> void:
	layout.blocks.append({"polygon": polygon, "nodes": nodes, "phase": phase, "seed": seed_value, "park": park, "fringe": fringe, "area_ha": Geography.polygon_area(polygon) * 100.0})


# Organic districts keep the through collectors, but join selected pairs of
# local blocks across a removed street.  This produces loops and occasional
# dead ends in the street graph rather than merely bowing a rectangular grid.


static func _build_core_paths(layout, boundary_corners: PackedInt32Array = PackedInt32Array()) -> void:
	var neighbors: Dictionary = {}
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] != Roads.COLLECTOR:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		for node_id in [int(edge.x), int(edge.y)]:
			if not neighbors.has(node_id):
				neighbors[node_id] = []
			neighbors[node_id].append(edge_id)
	var visited: Dictionary = {}
	for node_id in neighbors:
		var phase_boundary: bool = neighbors[node_id].size() == 2 and layout.phases[neighbors[node_id][0]] != layout.phases[neighbors[node_id][1]]
		if neighbors[node_id].size() == 2 and not layout.arterial_nodes.has(node_id) and not boundary_corners.has(node_id) and not phase_boundary:
			continue
		for first_edge in neighbors[node_id]:
			if visited.has(first_edge):
				continue
			var points := PackedVector2Array([layout.nodes[node_id]])
			var edges := PackedInt32Array()
			var cursor: int = node_id
			var edge_id: int = first_edge
			var stage := 1
			while not visited.has(edge_id):
				visited[edge_id] = true
				edges.append(edge_id)
				stage = maxi(stage, layout.phases[edge_id])
				var edge: Vector2 = layout.edges[edge_id]
				var forward: bool = int(edge.x) == cursor
				cursor = int(edge.y) if forward else int(edge.x)
				var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
				if not forward:
					path = path.duplicate()
					path.reverse()
				for point_id in range(1, path.size()):
					points.append(path[point_id])
				phase_boundary = neighbors[cursor].size() == 2 and layout.phases[neighbors[cursor][0]] != layout.phases[neighbors[cursor][1]]
				if neighbors[cursor].size() != 2 or layout.arterial_nodes.has(cursor) or boundary_corners.has(cursor) or phase_boundary:
					break
				edge_id = neighbors[cursor][0] if neighbors[cursor][1] == edge_id else neighbors[cursor][1]
			layout.core_paths.append({"from": node_id, "to": cursor, "points": points, "edges": edges, "phase": stage})
