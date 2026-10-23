extends SceneTree

const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 30000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null or not main.region.is_large_scale:
		_fail("Large region did not generate.")
		return
	main.playing = false
	main._discard_pending_day()
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0:
			candidate_id = int(candidate["id"])
			break
	if candidate_id < 0:
		_fail("No approvable district was offered.")
		return
	var previous_count: int = main.region.neighborhoods.size()
	var started: int = Time.get_ticks_usec()
	main._apply_candidate_approval(candidate_id, true, -1, {}, {})
	var action_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	if main.region.neighborhoods.size() != previous_count + 1 or main.road_rebuild_thread == null:
		_fail("Approval did not start an asynchronous rebuild.")
		return
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	if main.simulation_mode != MultiScaleTraffic.MINUTE or main.deferred_mode_index != MultiScaleTraffic.HOUR:
		_fail("Mode switch used the stale demand profile during the rebuild.")
		return
	deadline = Time.get_ticks_msec() + 30000
	while (main.road_rebuild_thread != null or main.deferred_mode_index >= 0) and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.road_rebuild_thread != null or main.simulation_mode != MultiScaleTraffic.HOUR:
		_fail("The deferred mode switch did not finish after the rebuild.")
		return
	if main.flow_profile.compact_origin_daily["Work"].size() != main.region.neighborhoods.size():
		_fail("Traffic demand still has the old neighborhood count.")
		return
	print("District approval %.1f ms on UI thread, %.1f ms to rebuilt traffic and deferred mode." % [action_ms, float(Time.get_ticks_usec() - started) / 1000.0])
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
