extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 300000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Large UI generation did not complete.")
		quit(1)
		return
	main.playing = false
	var errors := PackedStringArray()
	main.map_view.queue_redraw()
	await process_frame
	await process_frame
	var neighborhood_draw_ms: float = float(main.map_view.last_overlay_us) / 1000.0
	print("Large neighborhood frame (µs): overlay ", main.map_view.last_overlay_us, " bake ", main.map_view.last_draw_us, " stages ", main.map_view.last_draw_stages_us)
	if neighborhood_draw_ms >= 100.0:
		errors.append("Neighborhood map frame took %.1f ms." % neighborhood_draw_ms)
	if main.region.neighborhoods.size() != 286:
		errors.append("Large region was not selected by default.")
	if main.map_view.region != main.region:
		errors.append("Map did not receive the generated region.")
	main._on_map_mode_selected(1)
	main.map_view.zoom = 3.0
	main.map_view.queue_redraw()
	await process_frame
	var mode_started: int = Time.get_ticks_usec()
	main._on_mode_selected(MultiScaleTraffic.DAY)
	var mode_switch_ms: float = float(Time.get_ticks_usec() - mode_started) / 1000.0
	deadline = Time.get_ticks_msec() + 60000
	while (main.week_buffer == null or int(main.week_buffer.status()["produced"]) < 7) and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.week_buffer == null or int(main.week_buffer.status()["produced"]) < 7:
		errors.append("Seven-day buffer did not fill.")
	else:
		print("Seven-day stage totals: ", main.week_buffer.status()["stage_totals_us"])
	main._on_speed_selected(2)
	main.playing = true
	var initial_day: int = main.last_dynamics_day_key
	var longest_frame := 0.0
	var longest_detail := ""
	deadline = Time.get_ticks_msec() + 60000
	while main.last_dynamics_day_key == initial_day and Time.get_ticks_msec() < deadline:
		var frame_started: int = Time.get_ticks_usec()
		await process_frame
		var frame_ms: float = float(Time.get_ticks_usec() - frame_started) / 1000.0
		if frame_ms > longest_frame:
			longest_frame = frame_ms
			longest_detail = "draw %.1f, process %.1f, handoff %.1f, advance %.1f, sync %.1f ms" % [float(main.map_view.last_draw_us) / 1000.0, float(main.last_process_us) / 1000.0, float(main.last_handoff_us) / 1000.0, float(main.last_advance_us) / 1000.0, float(main.last_sync_us) / 1000.0]
	if main.last_dynamics_day_key != initial_day + 1:
		errors.append("Large day mode did not advance.")
	if main.week_buffer == null or int(main.week_buffer.status()["ready"]) < 5:
		errors.append("Prepared days were discarded after the first seven-day window.")
	# Day rollovers redraw the map with fresh traffic colors while the week
	# buffer keeps producing days on worker threads. The rollover bake is a
	# known single hitch (~100-160 ms on the large map) and worker-thread core
	# contention adds variable scheduling delay on loaded machines. This
	# guards against synchronous recalculation freezes, not those hitches.
	if longest_frame >= 400.0:
		errors.append("Large day mode blocked a UI frame for %.1f ms." % longest_frame)
	print("Large UI mode switch: %.1f ms; longest day frame: %.1f ms (%s)" % [mode_switch_ms, longest_frame, longest_detail])
	print("Longest day frame draw stages (µs): ", main.map_view.last_draw_stages_us)
	print("Large neighborhood map frame: %.1f ms" % neighborhood_draw_ms)
	print("Large UI handoff breakdown (µs): ", main.last_handoff_breakdown)
	print("Large UI: %d neighborhoods, %d buffered days" % [main.region.neighborhoods.size(), 0 if main.week_buffer == null else int(main.week_buffer.status()["produced"])])
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
