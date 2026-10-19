extends RefCounted

const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


# Walk each side of the connected, at-grade arterial graph. The outside walk
# has opposite winding and is discarded; highways never enter this graph.
static func bounded_faces(region, rooted: PackedByteArray) -> Array[Dictionary]:
	var edges: Array[Dictionary] = []
	var directions: Array[Vector2] = []
	var outgoing: Dictionary = {}
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or link.points.size() < 2:
			continue
		if rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		for reverse in [false, true]:
			var points: PackedVector2Array = link.points.duplicate()
			if reverse:
				points.reverse()
			var from_id: int = link.to_node_id if reverse else link.from_node_id
			var to_id: int = link.from_node_id if reverse else link.to_node_id
			var edge_id: int = edges.size()
			edges.append({"from": from_id, "to": to_id, "link_id": link.id, "points": points})
			directions.append((points[1] - points[0]).normalized())
			if not outgoing.has(from_id):
				outgoing[from_id] = []
			outgoing[from_id].append(edge_id)
	for node_id in outgoing:
		outgoing[node_id].sort_custom(func(first, second): return directions[first].angle() < directions[second].angle())
	var visited: Dictionary = {}
	var result: Array[Dictionary] = []
	for start_id in range(edges.size()):
		if visited.has(start_id):
			continue
		var current: int = start_id
		var local: Dictionary = {}
		var polygon := PackedVector2Array()
		var link_ids: Array[int] = []
		var closed := false
		for step in range(edges.size() + 1):
			if local.has(current):
				closed = current == start_id
				break
			local[current] = true
			visited[current] = true
			var edge: Dictionary = edges[current]
			var points: PackedVector2Array = edge["points"]
			polygon.append_array(points.slice(0, points.size() - 1))
			link_ids.append(edge["link_id"])
			var at_node: Array = outgoing.get(edge["to"], [])
			var reverse_index: int = at_node.find(current ^ 1)
			if reverse_index < 0:
				break
			current = at_node[posmod(reverse_index - 1, at_node.size())]
		if not closed or polygon.size() < 3 or _signed_area(polygon) <= 0.0:
			continue
		var area: float = Geography.polygon_area(polygon)
		if area < 0.4 or area > 4.0 or Geometry2D.triangulate_polygon(polygon).is_empty():
			continue
		link_ids.sort()
		var unique_ids: Array[int] = []
		for link_id in link_ids:
			if unique_ids.is_empty() or unique_ids[-1] != link_id:
				unique_ids.append(link_id)
		if unique_ids.size() < 3:
			continue
		var boundaries: Array = _four_sides(polygon)
		if boundaries.size() != 4:
			continue
		result.append({"polygon": polygon, "boundaries": boundaries, "links": unique_ids, "key": "face:%s" % str(unique_ids)})
	return result


static func _four_sides(polygon: PackedVector2Array) -> Array:
	var distances := PackedFloat32Array([0.0])
	for index in range(polygon.size()):
		distances.append(distances[-1] + polygon[index].distance_to(polygon[(index + 1) % polygon.size()]))
	var perimeter: float = distances[-1]
	if perimeter < 0.1:
		return []
	var sides: Array = []
	for quarter in range(4):
		var begin: float = perimeter * float(quarter) * 0.25
		var end: float = perimeter * float(quarter + 1) * 0.25
		var side := PackedVector2Array([_at_distance(polygon, distances, begin)])
		for index in range(1, polygon.size()):
			if distances[index] > begin + 0.000001 and distances[index] < end - 0.000001:
				side.append(polygon[index])
		side.append(_at_distance(polygon, distances, end))
		if quarter >= 2:
			side.reverse()
		sides.append(side)
	return sides


static func _at_distance(polygon: PackedVector2Array, distances: PackedFloat32Array, distance: float) -> Vector2:
	for index in range(polygon.size()):
		if distance <= distances[index + 1]:
			var length: float = distances[index + 1] - distances[index]
			return polygon[index].lerp(polygon[(index + 1) % polygon.size()], (distance - distances[index]) / maxf(length, 0.000001))
	return polygon[0]


static func _signed_area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in range(polygon.size()):
		area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return area * 0.5
