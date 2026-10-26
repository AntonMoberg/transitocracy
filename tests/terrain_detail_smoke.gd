extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
const TerrainDetailTile = preload("res://scripts/ui/terrain_detail_tile.gd")
const Style = preload("res://scripts/ui/map_style.gd")

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
		_check(step_km * pixels_per_km <= 2.0, "Map detail fields must refine to at most two pixels per texel")
		var origin: Vector2 = terrain.bounds.position + Vector2(key.y, key.z) * step_km * TerrainDetailTile.PIXELS
		var images: Dictionary = TerrainDetailTile.render(terrain, region.jurisdictions[0].polygon_km, origin, step_km)
		_check(images["color"].get_width() == TerrainDetailTile.PIXELS, "detail renderer must produce full size tiles")
		_check(images["terrain"].get_width() == TerrainDetailTile.PIXELS, "detail renderer must produce shaded terrain tiles")
		_check(images["contours"].get_width() == TerrainDetailTile.PIXELS, "terrain tiles must carry contour overlays")
		# The cached derivative optimization must agree with direct world
		# sampling, including cells crossing the original 2 km height grid.
		var field_rect := Rect2(terrain.bounds.get_center(), Vector2(12,12))
		var field := TerrainDetailTile.render_field(terrain, field_rect, Vector2i(48,48))
		for y in range(0,50,7):
			for x in range(0,50,7):
				var point := field_rect.position + (Vector2(x,y)-Vector2.ONE*.5)*.25
				var expected := Style.landscape_field(terrain,point)
				var actual := field.get_pixel(x,y)
				_check(absf(actual.r-expected.r)<.001 and absf(actual.g-expected.g)<.001 and absf(actual.b-expected.b)<.001 and absf(actual.a-expected.a)<.001,"cached landscape derivative changes world-space cover")
		_check(not map.terrain_detail_tiles[key].has("terrain"), "plain Map must not wait for unused raster styles")
	# Enabling analysis at the same zoom invalidates readiness, keeps a base
	# available, and upgrades cached Map-only entries rather than using blanks.
	map.show_slope_overlay = true
	await process_frame
	await process_frame
	_check(map.terrain_detail_published_level < 0, "analysis must request missing raster data at unchanged zoom")
	map.show_slope_overlay = false
	var land := PackedVector2Array([Vector2(-1, -1), Vector2(3, -1), Vector2(3, 3), Vector2(-1, 3)])
	var flat: Dictionary = TerrainDetailTile.render(FlatTerrain.new(), land, Vector2.ZERO, 0.015625)
	_check(flat["color"].get_pixel(8, 8).is_equal_approx(flat["color"].get_pixel(110, 110)), "flat land must not have artificial bumpy shading")
	_check(flat["terrain"].get_pixel(8, 8).is_equal_approx(flat["terrain"].get_pixel(110, 110)), "flat terrain mode must not have artificial bumpy shading")
	_check(flat["contours"].get_pixel(64, 64).a == 0.0, "flat land must not be covered in contour bands")
	var hill: Dictionary = TerrainDetailTile.render(SlopedTerrain.new(), land, Vector2.ZERO, 0.015625)
	_check(not TerrainDetailTile.land_color(700.0, Vector2(0.3, 0.1)).is_equal_approx(TerrainDetailTile.land_color(700.0, Vector2(-0.3, -0.1))), "plain Map must retain subtle directional relief")
	_check(not TerrainDetailTile.land_color(700.0, Vector2.ZERO).is_equal_approx(TerrainDetailTile.land_color(700.0, Vector2(0.3, 0.1))), "plain Map must show restrained relief on steep terrain")
	_check(TerrainDetailTile.land_color(500.0, Vector2.ZERO, Vector3.ZERO, -1.0).is_equal_approx(TerrainDetailTile.land_color(500.0, Vector2.ZERO, Vector3.ZERO, 1.0)), "plain Map colors must not include fine ground texture")
	var lowland: Color = TerrainDetailTile.land_color(50.0, Vector2.ZERO)
	var foothill: Color = TerrainDetailTile.land_color(650.0, Vector2(0.1, 0.0), Vector3(0.8,0,0))
	var alpine: Color = TerrainDetailTile.land_color(2500.0, Vector2(0.2, 0.1), Vector3(0,0,1))
	_check(lowland.g > lowland.r and foothill.g > foothill.r and foothill.g < lowland.g, "wooded hills must deepen from light green open land")
	_check(alpine.r > alpine.g and alpine.g > alpine.b, "exposed mountain rock must use sand colors")
	_check(not TerrainDetailTile.terrain_color(500.0, Vector2.ZERO).is_equal_approx(TerrainDetailTile.terrain_color(500.0, Vector2(0.3, 0.1))), "terrain toggle must add relief shading")
	var contour_pixels := 0
	for y in range(TerrainDetailTile.PIXELS):
		for x in range(TerrainDetailTile.PIXELS):
			contour_pixels += 1 if hill["contours"].get_pixel(x, y).a > 0.05 else 0
	_check(contour_pixels > 0 and contour_pixels < TerrainDetailTile.PIXELS * TerrainDetailTile.PIXELS / 3, "hills must show faint, narrow contour lines")
	map.terrain_toggle_button.button_pressed = true
	_check(map.map_mode == "Roads" and map.show_terrain_overlay, "terrain toggle must preserve the Roads map mode")
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
	for key in map.terrain_detail_visible:
		_check(map.terrain_detail_tiles[key].has("terrain"), "analysis mode must publish complete raster tiles")
		if map.terrain_layer.tiles.has(key):
			_check(map.terrain_layer.tiles[key].ground.texture == map.terrain_detail_tiles[key].terrain, "visible tile must adopt its upgraded texture")
	await process_frame
	_check(not map.traffic_toggle_button.disabled, "terrain relief must keep traffic controls available")
	_check(not map.terrain_toggle_button.disabled and not map.slope_toggle_button.disabled and not map.contour_toggle_button.disabled and not map.transit_toggle_button.disabled, "Map must always offer its terrain, analysis and transit layers")
	_check(map.get_node("MapNavigation").get_child_count()==3, "Map navigation must only contain zoom and Fit controls")
	map.queue_free()
	if failures == 0:
		print("Terrain tiles, contours, flat colors, and terrain relief toggle passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
