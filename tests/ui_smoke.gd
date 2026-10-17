extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main = await UiFixture.attach_small(self)
	main._on_play_pressed()
	await process_frame
	_check(main.region.region_ids.size() == 4 and main.region.county_ids.size() == 8 and main.region.cities.size() == 32 and main.region.neighborhoods.size() == 62, "main scene must generate the state hierarchy")
	_check(main.flow_timeline.size.x > 0 and main.map_view.size.y > 0, "timeline and map must be visible")
	_check(main.selected_jurisdiction_id == 0 and main.map_view.detail_level == "Neighborhood" and main.inspector.text.contains("REGIONS"), "the full map must start with the state inspector")
	_check(main.state_tax_controls.visible and not main.jurisdiction_policy_controls.visible and not main.toll_controls.visible and not main.flow_detail_label.visible, "only controls for the selected scope and map mode should be visible")
	_check(main.purpose_selector.item_count == 4 and main.purpose_selector.get_item_text(3) == "Social", "purpose filter must retain all trip types")
	var first_region_id: int = main.region.region_ids[0]
	var region_label: Rect2 = main.map_view._jurisdiction_label_rect(main.region.jurisdictions[first_region_id])
	_check(main.map_view._hit_jurisdiction_label(region_label.get_center()) == first_region_id, "region labels must be clickable on the full map")
	var polygon: PackedVector2Array = main.region.jurisdictions[first_region_id].polygon_km
	_check(main.map_view._hit_jurisdiction_border(main.map_view._world_to_screen(polygon[0].lerp(polygon[1], 0.5))) >= 0, "region borders must be selectable")
	var mouse_click := InputEventMouseButton.new()
	mouse_click.button_index = MOUSE_BUTTON_LEFT
	mouse_click.position = region_label.get_center()
	mouse_click.pressed = true
	main.map_view._gui_input(mouse_click)
	mouse_click.pressed = false
	main.map_view._gui_input(mouse_click)
	_check(main.selected_jurisdiction_id == first_region_id and main.map_view.detail_level == "Neighborhood" and main.fiscal_label.text.contains("funds"), "clicking a region label must show its finances without changing the map")
	_check(main.inspector.text.contains("jurisdiction:%d" % main.region.jurisdictions[first_region_id].child_ids[0]), "the selected region must list its counties")
	var distant_neighborhood = main.region.neighborhoods[-1]
	_check(main.map_view._hit_test(main.map_view._world_to_screen(distant_neighborhood.position_km)) == distant_neighborhood.id, "selecting a region must leave distant neighborhoods visible and clickable")
	var current_time: int = main.calendar_clock.unix_seconds
	main.flow_timeline.time_selected.emit(17, 30)
	_check(main.calendar_clock.unix_seconds == current_time and not main.playing and main.inspected_hour == 17 and main.calendar_label.text.contains("forecast"), "chart scrubbing must inspect future demand without advancing the clock")
	main._on_play_pressed()
	main._sync_clock_view()
	_check(main.playing and main.inspected_hour == -1, "Play must return to the actual time")
	main._on_play_pressed()
	var frontier_bin: int = main.traffic_state.next_bin
	_check(frontier_bin > main.traffic_state.first_recorded_bin and frontier_bin < 96, "a completed bin must exist before testing a traffic wait")
	main.calendar_clock.set_time(frontier_bin / 4, frontier_bin % 4 * 15)
	main._sync_clock_view()
	var displayed_bin: int = main.map_view.selected_hour * 4 + floori(main.map_view.hour_fraction * 4.0)
	_check(main.map_view._is_recorded_time() and displayed_bin == frontier_bin - 1, "a waiting clock must keep showing the last completed road state")
	_check(main.flow_timeline.actual_hour * 4 + floori(main.flow_timeline.actual_fraction * 4.0) == frontier_bin, "the timeline must keep the actual clock position")
	main.inspected_hour = frontier_bin / 4
	main.inspected_minute = frontier_bin % 4 * 15
	main._sync_clock_view()
	_check(not main.map_view._is_recorded_time(), "explicit inspection of an uncalculated bin must stay marked as a forecast")
	main.inspected_hour = -1
	main._sync_clock_view()
	main.scope_breadcrumb.meta_clicked.emit("jurisdiction:0")
	main.tax_input.value = 12.0
	_check(is_equal_approx(main.region.jurisdictions[0].income_tax_rate, 0.10) and not main.region.pending_policy_changes.is_empty(), "state tax edits must wait until midnight")
	var county_id: int = main.region.county_ids[0]
	main.inspector.meta_clicked.emit("jurisdiction:%d" % first_region_id)
	main.inspector.meta_clicked.emit("jurisdiction:%d" % county_id)
	_check(main.selected_jurisdiction_id == county_id and main.map_view.detail_level == "Neighborhood" and not main.state_tax_controls.visible and main.jurisdiction_policy_controls.visible, "clicking a county must reveal its policies without changing map detail")
	var county_label: Rect2 = main.map_view._jurisdiction_label_rect(main.region.jurisdictions[county_id])
	_check(main.map_view._hit_jurisdiction_label(county_label.get_center()) == county_id, "county labels must be clickable")
	main.policy_input.value = 8.0
	_check(main.region.pending_policy_changes.any(func(change: Dictionary) -> bool: return int(change.get("jurisdiction_id", -1)) == county_id and change["property"] == "income_tax_rate"), "county policy control must queue an independent tax")
	var city_id: int = main.region.city_jurisdiction_ids[0]
	main.inspector.meta_clicked.emit("jurisdiction:%d" % city_id)
	_check(main.selected_jurisdiction_id == city_id and main.map_view.detail_level == "Neighborhood" and main.inspector.text.contains("NEIGHBORHOODS"), "clicking a city must reveal its neighborhoods without filtering the map")
	var city_label: Rect2 = main.map_view._jurisdiction_label_rect(main.region.jurisdictions[city_id])
	_check(main.map_view._hit_jurisdiction_label(city_label.get_center()) == city_id, "city labels must be clickable")
	var neighborhood_area_id: int = main.region.jurisdictions[city_id].child_ids[0]
	main.inspector.meta_clicked.emit("jurisdiction:%d" % neighborhood_area_id)
	_check(main.selected_jurisdiction_id == neighborhood_area_id and main.map_view.detail_level == "Neighborhood" and main.inspector.text.contains("HOUSING & WEALTH"), "clicking a neighborhood must open its statistics on the full map")
	main.scope_breadcrumb.meta_clicked.emit("jurisdiction:%d" % city_id)
	_check(main.selected_jurisdiction_id == city_id, "the breadcrumb must return from a neighborhood to its city")
	main.policy_input.value = 5.0
	_check(main.region.pending_policy_changes.any(func(change: Dictionary) -> bool: return int(change.get("jurisdiction_id", -1)) == city_id and change["property"] == "parking_fee"), "city fee control must queue a parking fee")
	var link = main.region.road_links[0]
	main._on_road_link_clicked(link.id, link.points[0].lerp(link.points[-1], 0.5))
	_check(main.toll_forward_input.editable and main.toll_controls.visible and not main.jurisdiction_policy_controls.visible and not main.scope_breadcrumb.visible and main.toll_label.text.contains("Road"), "road selection must expose its toll controls without unrelated policies")
	main.toll_forward_input.value = 7.0
	_check(main.region.pending_policy_changes.any(func(change: Dictionary) -> bool: return int(change.get("link_id", -1)) == link.id and change["property"] == "toll_forward"), "road toll edit must be queued for the next checkpoint")
	_check(main.inspector.text.contains("Owner:") and (main.inspector.text.contains("Forward queue:") or main.inspector.text.contains("still uncalculated")), "road inspector must show ownership and clearly mark traffic that is recalculating")
	if failures == 0:
		print("UI smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
