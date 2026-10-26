extends RefCounted

# Interpolated land-cover colors use fixed world-space terrain sampling.
# Adjacent tiles share unjittered edge vertices and never need a seam repair.
const Style = preload("res://scripts/ui/map_style.gd")
const CELLS = 16


static func build(terrain, land: PackedVector2Array, origin: Vector2, tile_km: float) -> Dictionary:
	var spacing: float = tile_km / float(CELLS)
	var positions := PackedVector2Array()
	for y in range(CELLS + 1):
		for x in range(CELLS + 1):
			var point: Vector2 = origin + Vector2(x, y) * spacing
			if x > 0 and x < CELLS and y > 0 and y < CELLS:
				var key: int = hash(Vector2i(roundi(point.x / spacing), roundi(point.y / spacing)))
				point += Vector2(float(posmod(key, 997)) / 996.0 - 0.5, float(posmod(key / 997, 991)) / 990.0 - 0.5) * spacing * 0.55
			positions.append(point)
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var color_cache := {}
	for y in range(CELLS):
		for x in range(CELLS):
			var a: int = y * (CELLS + 1) + x
			var b: int = a + 1
			var c: int = a + CELLS + 1
			var d: int = c + 1
			for indices in [Vector3i(a, b, d), Vector3i(a, d, c)]:
				var first: Vector2 = positions[indices.x]
				var second: Vector2 = positions[indices.y]
				var third: Vector2 = positions[indices.z]
				var polygon := PackedVector2Array([first, second, third])
				if Geometry2D.is_point_in_polygon(first, land) and Geometry2D.is_point_in_polygon(second, land) and Geometry2D.is_point_in_polygon(third, land):
					_append_polygon(vertices, colors, polygon, origin, terrain, color_cache)
				else:
					for clipped in Geometry2D.intersect_polygons(polygon, land):
						_append_polygon(vertices, colors, clipped, origin, terrain, color_cache)
	return {"map_vertices": vertices, "map_colors": colors}


static func _append_polygon(vertices: PackedVector2Array, colors: PackedColorArray, polygon: PackedVector2Array, origin: Vector2, terrain, color_cache: Dictionary) -> void:
	var indices: PackedInt32Array = Geometry2D.triangulate_polygon(polygon)
	for index in indices:
		vertices.append(polygon[index] - origin)
		var point: Vector2 = polygon[index]
		if not color_cache.has(point):
			color_cache[point] = Style.landscape_color(terrain, point)
		colors.append(color_cache[point])
