extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_check(main.simulation_mode == MultiScaleTraffic.MINUTE and main.mode_selector.item_count == 4 and main.speed_selector.item_count == 3, "mode and pace selectors are available")
	var start_day: int = main.last_dynamics_day_key
	main._on_mode_selected(MultiScaleTraffic.DAY)
	main._on_speed_selected(2)
	_check(main.map_view.detail_level == "State" and main.simulation_mode == MultiScaleTraffic.DAY, "day mode uses regional map detail")
	_check(main.flow_timeline.week_mode and main.flow_timeline.week_start_day_key == start_day, "day mode switches the timeline to a seven-day window")
	_check(main.flow_timeline._week_values(main.flow_purpose).size() == 7 and is_equal_approx(main.flow_timeline._week_values(main.flow_purpose)[0], main.flow_profile.get_daily_totals()[main.flow_purpose]), "weekly chart uses daily trip totals")
	var start_msec: int = Time.get_ticks_msec()
	var longest_frame := 0.0
	while main.last_dynamics_day_key == start_day and Time.get_ticks_msec() - start_msec < 30000:
		var frame_msec: int = Time.get_ticks_usec()
		await process_frame
		longest_frame = maxf(longest_frame, float(Time.get_ticks_usec() - frame_msec) / 1000.0)
	_check(main.last_dynamics_day_key == start_day + 1, "day mode crosses midnight")
	_check(main.flow_timeline.week_start_day_key == start_day and main.flow_timeline.week_totals.has(start_day), "weekly chart retains the previous day's total after midnight")
	_check(main.traffic_state.day_key == main.last_dynamics_day_key, "day handoff keeps the road state aligned")
	_check(main.map_view._is_recorded_time(), "traffic colors remain available after midnight")
	var superseded_buffer = main.week_buffer
	var new_tax_rate: float = main.region.jurisdictions[0].income_tax_rate + 0.01
	main._on_tax_changed(new_tax_rate * 100.0)
	_check(bool(superseded_buffer.status()["cancelled"]), "policy edits invalidate prepared days")
	var tax_handoff_start: int = Time.get_ticks_msec()
	while main.last_dynamics_day_key == start_day + 1 and Time.get_ticks_msec() - tax_handoff_start < 10000:
		await process_frame
	_check(main.last_dynamics_day_key == start_day + 2 and is_equal_approx(main.region.jurisdictions[0].income_tax_rate, new_tax_rate), "reprepared week applies the tax on its scheduled day")
	_check(main.week_buffer != null and int(main.week_buffer.status()["ready"]) <= 7, "week preparation remains bounded")
	main._on_jurisdiction_selected(main.region.cities[0]["jurisdiction_id"])
	_check(main.simulation_mode == MultiScaleTraffic.MINUTE and main.map_view.detail_level == "Neighborhood", "local inspection switches to minute mode")
	_check(not main.flow_timeline.week_mode, "leaving day mode restores the hourly timeline")
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	_check(main.simulation_mode == MultiScaleTraffic.MINUTE, "hour mode stays unavailable during local inspection")
	main._on_jurisdiction_selected(0)
	main._on_mode_selected(MultiScaleTraffic.SECOND)
	_check(main.simulation_mode == MultiScaleTraffic.SECOND, "second mode can resume after macro time")
	main._on_play_pressed()
	var frozen_time: int = main.calendar_clock.unix_seconds
	await process_frame
	_check(main.calendar_clock.unix_seconds == frozen_time and main.map_view._is_recorded_time(), "pause retains the current traffic display")
	main._on_mode_selected(MultiScaleTraffic.DAY)
	var pending_source_day: int = main.traffic_state.day_key
	main.traffic_state.unix_seconds = (pending_source_day + 1) * 86400
	main.calendar_clock.unix_seconds = main.traffic_state.unix_seconds
	main._queue_next_day(pending_source_day)
	main._on_jurisdiction_selected(main.region.cities[0]["jurisdiction_id"])
	var handoff_start: int = Time.get_ticks_msec()
	while main.last_dynamics_day_key == pending_source_day and Time.get_ticks_msec() - handoff_start < 10000:
		await process_frame
	_check(main.last_dynamics_day_key == pending_source_day + 1 and main.simulation_mode == MultiScaleTraffic.MINUTE and main.traffic_state.cached_mode == MultiScaleTraffic.MINUTE, "mode changes during day preparation carry into the new day")
	if failures == 0:
		print("Multiscale UI smoke checks passed. Longest frame: %.1f ms" % longest_frame)
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
