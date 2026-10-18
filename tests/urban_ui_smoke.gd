extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")
const Local = preload("res://scripts/simulation/local_street_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = await UiFixture.attach_small(self)
	main.playing = false
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1024, 700)
	root.content_scale_size = Vector2i(1024, 700)
	await process_frame
	var map = main.map_view
	var layout = main.region.neighborhoods[0].street_layout
	map.zoom = 300.0 / map._map_scale()
	map.pan = -(layout.bounds.get_center() - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	await process_frame
	var errors := PackedStringArray()
	if map.urban_layer.last_street_count == 0 or map.urban_layer.last_building_count == 0:
		errors.append("Street zoom must draw actual local roads and occupied building footprints.")
	var local_edge := -1
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] == "Local":
			local_edge = edge_id
			break
	if local_edge >= 0:
		var edge: Vector2 = layout.edges[local_edge]
		var point: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)].lerp(layout.nodes[int(edge.y)], 0.5))
		if map.urban_layer.hit_street(map, point).x != 0:
			errors.append("Visible local streets must be selectable at their actual location.")
		map.local_street_selected.emit(0, local_edge)
		main._refresh_inspector(false)
		if not main.inspector.text.contains("Arrival demand:") or not main.inspector.text.contains("Manage neighborhood funding"):
			errors.append("Local street selection must open the live-flow inspector and funding link.")
	main._on_map_mode_selected(2)
	for candidate in main.region.development_candidates:
		if candidate["neighborhood_id"] < 0 and candidate["frontage_link_id"] >= 0:
			main._on_candidate_selected(candidate["id"])
			break
	await process_frame
	await process_frame
	var controls = main.development_controls
	controls.zoning_popup.popup_centered(Vector2i(360, 0))
	await process_frame
	await process_frame
	if not controls.zoning_popup.visible or controls.zoning_popup.size.y >= 650:
		errors.append("The zoning editor must fit inside a small MacBook window.")
	controls.zoning_popup.hide()
	await process_frame
	if map.size.y < 250.0 or main.inspector.size.y < 70.0:
		errors.append("Development controls must leave the map and inspector usable at 1024 × 700: map %s, inspector %s." % [map.size, main.inspector.size])
	if not errors.is_empty():
		push_error("; ".join(errors))
	else:
		print("Street buildings, local-road selection, development controls, and small-window zoning editor passed.")
	quit(1 if not errors.is_empty() else 0)
