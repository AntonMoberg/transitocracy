extends SceneTree

const RoadLand = preload("res://scripts/simulation/road_land.gd")
const GrowthAreas = preload("res://scripts/simulation/growth_area_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")


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
	for city_id in range(main.region.cities.size()):
		var city: Dictionary = main.region.cities[city_id]
		var policy: Dictionary = city["growth_policy"]
		policy["enabled"] = false
		city["growth_policy"] = policy
		main.region.cities[city_id] = city
	main._discard_pending_day()
	main.map_mode_selector.select(2)
	main._on_map_mode_selected(2)
	var candidate_id := -1
	var paint_point := Vector2.ZERO
	var drawn_polygon := PackedVector2Array()
	for candidate in main.region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or int(candidate["frontage_link_id"]) < 0 or RoadLand.contains_reserved(main.region, candidate["center_km"]):
			continue
		var route: PackedVector2Array = candidate["layout_input"]["route"]
		if route.size() != 2:
			continue
		var nearest: Vector2 = route[0]
		var nearest_distance := INF
		for index in range(1, route.size()):
			var projected: Vector2 = Geometry2D.get_closest_point_to_segment(candidate["center_km"], route[index - 1], route[index])
			if projected.distance_to(candidate["center_km"]) < nearest_distance:
				nearest = projected
				nearest_distance = projected.distance_to(candidate["center_km"])
		var axis: Vector2 = (route[1] - route[0]).normalized()
		var normal: Vector2 = (candidate["center_km"] - nearest).normalized()
		for width in [0.45, 0.35]:
			var polygon := PackedVector2Array([nearest - axis * width, nearest + axis * width, nearest + axis * width + normal * 0.85, nearest - axis * width + normal * 0.85])
			var clipped: PackedVector2Array = GrowthAreas.clip_to_city(main.region, int(candidate["city_id"]), polygon)
			if Geography.polygon_area(polygon) - Geography.polygon_area(clipped) < 0.01 and DevelopmentPlanner._simple_growth_outline(polygon) and not GrowthAreas.plan(main.region, int(candidate["city_id"]), polygon, "ui-probe", {}, "Grid", true).is_empty():
				candidate_id = candidate["id"]
				paint_point = candidate["center_km"]
				drawn_polygon = polygon
				break
		if candidate_id >= 0:
			break
	if candidate_id < 0:
		push_error("No space for an exact four-corner district was generated beside an arterial.")
		quit(1)
		return
	var map = main.map_view
	map.zoom = 32.0
	map.pan = -(paint_point - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	main.zoning_tool_selector.select(1)
	main._on_zoning_tool_selected(1)
	for corner in drawn_polygon:
		_click_map(map, map._world_to_screen(corner))
	if map.growth_polygon_anchors.size() != 4:
		push_error("Draw mode did not retain four polygon corners.")
		quit(1)
		return
	main.zoning_angle_snap_toggle.button_pressed = true
	main._on_zoning_angle_snap_toggled(true)
	if not main.zoning_angle_snap_toggle.visible or not map.growth_angle_snap_enabled:
		push_error("The zoning angle snap toggle did not reach the polygon tool.")
		quit(1)
		return
	var free_point: Vector2 = (drawn_polygon[0] + drawn_polygon[1] + drawn_polygon[2] + drawn_polygon[3]) * 0.25
	var free_screen: Vector2 = map._world_to_screen(free_point)
	var angle_preview: Dictionary = map._growth_snap_at(free_screen)
	if not angle_preview.get("angle_snapped", false):
		push_error("A free zoning corner did not show its snapped angle.")
		quit(1)
		return
	_click_map(map, free_screen)
	if map.growth_polygon_anchors.size() != 5 or map.growth_polygon_anchors[-1]["point"].distance_to(angle_preview["point"]) > 0.0001:
		push_error("The placed zoning corner did not match the angle-snapped preview.")
		quit(1)
		return
	map.undo_growth_corner()
	main.zoning_angle_snap_toggle.button_pressed = false
	main._on_zoning_angle_snap_toggled(false)
	var expected_outline: PackedVector2Array = GrowthAreas.outline_from_anchors(main.region, map.growth_polygon_anchors)
	var close_click: Vector2 = map._world_to_screen(map.growth_polygon_anchors[0]["point"]) + Vector2(13, 0)
	if not map._growth_close_hit(close_click) or not map._growth_snap_at(close_click).get("closing", false):
		push_error("The first corner must have a forgiving, visible polygon closure target.")
		quit(1)
		return
	_click_map(map, close_click)
	if main.selected_candidate_id < 0:
		push_error("Drawing a polygon did not create a growth preview: %s" % main.road_status_label.text)
		quit(1)
		return
	candidate_id = main.selected_candidate_id
	var candidate: Dictionary = main.region.development_candidates[candidate_id]
	if not candidate.has("growth_draft_id"):
		push_error("Drawn growth was not selected.")
		quit(1)
		return
	if absf(Geography.polygon_area(candidate["polygon"]) - Geography.polygon_area(expected_outline)) > 0.01:
		push_error("The district preview expanded beyond the snapped drawn outline.")
		quit(1)
		return
	main.zoning_tool_selector.select(0)
	main._on_zoning_tool_selected(0)
	if main.selected_candidate_id != candidate_id or not main.zoning_controls.visible or main.zoning_button.disabled:
		push_error("Painting did not open the zoning approval panel.")
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
	var manual_matches := 0
	for new_id in range(initial_count, main.region.neighborhoods.size()):
		if main.region.neighborhoods[new_id].street_layout.key == candidate["key"]:
			manual_matches += 1
	if manual_matches != 1 or main.road_rebuild_thread != null:
		push_error("Zoning approval did not create and rebuild the drawn district exactly once: matches %d, rebuild %s, status %s." % [manual_matches, str(main.road_rebuild_thread), main.zoning_status_label.text])
		quit(1)
		return
	candidate_id = int(main.region.development_candidate_keys.get(candidate["key"], -1))
	if candidate_id < 0:
		push_error("Approved painted growth lost its stable plan key.")
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


func _click_map(map, point: Vector2) -> void:
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
