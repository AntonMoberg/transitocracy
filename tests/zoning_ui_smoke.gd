extends SceneTree

const RoadLand = preload("res://scripts/simulation/road_land.gd")


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
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0 and not RoadLand.contains_reserved(main.region, candidate["center_km"]):
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
	var controls = main.development_controls
	var initial_polygon: PackedVector2Array = candidate["polygon"].duplicate()
	controls.style_input.select(1)
	controls.style_input.item_selected.emit(1)
	deadline = Time.get_ticks_msec() + 10000
	while main.region.development_candidates[candidate_id]["layout"].interior_style != "Organic" and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.development_candidates[candidate_id]["layout"].interior_style != "Organic" or main.region.development_candidates[candidate_id]["polygon"] != initial_polygon:
		push_error("Organic approval choice must change the street preview without moving the neighbourhood boundary.")
		quit(1)
		return
	controls.character_input.select(4)
	controls.character_input.item_selected.emit(4)
	deadline = Time.get_ticks_msec() + 10000
	while main.region.development_candidates[candidate_id].get("character_override", "Auto") != "Large Plot" and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.development_candidates[candidate_id]["character_profile"] != "Large Plot":
		push_error("Neighbourhood character selection must update the zoning preview.")
		quit(1)
		return
	for zone in controls.zone_inputs:
		controls.zone_inputs[zone].value = 100 if zone == "Residential" else 0
		controls.density_inputs[zone].select(2)
	controls._preview()
	controls.allocation_input.value = 123456
	if not controls.preview_label.text.contains("homes") or controls.apply_button.disabled == false:
		push_error("Unapproved zoning must preview capacity without applying edits early.")
		quit(1)
		return
	var initial_count: int = main.region.neighborhoods.size()
	var snapshot_buffer = preload("res://scripts/simulation/multiscale_week_buffer.gd").new()
	main.active_snapshot_buffers.append(snapshot_buffer)
	main.zoning_button.pressed.emit()
	main.zoning_button.pressed.emit()
	main._on_jurisdiction_selected(0)
	snapshot_buffer.mark_snapshot_ready()
	deadline = Time.get_ticks_msec() + 10000
	while (main.region.neighborhoods.size() == initial_count or main.road_rebuild_thread != null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region.neighborhoods.size() != initial_count + 1 or main.road_rebuild_thread != null:
		push_error("Zoning approval did not create and rebuild one neighborhood.")
		quit(1)
		return
	var neighborhood_id: int = main.region.development_candidates[candidate_id]["neighborhood_id"]
	var plan = main.region.neighborhoods[neighborhood_id].development_plan
	if main.region.neighborhoods[neighborhood_id].street_layout.interior_style != "Organic":
		push_error("Approval must retain the chosen interior street style.")
		quit(1)
		return
	if main.region.neighborhoods[neighborhood_id].character_profile != "Large Plot":
		push_error("Approval and worker rebuild must retain the chosen character.")
		quit(1)
		return
	if plan.reserved != 123456 or plan.pending_zoning.get("shares", {}).get("Residential", 0) != 100:
		push_error("Approval must retain the custom allocation and draft zoning for the next day.")
		quit(1)
		return
	if not main.region.neighborhoods[neighborhood_id].development_approved or main.map_view.region != main.region:
		push_error("Approved neighborhood or map state was stale after the worker rebuild.")
		quit(1)
		return
	main._on_candidate_selected(candidate_id)
	controls.allocation_input.value = 100
	controls.allocation_buttons[0].pressed.emit()
	deadline = Time.get_ticks_msec() + 10000
	while plan.reserved == 123456 and Time.get_ticks_msec() < deadline:
		await process_frame
	if plan.reserved != 123556:
		push_error("The top-up control must add the entered amount to the selected plan.")
		quit(1)
		return
	controls.allocation_buttons[1].pressed.emit()
	deadline = Time.get_ticks_msec() + 10000
	while plan.reserved == 123556 and Time.get_ticks_msec() < deadline:
		await process_frame
	if plan.reserved != 123456:
		push_error("The return control must release only the entered amount of unused reserves.")
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
	print("Zoning selection, draft allocation, deferred approval isolation, async rebuild, and withdrawal passed.")
	quit(0)
