extends SceneTree

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._on_play_pressed()
	main.get_window().mode = Window.MODE_WINDOWED
	main.get_window().size = Vector2i(1024, 700)
	main.get_window().content_scale_size = Vector2i(1024, 700)
	await process_frame
	var map_rect: Rect2 = main.map_view.get_global_rect()
	var chart_rect: Rect2 = main.flow_timeline.get_global_rect()
	_check(map_rect.position.y + map_rect.size.y <= 701.0 and chart_rect.position.y + chart_rect.size.y < map_rect.position.y, "road tools, chart and map must fit in minimum window")
	_check(main.map_mode_selector.get_item_text(0) == "Roads" and main.map_mode_selector.get_item_text(1) == "Trips", "map must expose roads and trips views")
	_check(main.road_tool_selector.item_count == 7 and main.road_tool_selector.get_item_text(6) == "Demolish", "road tools must include demolition")
	_check(main.map_view._hit_road_node(main.map_view._world_to_screen(main.region.road_nodes[0].position_km)) == 0, "neighborhood gateway must be clickable")
	main.road_tool_selector.select(1)
	main._on_road_tool_selected(1)
	main.map_view.road_node_clicked.emit(0)
	main.map_view.road_node_clicked.emit(1)
	_check(main.pending_road_preview.get("ok", false) and not main.road_build_button.disabled, "two road node clicks must show an affordable build preview")
	_check(main.road_status_label.text.contains("Opens") and main.road_status_label.text.contains("$"), "preview must show cost and opening date")
	var initial_links: int = main.region.road_links.size()
	var days_until_open: int = main.pending_road_preview["days"]
	main._on_road_build_pressed()
	_check(main.region.road_projects.size() == 1 and main.region.road_links.size() == initial_links, "Build must fund a construction project without opening it early")
	main._on_speed_selected(4)
	main._on_play_pressed()
	main._process((float(days_until_open) * 24.0 + 1.0) / 256.0)
	_check(main.region.road_projects.is_empty() and main.region.road_links.size() == initial_links + 1, "fast forward must process each midnight and open the project on schedule")
	_check(main.traffic_profile.hourly_volumes[8].size() == main.region.road_links.size(), "traffic must rebuild against the opened road after fast forward")
	main._on_play_pressed()
	var first_link = main.region.road_links[0]
	var midpoint: Vector2 = first_link.points[0].lerp(first_link.points[1], 0.5)
	_check(main.map_view._hit_road_link(main.map_view._world_to_screen(midpoint)) == first_link.id, "road lines must be selectable on the map")
	var original_lanes: int = first_link.lanes_per_direction
	first_link.lanes_per_direction = 5
	var from_screen: Vector2 = main.map_view._world_to_screen(first_link.points[0])
	var to_screen: Vector2 = main.map_view._world_to_screen(first_link.points[1])
	var outer_lane_point: Vector2 = from_screen.lerp(to_screen, 0.5) + (to_screen - from_screen).normalized().orthogonal() * main.map_view._road_lane_offset(5, 0, 4)
	_check(outer_lane_point.distance_to(from_screen.lerp(to_screen, 0.5)) > 8.0 and main.map_view._hit_road_link(outer_lane_point) == first_link.id, "outer lanes of a wide road must remain clickable")
	var forward_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 0, 0)
	var reverse_side: Vector2 = Vector2.RIGHT.orthogonal() * main.map_view._road_lane_offset(2, 1, 0)
	_check(forward_side.y > 0.0 and reverse_side.y < 0.0 and main.map_view._road_lane_offset(2, 0, 0) != main.map_view._road_lane_offset(2, 0, 1), "each travel direction must occupy its right-hand lanes")
	first_link.lanes_per_direction = original_lanes
	main.map_view.road_link_clicked.emit(first_link.id, midpoint)
	_check(main.inspector.text.contains("Capacity:") and main.inspector.text.contains("Forward:") and main.inspector.text.contains("Upkeep:"), "road inspector must expose traffic and finances")
	main.road_tool_selector.select(5)
	main._on_road_tool_selected(5)
	main.map_view.road_link_clicked.emit(main.region.road_links[0].id, main.region.road_links[0].points[0])
	_check(main.pending_road_preview.get("kind", "") == "Widen" and main.pending_road_preview.get("ok", false), "widen tool must preview an existing road")
	main._cancel_road_preview()
	_check(main.pending_road_preview.is_empty() and main.road_build_button.disabled, "Cancel must clear uncommitted edits")
	main.road_tool_selector.select(6)
	main._on_road_tool_selected(6)
	var added_link_id: int = main.region.road_links[-1].id
	main.map_view.road_link_clicked.emit(added_link_id, main.region.road_links[-1].points[0])
	_check(main.pending_road_preview.get("ok", false) and main.pending_road_preview.get("components_after", 0) == 1 and main.road_build_button.text == "Demolish", "demolition must preview a redundant road without disconnecting neighborhoods")
	var balance_before: float = main.region.treasury
	main._on_road_build_pressed()
	_check(main.region.road_links.size() == initial_links and main.region.treasury == balance_before and main.traffic_profile.hourly_volumes[8].size() == initial_links, "demolition must remove a road immediately without a refund and rebuild traffic")
	main.map_view.road_link_clicked.emit(first_link.id, midpoint)
	_check(main.pending_road_preview.get("components_after", 0) > 1, "demolition preview must disclose when a tree edge disconnects neighborhoods")
	main._on_road_build_pressed()
	_check(main.region.road_links.size() == initial_links - 1 and main.road_status_label.text.contains("2 neighborhood road groups"), "player must be able to demolish a starting bridge road")
	var found_unreachable := false
	for neighborhood in main.region.neighborhoods:
		main._on_neighborhood_selected(neighborhood.id)
		if main.inspector.text.contains("no road route"):
			found_unreachable = true
		for line in main.inspector.get_parsed_text().split("\n"):
			if not line.contains("no road route"):
				continue
			var line_width: float = main.inspector.get_theme_default_font().get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			_check(line_width + 18.0 <= main.inspector.size.x, "unreachable travel status must fit the neighborhood inspector")
	_check(found_unreachable, "the inspector must identify destinations that have no road route")
	main.map_mode_selector.select(1)
	main._on_map_mode_selected(1)
	_check(main.map_view.map_mode == "Trips" and not main.map_view._get_net_flows().is_empty(), "Trips view must keep the existing OD visualization")
	if failures == 0:
		print("Road UI smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
