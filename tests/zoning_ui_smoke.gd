extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 10000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Region did not generate.")
		quit(1)
		return
	main.playing = false
	main.map_mode_selector.select(2)
	main._on_map_mode_selected(2)
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0:
			candidate_id = candidate["id"]
			break
	if candidate_id < 0:
		push_error("No unapproved candidate was generated beside an arterial.")
		quit(1)
		return
	var candidate: Dictionary = main.region.development_candidates[candidate_id]
	var map = main.map_view
	map.zoom = 32.0
	map.pan = -(candidate["center_km"] - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	var point: Vector2 = map._world_to_screen(candidate["center_km"])
	if main.region.development_candidate_at_point(candidate["center_km"]) != candidate_id:
		push_error("Zoning hit lookup did not find the road-frontage cell.")
		quit(1)
		return
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = point
	map._gui_input(press)
	map._gui_input(release)
	if main.selected_candidate_id != candidate_id or not main.zoning_controls.visible or main.zoning_button.disabled:
		push_error("Clicking a candidate did not open its zoning approval panel.")
		quit(1)
		return
	var initial_count: int = main.region.neighborhoods.size()
	main.zoning_button.pressed.emit()
	deadline = Time.get_ticks_msec() + 10000
	while (main.region.neighborhoods.size() == initial_count or main.road_rebuild_thread != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.neighborhoods.size() != initial_count + 1 or main.road_rebuild_thread != null:
		push_error("Zoning approval did not create and rebuild one neighborhood.")
		quit(1)
		return
	var neighborhood_id: int = main.region.development_candidates[candidate_id]["neighborhood_id"]
	if not main.region.neighborhoods[neighborhood_id].development_approved or main.map_view.region != main.region:
		push_error("Approved neighborhood or map state was stale after the worker rebuild.")
		quit(1)
		return
	main.zoning_button.pressed.emit()
	deadline = Time.get_ticks_msec() + 10000
	while main.region.neighborhoods[neighborhood_id].development_approved and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.neighborhoods[neighborhood_id].development_approved:
		push_error("Withdraw approval did not update the selected neighborhood.")
		quit(1)
		return
	print("Zoning map selection, approval, async rebuild, and withdrawal passed.")
	quit(0)
