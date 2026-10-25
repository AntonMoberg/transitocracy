extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 300000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Region generation timed out")
		quit(1)
		return
	main.playing = false
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--seed="):
			continue
		var requested_seed: int = int(argument.trim_prefix("--seed="))
		if main.region.generation_seed != requested_seed:
			main._generate_region(requested_seed)
			deadline = Time.get_ticks_msec() + 300000
			while (main.region == null or main.region.generation_seed != requested_seed) and Time.get_ticks_msec() < deadline:
				await process_frame
			if main.region == null or main.region.generation_seed != requested_seed:
				push_error("Requested benchmark seed generation timed out")
				quit(1)
				return
		break
	var map = main.map_view
	var city: Dictionary = main.region.cities[main.region.starting_city_ids[0]]
	var street_zoom: float = map.MAX_PIXELS_PER_KM / map._map_scale()
	for magnification in [1.0, 2.0, 3.0, 4.0, 8.0, 16.0, 64.0, 256.0, 1024.0, street_zoom]:
		map.zoom = magnification
		map.pan = -(city["center_km"] - map._world_center()) * map._map_scale() * magnification
		map.queue_redraw()
		await process_frame
		await process_frame
		print("Zoom %.0f: %d µs, stages %s" % [magnification, map.last_draw_us, map.last_draw_stages_us])
		map.queue_redraw()
		await process_frame
		await process_frame
		print("Zoom %.0f warm: %d µs, stages %s, urban blocks %d µs, urban streets %d µs, visible buildings %d" % [magnification, map.last_draw_us, map.last_draw_stages_us, map.urban_layer.last_block_draw_us, map.urban_layer.last_street_draw_us, map.urban_layer.last_building_count])
		if magnification == 3.0:
			# The countryside web stays LOD-skipped below zoom 2 and the
			# overview renderer owns zoom 3; the batched lane/arrow mesh only
			# exists past the overview band, so assert the overview draw ran.
			if map.last_draw_stages_us.get("roads", -1) <= 0:
				push_error("Overview road draw did not run at zoom 3")
				quit(1)
				return
		if magnification == 16.0:
			if map.neighborhood_batches.is_empty() or map.neighborhood_batches[0].visible_instance_count == 0:
				push_error("Neighborhood GPU instances were not built")
				quit(1)
				return
			var tested_hit := false
			for neighborhood in main.region.neighborhoods:
				var point: Vector2 = map._world_to_screen(neighborhood.position_km)
				if map._screen_visible(point, -25.0):
					if map._hit_test(point) < 0:
						push_error("Neighborhood marker hit test failed")
						quit(1)
						return
					tested_hit = true
					break
			if not tested_hit:
				push_error("No visible marker available for hit test")
				quit(1)
				return
	var longest_highway_segment := 0.0
	var highway_center := Vector2.ZERO
	for link in main.region.road_links:
		if link.road_class != "Highway":
			continue
		for segment in range(1, link.points.size()):
			var segment_length: float = link.points[segment - 1].distance_to(link.points[segment])
			if segment_length > longest_highway_segment:
				longest_highway_segment = segment_length
				highway_center = (link.points[segment - 1] + link.points[segment]) * 0.5
	if longest_highway_segment > 0.0:
		map.zoom = street_zoom
		map.pan = -(highway_center - map._world_center()) * map._map_scale() * street_zoom
		if map._hit_road_link(map.size * 0.5) < 0:
			push_error("Highway center must be selectable at street zoom")
			quit(1)
			return
		map.queue_redraw()
		await process_frame
		await process_frame
		print("Highway street zoom: %d µs, stages %s" % [map.last_draw_us, map.last_draw_stages_us])
	quit()
