extends RefCounted

# CPU-only terrain tile rendering. RegionMap creates GPU textures on the main
# thread after the visible tiles finish on background workers.
const Style = preload("res://scripts/ui/map_style.gd")
const PIXELS = 128
const CartographicTile = preload("res://scripts/ui/cartographic_tile.gd")


static func render(terrain, land: PackedVector2Array, origin: Vector2, step_km: float) -> Dictionary:
	var image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var terrain_image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
	var satellite_image := Image.create(PIXELS, PIXELS, false, Image.FORMAT_RGBA8)
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
		satellite_image.fill(Color.TRANSPARENT)
		slope_image.fill(Color.TRANSPARENT)
		contour_image.fill(Color.TRANSPARENT)
		return {"color": image, "terrain": terrain_image, "satellite": satellite_image, "slope": slope_image, "contours": contour_image, "map_vertices": PackedVector2Array(), "map_colors": PackedColorArray()}
	var has_land_cover: bool = terrain.has_method("land_cover_at")
	var has_ground_detail: bool = terrain.has_method("ground_detail_at")
	# Padding lets hillshade compare broad slopes with local gullies
	# without a visible change at tile edges.
	var padding := 6
	var stride := PIXELS + padding * 2
	var heights := PackedFloat32Array()
	heights.resize(stride * stride)
	var contour_interval_m: float = 100.0 if step_km >= 0.25 else (50.0 if step_km >= 0.03125 else 25.0)
	for y in range(stride):
		for x in range(stride):
			var point: Vector2 = origin + Vector2(float(x - padding) + 0.5, float(y - padding) + 0.5) * step_km
			heights[y * stride + x] = terrain.visual_elevation_at(point)
	for y in range(PIXELS):
		for x in range(PIXELS):
			var point: Vector2 = origin + Vector2(float(x) + 0.5, float(y) + 0.5) * step_km
			if (boundary_crosses or not all_land) and not Geometry2D.is_point_in_polygon(point, land):
				image.set_pixel(x, y, Color.TRANSPARENT)
				terrain_image.set_pixel(x, y, Color.TRANSPARENT)
				satellite_image.set_pixel(x, y, Color.TRANSPARENT)
				slope_image.set_pixel(x, y, Color.TRANSPARENT)
				contour_image.set_pixel(x, y, Color.TRANSPARENT)
				continue
			var index: int = (y + padding) * stride + x + padding
			var elevation: float = heights[index]
			var west: float = heights[index - 1]
			var east: float = heights[index + 1]
			var north: float = heights[index - stride]
			var south: float = heights[index + stride]
			var gradient := Vector2(east - west, south - north) / (step_km * 2000.0)
			var detail_radius := 2
			var detail_gradient := Vector2(heights[index + detail_radius] - heights[index - detail_radius], heights[index + detail_radius * stride] - heights[index - detail_radius * stride]) / (step_km * 2000.0 * float(detail_radius))
			var map_radius := 3
			var map_gradient := Vector2(heights[index + map_radius] - heights[index - map_radius], heights[index + map_radius * stride] - heights[index - map_radius * stride]) / (step_km * 2000.0 * float(map_radius))
			var broad_gradient := Vector2(heights[index + padding] - heights[index - padding], heights[index + padding * stride] - heights[index - padding * stride]) / (step_km * 2000.0 * float(padding))
			var cover: Vector3 = terrain.land_cover_at(point, elevation, gradient) if has_land_cover else Vector3.ZERO
			var ground_detail: float = terrain.ground_detail_at(point) if has_ground_detail else 0.0
			var fine_detail: float = terrain.ground_detail_at(point * 8.0) if has_ground_detail else 0.0
			image.set_pixel(x, y, land_color(elevation, map_gradient, cover, ground_detail))
			terrain_image.set_pixel(x, y, terrain_color(elevation, detail_gradient, cover, ground_detail, broad_gradient))
			satellite_image.set_pixel(x, y, satellite_color(elevation, gradient, cover, ground_detail, fine_detail))
			slope_image.set_pixel(x, y, slope_color(gradient))
			contour_image.set_pixel(x, y, contour_color(elevation, gradient, step_km, contour_interval_m))
	var result := {"color": image, "terrain": terrain_image, "satellite": satellite_image, "slope": slope_image, "contours": contour_image}
	result.merge(CartographicTile.build(terrain, land, origin, step_km * PIXELS))
	return result


static func land_color(elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO, ground_detail: float = 0.0) -> Color:
	return Style.land_color(elevation, gradient, cover, ground_detail)


static func terrain_color(elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO, ground_detail: float = 0.0, broad_gradient: Vector2 = Vector2.INF) -> Color:
	var macro_gradient: Vector2 = broad_gradient if broad_gradient.is_finite() else gradient
	var base: Color = _base_color(elevation, cover)
	base = base.lerp(Color("d8d4c9"), cover.z * 0.25)
	var broad_light: float = clampf(1.0 - (macro_gradient.x + macro_gradient.y) * 0.9, 0.72, 1.16)
	var detail_gradient: Vector2 = gradient - macro_gradient
	var detail_light: float = clampf(1.0 - (detail_gradient.x + detail_gradient.y) * 1.5, 0.83, 1.17)
	var hill_detail: float = smoothstep(0.035, 0.15, gradient.length())
	return base * broad_light * detail_light * (1.0 + ground_detail * 0.05 * hill_detail)


static func satellite_color(elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO, ground_detail: float = 0.0, fine_detail: float = 0.0) -> Color:
	var base: Color = Color("829576").lerp(Color("a6a08e"), smoothstep(220.0, 1200.0, elevation))
	base = base.lerp(Color("d2cdc1"), smoothstep(1300.0, 1900.0, elevation))
	base = base.lerp(Color("426c4d"), cover.x * 0.82)
	base = base.lerp(Color("b7a87d"), cover.y * 0.76)
	base = base.lerp(Color("a8a39b"), cover.z * 0.82)
	var light: float = clampf(1.0 - (gradient.x + gradient.y) * 1.6, 0.76, 1.18)
	return base * light * (1.0 + ground_detail * 0.13 + fine_detail * 0.11)


static func _base_color(elevation: float, cover: Vector3) -> Color:
	# Narrow transitions produce readable landform regions on the unshaded map.
	var base: Color = Color("d7efdc").lerp(Color("c5e5cd"), smoothstep(140.0, 170.0, elevation))
	base = base.lerp(Color("b4d7b7"), smoothstep(400.0, 440.0, elevation))
	base = base.lerp(Color("a8cca9"), smoothstep(800.0, 850.0, elevation))
	base = base.lerp(Color("e6dfcb"), smoothstep(1250.0, 1310.0, elevation))
	base = base.lerp(Color("d8ccb5"), smoothstep(2000.0, 2060.0, elevation))
	base = base.lerp(Color("c9bba2"), smoothstep(3000.0, 3080.0, elevation))
	var woodland: float = cover.x * (1.0 - smoothstep(950.0, 1700.0, elevation))
	return base.lerp(Color("9fc8aa"), woodland * 0.10)


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


static func render_base(terrain, land: PackedVector2Array) -> Dictionary:
	var image := Image.create(terrain.width, terrain.height, false, Image.FORMAT_RGBA8)
	var terrain_image := Image.create(terrain.width, terrain.height, false, Image.FORMAT_RGBA8)
	var satellite_image := Image.create(terrain.width, terrain.height, false, Image.FORMAT_RGBA8)
	var slope_image := Image.create(terrain.width, terrain.height, false, Image.FORMAT_RGBA8)
	var contour_image := Image.create(terrain.width, terrain.height, false, Image.FORMAT_RGBA8)
	for y in range(terrain.height):
		for x in range(terrain.width):
			var point: Vector2 = terrain.bounds.position + Vector2(x, y) * terrain.GRID_KM
			if not Geometry2D.is_point_in_polygon(point, land):
				image.set_pixel(x, y, Color.TRANSPARENT)
				terrain_image.set_pixel(x, y, Color.TRANSPARENT)
				satellite_image.set_pixel(x, y, Color.TRANSPARENT)
				slope_image.set_pixel(x, y, Color.TRANSPARENT)
				contour_image.set_pixel(x, y, Color.TRANSPARENT)
				continue
			var elevation: float = terrain.elevations[y * terrain.width + x]
			var west: float = terrain.elevations[y * terrain.width + maxi(0, x - 1)]
			var east: float = terrain.elevations[y * terrain.width + mini(terrain.width - 1, x + 1)]
			var north: float = terrain.elevations[maxi(0, y - 1) * terrain.width + x]
			var south: float = terrain.elevations[mini(terrain.height - 1, y + 1) * terrain.width + x]
			var gradient: Vector2 = Vector2(east - west, south - north) / (terrain.GRID_KM * 2000.0)
			var cover: Vector3 = terrain.land_cover_at(point, elevation, gradient)
			image.set_pixel(x, y, land_color(elevation, gradient, cover))
			terrain_image.set_pixel(x, y, terrain_color(elevation, gradient, cover))
			satellite_image.set_pixel(x, y, satellite_color(elevation, gradient, cover, terrain.ground_detail_at(point), terrain.ground_detail_at(point * 8.0)))
			slope_image.set_pixel(x, y, slope_color(gradient))
			contour_image.set_pixel(x, y, contour_color(elevation, gradient, terrain.GRID_KM, 500.0))
	image.generate_mipmaps()
	terrain_image.generate_mipmaps()
	satellite_image.generate_mipmaps()
	slope_image.generate_mipmaps()
	contour_image.generate_mipmaps()
	return {"color": image, "terrain": terrain_image, "satellite": satellite_image, "slope": slope_image, "contours": contour_image}
