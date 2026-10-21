extends SceneTree

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const UiFixture = preload("res://tests/ui_fixture.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main = await UiFixture.attach_small(self)
	main._on_play_pressed()
	main.get_window().mode = Window.MODE_WINDOWED
	main.get_window().size = Vector2i(1024, 700)
	main.get_window().content_scale_size = Vector2i(1024, 700)
	await process_frame
	_check(main.map_view.size.x > 0 and main.map_view.size.y >= 300 and main.flow_timeline.size.y > 0, "road map and chart must remain usable at the minimum window size")
	_check(main.inspector.size.y >= 90, "the hierarchy inspector must remain readable at the minimum window size")
	var label_rects: Array[Rect2] = []
	for area in main.region.jurisdictions:
		if area.kind not in ["Region", "County", "City"]:
			continue
		if not main.map_view._jurisdiction_label_visible(area):
			continue
		var label_rect: Rect2 = main.map_view._jurisdiction_label_rect(area)
		var font_size: int = 11 if area.kind == "Region" else (10 if area.kind == "County" else 9)
		var text_width: float = main.map_view.get_theme_default_font().get_string_size(main.map_view._jurisdiction_label_text(area), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		_check(text_width <= label_rect.size.x - 8.0, "%s label must fit at the minimum window size" % area.name)
		for prior_rect in label_rects:
			_check(not label_rect.intersects(prior_rect), "%s label must not overlap another jurisdiction label" % area.name)
		label_rects.append(label_rect)
	var widen_index := -1
	var demolish_index := -1
	for tool_index in range(main.road_tool_selector.item_count):
		if main.road_tool_selector.get_item_text(tool_index) == "Widen":
			widen_index = tool_index
		elif main.road_tool_selector.get_item_text(tool_index) == "Demolish":
			demolish_index = tool_index
	_check(widen_index >= 0 and demolish_index >= 0, "road tools must include widening and demolition")
	_check(not main.road_tool_selector.disabled and main.map_view.detail_level == "Neighborhood", "full map must enable detailed road tools")
	main.road_tool_selector.select(1)
	main._on_road_tool_selected(1)
	main.road_draw_selector.select(2)
	main._on_road_draw_selected(2)
	main.road_snap_toggle.button_pressed = true
	main._on_road_snap_toggled(true)
	main.road_length_snap_toggle.button_pressed = true
	main._on_road_length_snap_toggled(true)
	_check(main.road_draw_selector.visible and main.map_view.road_draw_mode == "Multi-point Curved" and main.map_view.road_snap_enabled and main.map_view.road_length_snap_enabled, "road mode and both snap controls must reach the map")
	var forward_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 0, 0, "Highway")
	var reverse_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 1, 0, "Highway")
	_check(forward_side.y > 0.0 and reverse_side.y < 0.0, "road directions must keep right-hand lanes")
	var preview: Dictionary = {}
	for first_id in range(mini(20, main.region.road_nodes.size())):
		for second_id in range(first_id + 1, mini(25, main.region.road_nodes.size())):
			var candidate: Dictionary = RoadPlanner.link_preview(main.region, first_id, second_id, "Arterial", PackedVector2Array(), main._current_day_key())
			if candidate.get("ok", false) and main.region.jurisdictions[candidate["owner_id"]].treasury >= candidate["cost"]:
				preview = candidate
				break
		if not preview.is_empty():
			break
	_check(not preview.is_empty(), "an affordable arterial project must be available")
	var multi_case: Dictionary = {}
	for candidate_link in main.region.road_links:
		if candidate_link.road_class != "Arterial" or candidate_link.points.size() < 2:
			continue
		for end_index in range(2):
			var start_id: int = candidate_link.from_node_id if end_index == 0 else candidate_link.to_node_id
			var start: Vector2 = main.region.road_nodes[start_id].position_km
			var outward: Vector2 = (candidate_link.points[0] - candidate_link.points[1]).normalized() if end_index == 0 else (candidate_link.points[-1] - candidate_link.points[-2]).normalized()
			for side in [-1.0, 1.0]:
				var offset: Vector2 = outward.orthogonal() * 0.06 * side
				var guide_one: Vector2 = start + outward * 0.25 + offset
				var end_one: Vector2 = start + outward * 0.5
				var guide_two: Vector2 = start + outward * 0.75 + offset
				var end_two: Vector2 = start + outward
				var anchors := PackedVector2Array([guide_one, end_one, guide_two])
				if RoadPlanner.player_route(main.region, start_id, end_two, "Arterial", anchors, RoadRouteBuilder.MULTIPOINT).is_empty():
					continue
				var multi_preview: Dictionary = RoadPlanner.link_preview(main.region, start_id, -1, "Arterial", anchors, main._current_day_key(), RoadRouteBuilder.MULTIPOINT, end_two)
				if multi_preview.get("ok", false):
					multi_case = {"start_id": start_id, "guide_one": guide_one, "end_one": end_one, "guide_two": guide_two, "end_two": end_two, "preview": multi_preview}
					break
			if not multi_case.is_empty():
				break
		if not multi_case.is_empty():
			break
	_check(not multi_case.is_empty(), "a valid two-curve arterial should be available for the road tool")
	if not multi_case.is_empty():
		main.road_snap_toggle.button_pressed = false
		main._on_road_snap_toggled(false)
		main._on_road_node_clicked(multi_case["start_id"])
		var origin: Vector2 = main.region.road_nodes[multi_case["start_id"]].position_km
		main._on_road_empty_clicked(origin + Vector2(0.101, 0.003))
		_check(main.road_waypoints.size() == 1 and is_equal_approx(main.road_waypoints[0].distance_to(origin), 0.1), "the placed multi-curve guide must use the 5 m length snap")
		main._cancel_road_preview()
		main.road_snap_toggle.button_pressed = false
		main._on_road_snap_toggled(false)
		main.road_length_snap_toggle.button_pressed = false
		main._on_road_length_snap_toggled(false)
		main._on_road_node_clicked(multi_case["start_id"])
		main._on_road_empty_clicked(multi_case["guide_one"])
		_check(main.road_waypoints.size() == 1, "the first multi-curve click should place a guide")
		main._on_road_empty_clicked(multi_case["end_one"])
		var frozen_first: PackedVector2Array = main.map_view.preview_frozen_route.duplicate()
		_check(main.road_waypoints.size() == 2 and frozen_first.size() > 2, "the second click should lock the first curve")
		main._on_road_empty_clicked(multi_case["guide_two"])
		_check(main.road_waypoints.size() == 3 and main.map_view.preview_frozen_route == frozen_first, "the next guide should leave the first curve fixed")
		main._on_road_empty_clicked(multi_case["end_two"])
		_check(main.road_waypoints.size() == 4 and main.map_view.preview_frozen_route.size() > frozen_first.size(), "the fourth click should lock a second curve")
		main._on_road_empty_double_clicked(multi_case["end_two"])
		_check(main.pending_road_preview.get("ok", false) and main.pending_road_preview.get("points", PackedVector2Array()) == multi_case["preview"]["points"], "double clicking a locked end should finish the two-curve route")
		main._cancel_road_preview()
	var initial_links: int = main.region.road_links.size()
	if not preview.is_empty():
		main.pending_road_preview = preview.duplicate(true)
		main._update_road_status()
		_check(main.road_status_label.text.contains(main.region.jurisdictions[preview["owner_id"]].name), "road preview must name its funding jurisdiction")
		var original_balance: float = main.region.jurisdictions[preview["owner_id"]].treasury
		main._on_road_build_pressed()
		_check(main.region.road_projects.size() == 1 and main.region.road_links.size() == initial_links, "funded roads must stay closed until construction ends")
		_check(is_equal_approx(main.region.jurisdictions[preview["owner_id"]].treasury, original_balance - preview["cost"]), "construction must debit only its owner")
	var link = main.region.road_links[0]
	var midpoint: Vector2 = link.points[0].lerp(link.points[-1], 0.5)
	for candidate in main.region.road_links:
		var candidate_midpoint: Vector2 = candidate.points[0].lerp(candidate.points[-1], 0.5)
		if main.map_view._hit_road_link(main.map_view._world_to_screen(candidate_midpoint)) == candidate.id:
			link = candidate
			midpoint = candidate_midpoint
			break
	_check(main.map_view._hit_road_link(main.map_view._world_to_screen(midpoint)) == link.id, "visible road must remain clickable")
	main.road_tool_selector.select(widen_index)
	main._on_road_tool_selected(widen_index)
	main.map_view.road_link_clicked.emit(link.id, midpoint)
	_check(main.pending_road_preview.get("kind", "") == "Widen", "widen tool must preview an existing link")
	main._cancel_road_preview()
	main.road_tool_selector.select(demolish_index)
	main._on_road_tool_selected(demolish_index)
	main.map_view.road_link_clicked.emit(link.id, midpoint)
	_check(main.pending_road_preview.get("ok", false) and main.pending_road_preview["components_after"] > 1, "demolition preview must disclose connectivity loss")
	var owner_balance: float = main.region.jurisdictions[link.owner_jurisdiction_id].treasury
	main._on_road_build_pressed()
	_check(main.region.road_links.size() == initial_links - 1 and is_equal_approx(main.region.jurisdictions[link.owner_jurisdiction_id].treasury, owner_balance), "demolition must remove a road without a refund")
	_check(main.traffic_state.link_ids.size() == main.region.road_links.size(), "rolling traffic must replan after demolition")
	main._on_jurisdiction_selected(main.region.region_ids[0])
	_check(not main.road_tool_selector.disabled and main.map_view.detail_level == "Neighborhood", "selecting a region must retain detailed road tools and map")
	_check(main.fiscal_label.tooltip_text.contains("State grants"), "regional inspector must disclose grants alongside road upkeep")
	_check(main.fiscal_label.text.contains("$%s available" % main._format_count(roundi(main.region.jurisdictions[main.region.region_ids[0]].treasury))), "regional inspector must show its own spendable treasury")
	main.map_mode_selector.select(1)
	main._on_map_mode_selected(1)
	_check(main.map_view.map_mode == "Trips", "full map must retain the trip layer")
	if failures == 0:
		print("Road UI smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
