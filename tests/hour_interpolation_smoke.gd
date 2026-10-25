extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const CompactTrafficCalculator = preload("res://scripts/simulation/compact_traffic_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 120000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Region generation timed out")
		quit(1)
		return
	main.playing = false
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	main._on_speed_selected(0)
	await process_frame
	deadline = Time.get_ticks_msec() + 120000
	while main.compact_hour_thread != null and not main.compact_hour_buffer.status()["snapshot_ready"] and Time.get_ticks_msec() < deadline:
		await process_frame
	while main.traffic_state.compact_hourly_links.size() != 24 and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.traffic_state.compact_hourly_links.size() != 24:
		push_error("Hourly routes were not prepared on the worker")
		quit(1)
		return
	var comparison = MultiScaleTraffic.fork_for_week(main.traffic_state)
	var comparison_hour: int = (main.traffic_state.unix_seconds % 86400) / 3600
	CompactTrafficCalculator.build_hour(main.region, main.flow_profile, comparison, MultiScaleTraffic.HOUR, comparison_hour)
	var prepared_links: PackedVector2Array = main.traffic_state.compact_hourly_links[comparison_hour]
	for index in range(prepared_links.size()):
		if prepared_links[index].distance_to(comparison.cached_links[index]) > 0.001:
			push_error("Prepared hourly routes differ from direct calculation")
			quit(1)
			return
	var committed_start: int = main.traffic_state.unix_seconds
	main.playing = true
	main._process(0.25)
	if main.traffic_state.unix_seconds != committed_start or absf(main.calendar_clock.visual_offset_seconds - 900.0) > 0.01:
		push_error("Hour mode advanced the simulation before the display crossed the hour")
		quit(1)
		return
	if main.calendar_clock.get_minute() != 15 or absf(main.flow_timeline.actual_fraction - 0.25) > 0.01:
		push_error("Clock and chart did not interpolate to the quarter hour")
		quit(1)
		return
	main._on_map_mode_selected(1)
	main._sync_clock_view()
	if main.map_view.selected_hour != main.calendar_clock.get_hour() or absf(main.map_view.hour_fraction - 0.25) > 0.01:
		push_error("Trip arrows did not receive interpolated time")
		quit(1)
		return
	main._on_map_mode_selected(0)
	main.playing = false
	main._process(0.25)
	if main.calendar_clock.get_minute() != 15:
		push_error("Paused hour display moved")
		quit(1)
		return
	main.playing = true
	for step in range(3):
		main._process(0.25)
	if main.traffic_state.unix_seconds != committed_start + 3600 or main.calendar_clock.get_minute() != 0 or main.calendar_clock.visual_offset_seconds >= 1.0:
		push_error("Hour commit did not meet the smooth display clock")
		quit(1)
		return
	main._process(1.0)
	main._process(0.5)
	if main.map_view.road_history_current_hour != (main.traffic_state.unix_seconds % 86400) / 3600 - 1 or main.map_view.road_history_previous_hour < 0 or absf(main.map_view.road_history_fraction - 0.5) > 0.01:
		push_error("Road colors did not blend completed hourly results")
		quit(1)
		return
	main.playing = false
	main.map_view.zoom = 3.0
	main.map_view.queue_redraw()
	await process_frame
	await process_frame
	print("Hour map redraw: %.1f ms %s" % [float(main.map_view.last_draw_us) / 1000.0, main.map_view.last_draw_stages_us])
	print("Hour clock, trip arrows, and road colors interpolate between discrete simulation steps")
	quit()
