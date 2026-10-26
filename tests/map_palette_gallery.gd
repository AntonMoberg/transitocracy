extends SceneTree
const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	root.size = Vector2i(1920,1080)
	root.content_scale_size = root.size
	var region = Setup.build(1729,256,0.1).region
	var map := RegionMap.new()
	root.add_child(map)
	map.size = Vector2(1920,1080)
	map.set_region(region)
	var focus: Vector2 = region.neighborhoods[0].street_layout.bounds.get_center()
	for ppk in [0.0, 8.0, 16.0, 40.0, 80.0, 150.0]:
		map.zoom = 1.0 if ppk == 0 else ppk / map._map_scale()
		map.pan = Vector2.ZERO if ppk == 0 else -(focus-map._world_center()) * ppk
		await process_frame
		var deadline := Time.get_ticks_msec()+15000
		while Time.get_ticks_msec()<deadline:
			await create_timer(.01).timeout
			if map.chunk_renderer.is_settled() and map.terrain_texture != null and (map.terrain_detail_level < 0 or map.terrain_detail_published_level == map.terrain_detail_level): break
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("user://palette_%d.png" % ppk)
		if ppk == 0:
			map.show_terrain_overlay = true
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("user://palette_terrain.png")
			map.show_terrain_overlay = false
	print("Palette gallery saved to user://palette_*.png")
	map.queue_free()
	await process_frame
	quit()
