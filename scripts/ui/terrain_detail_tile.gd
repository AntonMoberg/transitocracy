extends RefCounted

# CPU-only terrain tile rendering. RegionMap creates GPU textures on the main
# thread after the visible tiles finish on background workers.
const PIXELS = 128


static func render(terrain, land: PackedVector2Array, origin: Vector2, step_km: float) -> Dictionary:
	var image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var terrain_image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var slope_image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var contour_image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var tile_rect := Rect2(origin, Vector2.ONE * step_km * PIXELS)
	var corners := [tile_rect.position, Vector2(tile_rect.end.x, tile_rect.position.y), tile_rect.end, Vector2(tile_rect.position.x, tile_rect.end.y)]
	var all_land := true
	var any_land := false
	for corner in corners:
		var inside: bool = Geometry2D.is_point_in_polygon(corner, land)
		all_land = all_land and inside
		any_land = any_land or inside
	var boundary_crosses := false
	for edge in range(land.size()):
		var a: Vector2 = land[edge]
		var b: Vector2 = land[(edge + 1) % land.size()]
		if Rect2(a.min(b), (b - a).abs()).intersects(tile_rect, true):
			boundary_crosses = true
			break
	if not boundary_crosses and not any_land:
		image.fill(Color.TRANSPARENT)
		terrain_image.fill(Color.TRANSPARENT)
		slope_image.fill(Color.TRANSPARENT)
		contour_image.fill(Color.TRANSPARENT)
		return {"color": image, "terrain": terrain_image, "slope": slope_image, "contours": contour_image}
	var has_land_cover: bool = terrain.has_method("land_cover_at")
	var stride := PIXELS + 2
	var heights := PackedFloat32Array()
	heights.resize(stride * stride)
	var contour_interval_m: float = 100.0 if step_km >= 0.25 else (50.0 if step_km >= 0.03125 else 25.0)
	for y in range(stride):
		for x in range(stride):
			var point: Vector2 = origin + Vector2(float(x) - 0.5, float(y) - 0.5) * step_km
			heights[y * stride + x] = terrain.visual_elevation_at(point)
	for y in range(PIXELS):
		for x in range(PIXELS):
			var point: Vector2 = origin + Vector2(float(x) + 0.5, float(y) + 0.5) * step_km
			if (boundary_crosses or not all_land) and not Geometry2D.is_point_in_polygon(point, land):
				image.set_pixel(x, y, Color.TRANSPARENT)
				terrain_image.set_pixel(x, y, Color.TRANSPARENT)
				slope_image.set_pixel(x, y, Color.TRANSPARENT)
				contour_image.set_pixel(x, y, Color.TRANSPARENT)
				continue
			var index: int = (y + 1) * stride + x + 1
			var elevation: float = heights[index]
			var west: float = heights[index - 1]
			var east: float = heights[index + 1]
			var north: float = heights[index - stride]
			var south: float = heights[index + stride]
			var gradient := Vector2(east - west, south - north) / (step_km * 2000.0)
			var cover: Vector3 = terrain.land_cover_at(point, elevation, gradient) if has_land_cover else Vector3.ZERO
			image.set_pixel(x, y, land_color(elevation, gradient, cover))
			terrain_image.set_pixel(x, y, terrain_color(elevation, gradient, cover))
			slope_image.set_pixel(x, y, slope_color(gradient))
			contour_image.set_pixel(x, y, contour_color(elevation, gradient, step_km, contour_interval_m))
	return {"color": image, "terrain": terrain_image, "slope": slope_image, "contours": contour_image}


static func land_color(elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO) -> Color:
	var light: float = clampf(0.5 - (gradient.x + gradient.y) * 3.1, 0.29, 0.76)
	var base: Color = Color("526c5c").lerp(Color("9a9384"), smoothstep(120.0, 850.0, elevation))
	base = base.lerp(Color("bbb4a6"), smoothstep(850.0, 1450.0, elevation) * 0.6)
	base = base.lerp(Color("3e6553"), cover.x * 0.45)
	base = base.lerp(Color("8b846c"), cover.y * 0.28)
	base = base.lerp(Color("a7a198"), cover.z * 0.5)
	return base * (0.75 + light * 0.42)


static func terrain_color(elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO) -> Color:
	var base: Color = Color("c7e9d6").lerp(Color("b7d6b9"), smoothstep(220.0, 800.0, elevation))
	base = base.lerp(Color("c9bfb0"), smoothstep(650.0, 1500.0, elevation) * 0.78)
	base = base.lerp(Color("e7e6df"), smoothstep(1350.0, 1900.0, elevation))
	base = base.lerp(Color("83b8a1"), cover.x * 0.63)
	base = base.lerp(Color("dfd8b8"), cover.y * 0.52)
	base = base.lerp(Color("b9afa4"), cover.z * 0.72)
	var light: float = clampf(1.0 - (gradient.x + gradient.y) * 2.4, 0.55, 1.18)
	return base * light


static func slope_color(gradient: Vector2) -> Color:
	var slope: float = gradient.length()
	if slope >= 0.25:
		return Color("d75b5b", 0.70)
	if slope >= 0.10:
		return Color("df8e5f", clampf((slope - 0.10) * 2.6, 0.18, 0.55))
	return Color.TRANSPARENT


static func contour_color(elevation: float, gradient: Vector2, step_km: float, interval_m: float) -> Color:
	var slope: float = gradient.length()
	if slope < 0.006:
		return Color.TRANSPARENT
	var nearest_line: float = roundf(elevation / interval_m) * interval_m
	var distance_m: float = absf(elevation - nearest_line)
	var half_width_m: float = minf(interval_m * 0.16, maxf(0.25, slope * step_km * 1000.0 * 0.85))
	var strength: float = clampf(1.0 - distance_m / half_width_m, 0.0, 1.0)
	var major: bool = posmod(int(roundf(nearest_line / interval_m)), 5) == 0
	return Color("d4ddba", strength * (0.36 if major else 0.22))
