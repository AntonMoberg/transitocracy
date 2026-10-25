extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")
const Local = preload("res://scripts/simulation/local_street_traffic.gd")
const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")


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
	var ready: bool = await UiFixture.settle_map(self, map)
	print("Urban publication: %d buildings, %d streets; renderer %.2f ms" % [map.urban_layer.last_building_count, map.urban_layer.last_street_count, map.chunk_renderer.last_tick_us / 1000.0])
	var errors := PackedStringArray()
	if not ready:
		errors.append("Urban geometry did not finish publishing.")
	for placeholder in main.region.neighborhoods:
		if placeholder.street_layout != null:
			continue
		if main.region.jurisdiction_at_point(placeholder.position_km) == placeholder.jurisdiction_id or map._hit_test(map._world_to_screen(placeholder.position_km)) == placeholder.id:
			errors.append("City seed slots without arterial layouts must not appear as selectable neighbourhoods.")
		break
	if map.urban_layer.last_street_count == 0 or map.urban_layer.last_building_count == 0:
		errors.append("Street zoom must draw actual local roads and occupied building footprints.")
	var buildings_before: int = map.urban_layer.last_building_count
	var neighborhood = main.region.neighborhoods[0]
	var covered := false
	for block_id in range(layout.blocks.size()):
		if block_id >= neighborhood.block_zoning.size() or neighborhood.block_zoning[block_id] == 0:
			continue
		var block: Dictionary = layout.blocks[block_id]
		if block["phase"] > neighborhood.development_plan.completed_phase:
			continue
		var code: int = neighborhood.block_zoning[block_id] - 1
		var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][code / 3]
		var footprints: Array = ParcelGeometry.buildings(block, zone, code % 3, neighborhood.character_profile)
		for building_id in range(footprints.size()):
			var appearance: float = float(posmod(int(block["seed"]) + building_id * 7919, 1000)) / 1000.0
			if appearance > neighborhood.built_fraction:
				continue
			var footprint: PackedVector2Array = footprints[building_id]
			if RoadLand.polygon_intersects_masks(footprint, RoadLand.masks_for_bounds(main.region, layout.bounds)):
				continue
			var screen_bounds := Rect2(map._world_to_screen(footprint[0]), Vector2.ZERO)
			for vertex in footprint:
				screen_bounds = screen_bounds.expand(map._world_to_screen(vertex))
			if not screen_bounds.intersects(Rect2(Vector2.ZERO, map.size)):
				continue
			var bounds := Rect2(footprint[0], Vector2.ZERO)
			for vertex in footprint:
				bounds = bounds.expand(vertex)
			main.region.road_reservations.append({"bounds": bounds, "masks": [footprint], "road_class": "Highway", "link_id": -1, "project_id": -1})
			covered = true
			break
		if covered:
			break
	if covered:
		map.queue_redraw()
		await UiFixture.settle_map(self, map)
		if map.urban_layer.last_building_count >= buildings_before:
			errors.append("Highway land reservations must clear building footprints beneath them.")
		main.region.road_reservations.pop_back()
	else:
		errors.append("The fixture needs a visible building for the highway clearance check.")
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
	main._on_map_mode_selected(0)
	if main.map_mode_selector.item_count != 3:
		errors.append("Roads, Trips, and Zoning must be the only map modes.")
	map.terrain_toggle_button.button_pressed = true
	await process_frame
	await process_frame
	if map.map_mode != "Roads" or not map.show_terrain_overlay:
		errors.append("Terrain toggle must add relief without changing map mode.")
	if map.urban_layer.last_building_count == 0:
		errors.append("Terrain relief must preserve visible building footprints.")
	if map.traffic_toggle_button.disabled:
		errors.append("Traffic overlay must remain available with terrain relief.")
	map.set_base_map_style("Satellite")
	await process_frame
	await process_frame
	if map.urban_layer.last_building_count == 0 or map.map_mode != "Roads":
		errors.append("Satellite style must preserve road mode and visible building footprints.")
	if not map.terrain_toggle_button.disabled or map.traffic_toggle_button.disabled or map.transit_toggle_button.disabled:
		errors.append("Satellite style must offer Traffic and Transit layers without Terrain.")
	map.transit_toggle_button.button_pressed = true
	if not map.show_transit_overlay:
		errors.append("Transit layer must be switchable over Satellite.")
	map.set_base_map_style("Map")
	map.traffic_toggle_button.button_pressed = false
	if map.show_traffic_overlay:
		errors.append("Traffic toggle must turn off congestion coloring.")
	map.terrain_toggle_button.button_pressed = false
	if map.show_terrain_overlay:
		errors.append("Terrain toggle must restore the flat map colors.")
	if map.traffic_toggle_button.disabled:
		errors.append("Traffic overlay must remain available in Roads view.")
	if not errors.is_empty():
		push_error("; ".join(errors))
	else:
		print("Street buildings, local-road selection, development controls, and small-window zoning editor passed.")
	quit(1 if not errors.is_empty() else 0)
