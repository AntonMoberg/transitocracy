extends RefCounted

# Street families belong to the city, not to a candidate neighborhood.  The
# coordinates below remain stable when candidates are refreshed or approved in
# a different order. An arterial can establish a separate grid family on
# undeveloped land, but individual city-grid junctions must never drift.
static func guide(region, city_id: int, _point: Vector2) -> Dictionary:
	if city_id < 0 or city_id >= region.cities.size():
		return {}
	var city: Dictionary = region.cities[city_id]
	var base: Dictionary = city.get("street_plan", {})
	if base.is_empty():
		var pattern := RandomNumberGenerator.new()
		pattern.seed = hash("%d:block-pattern:starter-city:%d" % [region.generation_seed, city_id])
		var long_spacing: float = [0.16, 0.18, 0.20, 0.22][pattern.randi_range(0, 3)]
		var short_spacing: float = [0.08, 0.09, 0.10][pattern.randi_range(0, 2)]
		var long_along: bool = pattern.randf() < 0.8
		base = {
			"axis": city.get("street_axis", Vector2.RIGHT),
			"origin": city["center_km"],
			"column_spacing": long_spacing if long_along else short_spacing,
			"row_spacing": short_spacing if long_along else long_spacing,
		}
	var result: Dictionary = base.duplicate(true)
	var axis: Vector2 = result["axis"]
	if axis.length_squared() < 0.5:
		axis = Vector2.RIGHT
	# A district boundary cannot start a new lattice. Arterials affect the
	# direction field used to trace unbuilt streets, not this city's addresses.
	result["axis"] = axis.normalized()
	result["plan_key"] = "city:%d" % city_id
	return result


static func address(point: Vector2, plan: Dictionary) -> Vector2i:
	var axis: Vector2 = plan.get("axis", Vector2.RIGHT).normalized()
	var offset: Vector2 = point - plan.get("origin", Vector2.ZERO)
	return Vector2i(roundi(offset.dot(axis) / maxf(0.01, float(plan.get("column_spacing", 0.18)))), roundi(offset.dot(axis.orthogonal()) / maxf(0.01, float(plan.get("row_spacing", 0.09)))))


static func base_junction(plan: Dictionary, cell: Vector2i) -> Vector2:
	var axis: Vector2 = plan.get("axis", Vector2.RIGHT).normalized()
	return plan.get("origin", Vector2.ZERO) + axis * (float(cell.x) * float(plan.get("column_spacing", 0.18))) + axis.orthogonal() * (float(cell.y) * float(plan.get("row_spacing", 0.09)))


# Every regular-grid junction has one absolute city address. In particular, a
# nearby arterial or a district's frontage cannot bend a row of existing
# addresses. A separately oriented street family uses its own addresses.
static func junction(region, city_id: int, cell: Vector2i, plan: Dictionary, _organic: bool = false, _supplied_context: Dictionary = {}) -> Vector2:
	var permanent_key: String = "%d:%d:%d" % [city_id, cell.x, cell.y]
	if region.urban_locked_junctions.has(permanent_key):
		return region.urban_locked_junctions[permanent_key]
	return base_junction(plan, cell)


static func block_key(city_id: int, cell: Vector2i, organic: bool = false) -> String:
	return "%d:%d:%d:%d" % [city_id, cell.x, cell.y, int(organic)]


# Turn a suggested area into a connected set of whole city-grid blocks. The
# outer edge is assembled from block sides, so neighboring suggestions cannot
# invent unrelated street cuts through the same block.
static func block_outline(plan: Dictionary, polygon: PackedVector2Array, include_edge_cells: bool = false) -> PackedVector2Array:
	if polygon.size() < 3:
		return PackedVector2Array()
	var minimum := Vector2i(2147483647, 2147483647)
	var maximum := Vector2i(-2147483647, -2147483647)
	for vertex in polygon:
		var cell: Vector2i = address(vertex, plan)
		minimum.x = mini(minimum.x, cell.x - 2)
		minimum.y = mini(minimum.y, cell.y - 2)
		maximum.x = maxi(maximum.x, cell.x + 2)
		maximum.y = maxi(maximum.y, cell.y + 2)
	if (maximum.x - minimum.x + 1) * (maximum.y - minimum.y + 1) > 1200:
		return polygon
	var selected: Dictionary = {}
	for y in range(minimum.y, maximum.y):
		for x in range(minimum.x, maximum.x):
			var center: Vector2 = (base_junction(plan, Vector2i(x, y)) + base_junction(plan, Vector2i(x + 1, y + 1))) * 0.5
			var inside: bool = Geometry2D.is_point_in_polygon(center, polygon)
			if include_edge_cells and not inside:
				for corner in [Vector2i(x, y), Vector2i(x + 1, y), Vector2i(x + 1, y + 1), Vector2i(x, y + 1)]:
					if Geometry2D.is_point_in_polygon(base_junction(plan, corner), polygon):
						inside = true
						break
			if inside:
				selected[Vector2i(x, y)] = true
	if selected.is_empty():
		return PackedVector2Array()
	var visited: Dictionary = {}
	var largest: Dictionary = {}
	for start in selected:
		if visited.has(start):
			continue
		var component: Dictionary = {}
		var queue: Array[Vector2i] = [start]
		visited[start] = true
		var cursor := 0
		while cursor < queue.size():
			var cell: Vector2i = queue[cursor]
			cursor += 1
			component[cell] = true
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbor: Vector2i = cell + step
				if selected.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		if component.size() > largest.size():
			largest = component
	var edges: Dictionary = {}
	for cell in largest:
		var c: Vector2i = cell
		if not largest.has(c + Vector2i.UP):
			edges[c] = c + Vector2i.RIGHT
		if not largest.has(c + Vector2i.RIGHT):
			edges[c + Vector2i.RIGHT] = c + Vector2i.ONE
		if not largest.has(c + Vector2i.DOWN):
			edges[c + Vector2i.ONE] = c + Vector2i.DOWN
		if not largest.has(c + Vector2i.LEFT):
			edges[c + Vector2i.DOWN] = c
	var loops: Array[PackedVector2Array] = []
	while not edges.is_empty():
		var first: Vector2i = edges.keys()[0]
		var cursor: Vector2i = first
		var loop := PackedVector2Array()
		for step in range(edges.size() + 1):
			if not edges.has(cursor):
				break
			loop.append(base_junction(plan, cursor))
			var next: Vector2i = edges[cursor]
			edges.erase(cursor)
			cursor = next
			if cursor == first:
				break
		if cursor == first and loop.size() >= 3:
			loops.append(loop)
	var best := PackedVector2Array()
	var best_area := 0.0
	for loop in loops:
		var signed_area := 0.0
		for index in range(loop.size()):
			signed_area += loop[index].cross(loop[(index + 1) % loop.size()])
		var area: float = absf(signed_area) * 0.5
		if area > best_area:
			best_area = area
			best = loop
	return best
