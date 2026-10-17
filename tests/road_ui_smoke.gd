extends SceneTree

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
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
	_check(main.road_tool_selector.get_item_text(6) == "Demolish", "road tools must include demolition")
	_check(not main.road_tool_selector.disabled and main.map_view.detail_level == "Neighborhood", "full map must enable detailed road tools")
	var forward_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 0, 0)
	var reverse_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 1, 0)
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
	main.road_tool_selector.select(5)
	main._on_road_tool_selected(5)
	main.map_view.road_link_clicked.emit(link.id, midpoint)
	_check(main.pending_road_preview.get("kind", "") == "Widen", "widen tool must preview an existing link")
	main._cancel_road_preview()
	main.road_tool_selector.select(6)
	main._on_road_tool_selected(6)
	main.map_view.road_link_clicked.emit(link.id, midpoint)
	_check(main.pending_road_preview.get("ok", false) and main.pending_road_preview["components_after"] > 1, "demolition preview must disclose connectivity loss")
	var owner_balance: float = main.region.jurisdictions[link.owner_jurisdiction_id].treasury
	main._on_road_build_pressed()
	_check(main.region.road_links.size() == initial_links - 1 and is_equal_approx(main.region.jurisdictions[link.owner_jurisdiction_id].treasury, owner_balance), "demolition must remove a road without a refund")
	_check(main.traffic_state.link_ids.size() == main.region.road_links.size(), "rolling traffic must replan after demolition")
	main._on_jurisdiction_selected(main.region.region_ids[0])
	_check(not main.road_tool_selector.disabled and main.map_view.detail_level == "Neighborhood", "selecting a region must retain detailed road tools and map")
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
