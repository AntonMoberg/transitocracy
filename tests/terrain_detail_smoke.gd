extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
const TerrainDetailTile = preload("res://scripts/ui/terrain_detail_tile.gd")

class FlatTerrain:
	extends RefCounted
	func visual_elevation_at(_point: Vector2) -> float:
		return 100.0

class SlopedTerrain:
	extends RefCounted
	func visual_elevation_at(point: Vector2) -> float:
		return point.x * 100.0

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(5424046)
	var terrain = region.terrain
	var map = RegionMap.new()
	root.add_child(map)
	map.size = Vector2(800, 600)
	map.set_region(region)
	var center: Vector2 = region.neighborhoods[0].position_km
	var pixels_per_km := 300.0
	map.zoom = pixels_per_km / map._map_scale()
	map.pan = -(center - map._world_center()) * pixels_per_km
	var tile_started: int = Time.get_ticks_msec()
	map.queue_redraw()
	var deadline: int = Time.get_ticks_msec() + 5000
	while map.terrain_detail_published_level < 0 and Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
	_check(map.terrain_detail_published_level >= 0, "zoomed map must finish its visible terrain tiles")
	print("Visible terrain tiles: %d in %d ms" % [map.terrain_detail_visible.size(), Time.get_ticks_msec() - tile_started])
	if not map.terrain_detail_tiles.is_empty():
		var key: Vector3i = map.terrain_detail_tiles.keys()[0]
		var step_km: float = map.TERRAIN_DETAIL_STEPS[key.x]
		_check(step_km * pixels_per_km <= 6.5, "terrain texture texels must stay small on screen")
		var origin: Vector2 = terrain.bounds.position + Vector2(key.y, key.z) * step_km * TerrainDetailTile.PIXELS
		var images: Dictionary = TerrainDetailTile.render(terrain, region.jurisdictions[0].polygon_km, origin, step_km)
		_check(images["color"].get_width() == TerrainDetailTile.PIXELS, "detail renderer must produce full size tiles")
		_check(images["terrain"].get_width() == TerrainDetailTile.PIXELS, "detail renderer must produce a terrain-map palette")
		_check(images["contours"].get_width() == TerrainDetailTile.PIXELS, "terrain tiles must carry contour overlays")
	var land := PackedVector2Array([Vector2(-1, -1), Vector2(3, -1), Vector2(3, 3), Vector2(-1, 3)])
	var flat: Dictionary = TerrainDetailTile.render(FlatTerrain.new(), land, Vector2.ZERO, 0.015625)
	_check(flat["color"].get_pixel(8, 8).is_equal_approx(flat["color"].get_pixel(110, 110)), "flat land must not have artificial bumpy shading")
	_check(flat["terrain"].get_pixel(8, 8).is_equal_approx(flat["terrain"].get_pixel(110, 110)), "flat terrain mode must not have artificial bumpy shading")
	_check(flat["contours"].get_pixel(64, 64).a == 0.0, "flat land must not be covered in contour bands")
	var hill: Dictionary = TerrainDetailTile.render(SlopedTerrain.new(), land, Vector2.ZERO, 0.015625)
	var contour_pixels := 0
	for y in range(TerrainDetailTile.PIXELS):
		for x in range(TerrainDetailTile.PIXELS):
			contour_pixels += 1 if hill["contours"].get_pixel(x, y).a > 0.05 else 0
	_check(contour_pixels > 0 and contour_pixels < TerrainDetailTile.PIXELS * TerrainDetailTile.PIXELS / 3, "hills must show faint, narrow contour lines")
	map.set_map_mode("Terrain")
	map.show_contours = true
	map.show_traffic_overlay = false
	map.zoom = 5.0 / map._map_scale()
	map.pan = -(center - map._world_center()) * 5.0
	map.queue_redraw()
	await process_frame
	deadline = Time.get_ticks_msec() + 5000
	while map.terrain_detail_published_level != map.terrain_detail_level and Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
	_check(map.terrain_detail_level >= 0 and map.terrain_detail_published_level == map.terrain_detail_level, "terrain detail must appear at regional zoom")
	await process_frame
	_check(map.urban_layer.last_building_count == 0, "terrain view must hide building footprints")
	map.queue_free()
	if failures == 0:
		print("Terrain tiles, contours, smooth flats, and terrain map view passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
