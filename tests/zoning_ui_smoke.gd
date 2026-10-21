extends SceneTree

const WeekBuffer = preload("res://scripts/simulation/multiscale_week_buffer.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 30000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		_fail("Region did not generate.")
		return
	main.playing = false
	main._discard_pending_day()
	main.map_mode_selector.select(2)
	main._on_map_mode_selected(2)
	var map = main.map_view
	map.queue_redraw()
	await process_frame
	await process_frame
	var overview_draw_ms: float = float(map.last_draw_us) / 1000.0
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0:
			candidate_id = int(candidate["id"])
			break
	if candidate_id < 0:
		_fail("The starting map has no suggested district.")
		return
	var candidate: Dictionary = main.region.development_candidates[candidate_id]
	var candidate_key: String = candidate["key"]
	var plan_center: Vector2 = candidate["center_km"]
	main.map_mode_selector.select(0)
	main._on_map_mode_selected(0)
	for tool_index in [3, 4]:
		main.road_tool_selector.select(tool_index)
		main._on_road_tool_selected(tool_index)
		main._on_road_empty_clicked(plan_center + Vector2(-0.2, 0.0))
		main._on_road_empty_clicked(plan_center + Vector2(0.2, 0.0))
	main.road_tool_selector.select(5)
	main._on_road_tool_selected(5)
	main._on_road_empty_clicked(plan_center)
	deadline = Time.get_ticks_msec() + 10000
	while (main.region.urban_corridors.is_empty() or main.region.rail_reservations.is_empty() or main.region.station_sites.is_empty()) and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.urban_corridors.size() != 1 or main.region.rail_reservations.size() != 1 or main.region.station_sites.size() != 1:
		_fail("Road planning tools did not record growth, rail, and station guides.")
		return
	main.map_mode_selector.select(2)
	main._on_map_mode_selected(2)
	candidate_id = int(main.region.development_candidate_keys.get(candidate_key, -1))
	if candidate_id < 0:
		_fail("Planning guides removed a connected growth proposal.")
		return
	candidate = main.region.development_candidates[candidate_id]
	map.zoom = 32.0
	map.pan = -(candidate["center_km"] - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	await process_frame
	var city_draw_ms: float = float(map.last_draw_us) / 1000.0
	var point: Vector2 = map._world_to_screen(candidate["center_km"])
	if map._visible_zoning_candidate_at(candidate["center_km"]) != candidate_id:
		_fail("The suggested district cannot be hit on the zoning map.")
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
		_fail("Clicking the suggested district did not open its approval plan.")
		return
	var original_polygon: PackedVector2Array = candidate["polygon"].duplicate()
	main.development_controls.style_input.select(1)
	main.development_controls.style_input.item_selected.emit(1)
	if main.region.development_candidates[candidate_id]["polygon"] != original_polygon:
		_fail("Changing street style moved the suggested district boundary.")
		return
	main.development_controls.allocation_input.value = 123456
	var initial_count: int = main.region.neighborhoods.size()
	var snapshot_buffer = WeekBuffer.new()
	main.active_snapshot_buffers.append(snapshot_buffer)
	main.zoning_button.pressed.emit()
	snapshot_buffer.mark_snapshot_ready()
	deadline = Time.get_ticks_msec() + 10000
	while (main.region.neighborhoods.size() == initial_count or main.road_rebuild_thread != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	var approved_id: int = int(main.region.development_candidate_keys.get(candidate["key"], -1))
	if main.region.neighborhoods.size() != initial_count + 1 or approved_id < 0 or int(main.region.development_candidates[approved_id]["neighborhood_id"]) < 0:
		_fail("Approving the suggested district did not build exactly one neighborhood.")
		return
	print("Suggested district is visible, clickable, and approvable without drawing; zoning draws %.1f ms overview, %.1f ms city." % [overview_draw_ms, city_draw_ms])
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
