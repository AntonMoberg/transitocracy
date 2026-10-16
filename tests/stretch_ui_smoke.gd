extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 10000
	while main.generation_thread != null and Time.get_ticks_msec() < deadline:
		await process_frame
	main.playing = false
	main.map_size_selector.select(2)
	var started: int = Time.get_ticks_msec()
	main._generate_region(1729)
	deadline = Time.get_ticks_msec() + 15000
	while main.generation_thread != null and Time.get_ticks_msec() < deadline:
		await process_frame
	var errors := PackedStringArray()
	if main.generation_thread != null or main.region.neighborhoods.size() != 20480:
		errors.append("Stretch region did not generate.")
	else:
		main.playing = false
		main._on_map_mode_selected(1)
		main._on_mode_selected(MultiScaleTraffic.DAY)
		await process_frame
		if main.map_view.region != main.region or main.map_view._world_size().x < 400.0:
			errors.append("Stretch map did not use the expanded state geometry.")
		if main.week_buffer == null:
			errors.append("Stretch day buffer did not start.")
	print("Stretch UI generation: %.1f s" % (float(Time.get_ticks_msec() - started) / 1000.0))
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
