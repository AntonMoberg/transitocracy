extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 20000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("The large map did not generate for the zoom test.")
		quit(1)
		return
	main.playing = false
	var map = main.map_view
	map.set_map_mode("Zoning")
	var city: Dictionary = main.region.cities[main.region.starting_city_ids[0]]
	var center: Vector2 = city["center_km"]
	map.zoom = 100.0 / map._map_scale()
	map.pan = -(center - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	await process_frame
	if map.urban_layer.building_cache.size() != 0 or map.urban_layer.last_street_count == 0:
		push_error("Neighborhood roads should appear before individual building detail.")
		quit(1)
		return
	map.zoom = 220.0 / map._map_scale()
	map.pan = -(center - map._world_center()) * map._map_scale() * map.zoom
	var draws := {"count": 0}
	map.draw.connect(func() -> void: draws["count"] = int(draws["count"]) + 1)
	map.queue_redraw()
	for _frame in range(60):
		await process_frame
	var paused_draws: int = int(draws["count"])
	if map.urban_layer.building_cache.is_empty() or paused_draws > 24:
		push_error("Building detail monopolized the main loop: %d draws in 60 frames, %d cached blocks." % [draws["count"], map.urban_layer.building_cache.size()])
		quit(1)
		return
	var previous_zoom: float = map.zoom
	map.queue_redraw()
	await process_frame
	await process_frame
	var urban_ms: float = float(map.last_draw_stages_us["urban"] - map.last_draw_stages_us["cities"]) / 1000.0
	var total_ms: float = float(map.last_draw_us) / 1000.0
	var block_ms: float = float(map.urban_layer.last_block_draw_us) / 1000.0
	var street_ms: float = float(map.urban_layer.last_street_draw_us) / 1000.0
	var draw_stages: Dictionary = map.last_draw_stages_us.duplicate()
	var buildings: int = map.urban_layer.last_building_count
	var streets: int = map.urban_layer.last_street_count
	map._zoom_at(map.size * 0.5, 1.1)
	await process_frame
	if map.zoom <= previous_zoom:
		push_error("Zoom input stopped responding after building detail appeared.")
		quit(1)
		return
	main.playing = true
	var active_start: int = draws["count"]
	for _frame in range(60):
		await process_frame
	var active_draws: int = int(draws["count"]) - active_start
	if active_draws > 15:
		push_error("The playing zoning map redrew %d times in 60 frames." % active_draws)
		quit(1)
		return
	map.set_map_mode("Roads")
	var roads_start: int = draws["count"]
	for _frame in range(60):
		await process_frame
	var roads_draws: int = int(draws["count"]) - roads_start
	if roads_draws > 15:
		push_error("The playing roads map redrew %d times in 60 frames." % roads_draws)
		quit(1)
		return
	map.set_map_mode("Trips")
	var trips_start: int = draws["count"]
	for _frame in range(60):
		await process_frame
	var trips_draws: int = int(draws["count"]) - trips_start
	if trips_draws > 15:
		push_error("The playing trips map redrew %d times in 60 frames." % trips_draws)
		quit(1)
		return
	print("Large-map detail zoom remained responsive: %d draws in 60 frames, %.1f ms total, %.1f ms urban (blocks %.1f, streets %.1f; %d buildings, %d streets)." % [paused_draws, total_ms, urban_ms, block_ms, street_ms, buildings, streets])
	print("Large-map draw stages (µs): %s" % draw_stages)
	print("Playing map redraws: %d in 60 frames." % active_draws)
	print("Playing roads redraws: %d in 60 frames." % roads_draws)
	print("Playing trips redraws: %d in 60 frames." % trips_draws)
	quit()
