extends RefCounted

# Flat colored geometry changes its geographic sampling with the tile level.
# Adjacent tiles share unjittered edge vertices and never need a seam repair.
const CELLS = 16


static func build(terrain, land: PackedVector2Array, origin: Vector2, tile_km: float, palette: Callable) -> Dictionary:
	var spacing: float = tile_km / float(CELLS)
	var positions := PackedVector2Array()
	var heights := PackedFloat32Array()
	for y in range(CELLS + 1):
		for x in range(CELLS + 1):
			var point: Vector2 = origin + Vector2(x, y) * spacing
			if x > 0 and x < CELLS and y > 0 and y < CELLS:
				var key: int = hash(Vector2i(roundi(point.x / spacing), roundi(point.y / spacing)))
				point += Vector2(float(posmod(key, 997)) / 996.0 - 0.5, float(posmod(key / 997, 991)) / 990.0 - 0.5) * spacing * 0.55
			positions.append(point)
			heights.append(terrain.visual_elevation_at(point))
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
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
				var center: Vector2 = (first + second + third) / 3.0
				var edge_a: Vector2 = (second - first) * 1000.0
				var edge_b: Vector2 = (third - first) * 1000.0
				var determinant: float = edge_a.cross(edge_b)
				var da: float = heights[indices.y] - heights[indices.x]
				var db: float = heights[indices.z] - heights[indices.x]
				var gradient := Vector2((da * edge_b.y - db * edge_a.y) / determinant, (db * edge_a.x - da * edge_b.x) / determinant)
				var elevation: float = (heights[indices.x] + heights[indices.y] + heights[indices.z]) / 3.0
				var cover: Vector3 = terrain.land_cover_at(center, elevation, gradient) if terrain.has_method("land_cover_at") else Vector3.ZERO
				var color: Color = palette.call(elevation, gradient, cover)
				var polygon := PackedVector2Array([first, second, third])
				if Geometry2D.is_point_in_polygon(first, land) and Geometry2D.is_point_in_polygon(second, land) and Geometry2D.is_point_in_polygon(third, land):
					_append_polygon(vertices, colors, polygon, origin, color)
				else:
					for clipped in Geometry2D.intersect_polygons(polygon, land):
						_append_polygon(vertices, colors, clipped, origin, color)
	return {"map_vertices": vertices, "map_colors": colors}


static func _append_polygon(vertices: PackedVector2Array, colors: PackedColorArray, polygon: PackedVector2Array, origin: Vector2, color: Color) -> void:
	var indices: PackedInt32Array = Geometry2D.triangulate_polygon(polygon)
	for index in indices:
		vertices.append(polygon[index] - origin)
		colors.append(color)
