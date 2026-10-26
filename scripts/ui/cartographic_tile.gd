extends RefCounted
## Exact coastline geometry shared by Map, Terrain and Satellite tiles.
## Filtering a coarse alpha mask leaks land into the sea, even underneath
## a sharper replacement. The shoreline must be defined by geometry.

static func build(_terrain, land: PackedVector2Array, origin: Vector2, tile_km: float) -> Dictionary:
	return build_rect(land, Rect2(origin, Vector2.ONE * tile_km))

static func build_rect(land: PackedVector2Array, rect: Rect2) -> Dictionary:
	var outline := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	for polygon in Geometry2D.intersect_polygons(outline, land):
		for index in Geometry2D.triangulate_polygon(polygon):
			var local: Vector2 = polygon[index] - rect.position
			vertices.append(local)
			uvs.append(local / rect.size)
	return {"map_vertices": vertices, "map_uvs": uvs}
