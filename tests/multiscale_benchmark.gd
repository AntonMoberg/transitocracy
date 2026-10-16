extends SceneTree
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const UiFixture = preload("res://tests/ui_fixture.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var main = await UiFixture.attach_small(self)
	main._on_mode_selected(MultiScaleTraffic.DAY)
	main._on_speed_selected(2)
	var start_day: int = main.last_dynamics_day_key
	var start_msec: int = Time.get_ticks_msec()
	var max_frame := 0.0
	var boundary_wait_started: int = -1
	var max_boundary_wait_msec: int = 0
	while main.last_dynamics_day_key < start_day + 14 and Time.get_ticks_msec() - start_msec < 60000:
		var frame_start: int = Time.get_ticks_usec()
		await process_frame
		max_frame = maxf(max_frame, float(Time.get_ticks_usec() - frame_start) / 1000.0)
		var at_day_end: bool = main.traffic_state.unix_seconds >= (main.traffic_state.day_key + 1) * 86400
		if at_day_end and boundary_wait_started < 0:
			boundary_wait_started = Time.get_ticks_msec()
		elif not at_day_end and boundary_wait_started >= 0:
			max_boundary_wait_msec = maxi(max_boundary_wait_msec, Time.get_ticks_msec() - boundary_wait_started)
			boundary_wait_started = -1
	var seconds: float = float(Time.get_ticks_msec() - start_msec) / 1000.0
	print("Fastest Day mode: %d days in %.2f s, %.2f days/s, longest frame %.1f ms, longest midnight wait %d ms" % [main.last_dynamics_day_key - start_day, seconds, float(main.last_dynamics_day_key-start_day)/maxf(0.001,seconds), max_frame, max_boundary_wait_msec])
	if main.week_buffer != null:
		var status: Dictionary = main.week_buffer.status()
		var stage_totals: Dictionary = status["stage_totals_us"]
		var stage_parts: PackedStringArray = []
		for stage in stage_totals:
			stage_parts.append("%s %.1f ms/day" % [stage, float(stage_totals[stage]) / maxf(1.0, float(status["produced"])) / 1000.0])
		print("Day worker stages: ", ", ".join(stage_parts))
	quit(0 if main.last_dynamics_day_key >= start_day + 14 else 1)
