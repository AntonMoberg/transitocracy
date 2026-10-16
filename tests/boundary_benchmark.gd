extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 15000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Region generation timed out")
		quit(1)
		return
	main.playing = false
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	deadline = Time.get_ticks_msec() + 15000
	while main.traffic_state.compact_hourly_links.size() != 24 and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.traffic_state.compact_hourly_links.size() != 24:
		push_error("Hourly route preparation timed out")
		quit(1)
		return
	main.playing = true
	main.simulation_credit = 3600.0
	var started: int = Time.get_ticks_usec()
	main._process(0.0)
	print("Hour boundary: total %.1f ms, advance %.1f ms, sync %.1f ms" % [
		float(Time.get_ticks_usec() - started) / 1000.0,
		float(main.last_advance_us) / 1000.0,
		float(main.last_sync_us) / 1000.0,
	])
	print("Hour stages: ", main.traffic_state.stage_totals_us)
	main.playing = false
	main._on_mode_selected(MultiScaleTraffic.DAY)
	deadline = Time.get_ticks_msec() + 15000
	while main.pending_day_result_key < 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.pending_day_result_key < 0:
		push_error("Next day was not prepared")
		quit(1)
		return
	main.playing = true
	main.simulation_credit = 86400.0
	started = Time.get_ticks_usec()
	main._process(0.0)
	print("Day boundary: total %.1f ms, advance %.1f ms, sync %.1f ms" % [
		float(Time.get_ticks_usec() - started) / 1000.0,
		float(main.last_advance_us) / 1000.0,
		float(main.last_sync_us) / 1000.0,
	])
	print("Day stages: ", main.traffic_state.stage_totals_us)
	print("Day handoff breakdown: %s" % main.last_handoff_breakdown)
	quit()
