extends SceneTree

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._on_map_mode_selected(1)
	main._on_speed_selected(4)
	var old_day_key: int = main.last_dynamics_day_key
	var max_frame_ms := 0.0
	var start_msec: int = Time.get_ticks_msec()
	# Run real rolling traffic through midnight. A fabricated bin-96 state did
	# not contain the large flow and checkpoint data that caused the UI hitch.
	while main.last_dynamics_day_key == old_day_key and Time.get_ticks_msec() - start_msec < 90000:
		var frame_start: int = Time.get_ticks_usec()
		await process_frame
		max_frame_ms = maxf(max_frame_ms, float(Time.get_ticks_usec() - frame_start) / 1000.0)
	_check(main.last_dynamics_day_key == old_day_key + 1, "clock must advance after the full traffic day")
	_check(max_frame_ms < 300.0, "the full-day handoff must not block the UI")
	_check(main.traffic_state.next_bin >= 1 and main.map_view._is_recorded_time(), "midnight must arrive with the first traffic bin ready to display")
	var cleanup_start: int = Time.get_ticks_msec()
	while (not main.retired_data_threads.is_empty() or not main.retired_data_backlog.is_empty()) and Time.get_ticks_msec() - cleanup_start < 10000:
		await process_frame
	_check(main.retired_data_threads.is_empty() and main.retired_data_backlog.is_empty(), "old simulation data must be released by a worker")
	if failures == 0:
		print("Async midnight smoke checks passed. Longest frame: %.1f ms" % max_frame_ms)
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
