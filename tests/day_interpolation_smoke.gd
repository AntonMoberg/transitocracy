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
	main._on_mode_selected(MultiScaleTraffic.DAY)
	deadline = Time.get_ticks_msec() + 15000
	while main.pending_day_result_key < 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.pending_day_result_key < 0:
		push_error("Next day was not prepared")
		quit(1)
		return
	var start: int = main.traffic_state.unix_seconds
	var day_end: int = (main.traffic_state.day_key + 1) * 86400
	main.playing = true
	main.simulation_credit = 21600.0
	main._process(0.0)
	if main.traffic_state.unix_seconds != start or absf(main.calendar_clock.get_display_unix_seconds() - float(start + 21600)) > 0.01:
		push_error("Day mode did not interpolate the displayed clock")
		quit(1)
		return
	if absf(main.flow_timeline.week_clock_seconds - main.calendar_clock.get_display_unix_seconds()) > 0.01:
		push_error("Seven-day timeline did not follow the interpolated clock")
		quit(1)
		return
	main.simulation_credit = float(day_end - start) + 900.0
	main._process(0.0)
	if main.traffic_state.day_key != day_end / 86400 or absf(main.calendar_clock.get_display_unix_seconds() - float(day_end + 900)) > 0.01:
		push_error("Day handoff lost fractional-day time")
		quit(1)
		return
	main.playing = false
	main._process(0.5)
	if absf(main.calendar_clock.get_display_unix_seconds() - float(day_end + 900)) > 0.01:
		push_error("Paused Day mode moved the display")
		quit(1)
		return
	print("Day clock, week marker, and midnight handoff interpolate smoothly")
	quit()
