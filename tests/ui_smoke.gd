extends SceneTree

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._on_play_pressed()
	main.get_window().mode = Window.MODE_WINDOWED
	main.get_window().size = Vector2i(1024, 700)
	main.get_window().content_scale_size = Vector2i(1024, 700)
	await process_frame
	_check(main.map_view.size.x > 0 and main.map_view.size.y > 0, "map must have visible layout size")
	_check(main.flow_timeline.size.x > 0 and main.flow_timeline.size.y > 0, "hour chart must have visible layout size")
	_check(main.region.cities.size() == 8 and main.region.neighborhoods.size() == 64, "main scene must generate eight cities with eight neighborhoods each")
	_check(main.purpose_selector.get_item_text(0) == "All" and main.purpose_selector.get_item_text(1) == "Work" and main.purpose_selector.get_item_text(2) == "Commercial" and main.purpose_selector.get_item_text(3) == "Social", "flow filter must expose the four requested purposes")
	_check(main.calendar_label.text.contains("2030") and main.calendar_label.text.contains("07:00"), "calendar must display its initial date and hour")
	_send_key(main, KEY_SPACE)
	_check(main.playing and main.play_button.text == "Pause", "Space must resume the simulation")
	main._process(0.5)
	_check(main.calendar_clock.get_hour() == 7 and main.calendar_clock.get_minute() == 30, "half a second at 1× must advance the clock by 30 minutes")
	_check(main.calendar_label.text.contains("07:30") and is_equal_approx(main.map_view.hour_fraction, 0.5), "clock and map must show the interpolated half-hour")
	_send_key(main, KEY_SPACE)
	_check(not main.playing and main.play_button.text == "Play", "Space must pause at the current minute")
	main._process(10.0)
	_check(main.calendar_clock.get_minute() == 30, "paused time must remain frozen")
	_send_key(main, KEY_SPACE, true)
	_check(not main.playing, "holding Space must not repeatedly toggle playback")
	_send_key(main, KEY_2)
	_check(is_equal_approx(main.speed_multiplier, 4.0) and main.speed_selector.selected == 1 and not main.playing, "2 must select 4× speed without resuming")
	_send_key(main, KEY_3)
	_check(is_equal_approx(main.speed_multiplier, 16.0) and main.speed_selector.selected == 2, "3 must select 16× speed")
	_send_key(main, KEY_4)
	_check(is_equal_approx(main.speed_multiplier, 64.0) and main.speed_selector.selected == 3 and not main.playing, "4 must select 64× speed without resuming")
	_send_key(main, KEY_KP_5)
	_check(is_equal_approx(main.speed_multiplier, 256.0) and main.speed_selector.selected == 4, "5 and keypad 5 must select 256× speed")
	_send_key(main, KEY_KP_1)
	_check(is_equal_approx(main.speed_multiplier, 1.0) and main.speed_selector.selected == 0, "1 must select normal speed")
	_send_key(main, KEY_SPACE)
	_check(main.playing and main.play_button.text == "Pause", "Space must resume the simulation")
	main._process(0.25)
	_check(main.calendar_clock.get_hour() == 7 and main.calendar_clock.get_minute() == 45, "resuming must continue from the paused minute")
	_send_key(main, KEY_2)
	main._process(0.0625)
	_check(main.calendar_clock.get_hour() == 8 and main.calendar_clock.get_minute() == 0, "4× playback must advance from the current minute without resetting it")
	_send_key(main, KEY_1)
	main.seed_input.get_line_edit().grab_focus()
	_send_key(main, KEY_5)
	_send_key(main, KEY_SPACE)
	_check(is_equal_approx(main.speed_multiplier, 1.0) and main.playing, "shortcuts must not interfere with seed entry")
	main.seed_input.get_line_edit().release_focus()
	main.calendar_clock.set_time(23, 30)
	main._sync_clock_view()
	var tomorrow_profile = main.next_day_profile
	main._process(0.5)
	_check(main.calendar_clock.get_hour() == 0 and main.calendar_clock.get_minute() == 0 and main.flow_profile != tomorrow_profile and main.flow_profile.active_day_key == tomorrow_profile.active_day_key, "midnight must rebuild tomorrow's flow from updated neighborhood statistics")
	_check(main.dynamics_label.text.contains("Today:") and main.inspector.text.contains("Desirability:"), "daily migration and desirability must be visible")
	var earlier_desirability: float = main.region.neighborhoods[0].desirability
	main.tax_input.value = 40
	_check(is_equal_approx(main.region.income_tax_rate, 0.4) and main.region.neighborhoods[0].desirability < earlier_desirability, "tax control must update neighborhood desirability immediately")
	main.tax_input.value = 10
	_send_key(main, KEY_SPACE)
	main._on_purpose_selected(1)
	main.map_view.set_hour(8)
	var morning_flows: Array[Dictionary] = main.map_view._get_net_flows()
	var has_outgoing_dash := false
	for flow in morning_flows:
		if main.map_view._is_outgoing_from_selected(flow):
			has_outgoing_dash = true
	main.map_view.set_hour(17)
	var evening_flows: Array[Dictionary] = main.map_view._get_net_flows()
	var has_incoming_solid := false
	for flow in evening_flows:
		if flow["destination"] == main.map_view.selected_id and not main.map_view._is_outgoing_from_selected(flow):
			has_incoming_solid = true
	var evening_by_pair: Dictionary = {}
	for flow in evening_flows:
		evening_by_pair[flow["pair_key"]] = flow
	_check(morning_flows.size() > 0, "map must display net commute arrows at the morning peak")
	_check(has_outgoing_dash and has_incoming_solid, "outbound and inbound routes must receive different line styles")
	var matched_pairs := 0
	for flow in morning_flows:
		if not evening_by_pair.has(flow["pair_key"]):
			continue
		matched_pairs += 1
		var reverse_flow: Dictionary = evening_by_pair[flow["pair_key"]]
		_check(flow["origin"] == reverse_flow["destination"] and flow["destination"] == reverse_flow["origin"], "map arrows must reverse at the evening peak")
	_check(matched_pairs > 0, "map must show the same neighborhood pairs at both rush hours")
	main._on_purpose_selected(2)
	_check(main.map_view.selected_purpose == "Commercial" and main.map_view._get_net_flows().size() > 0, "commercial filter must display trips to retail destinations")
	_check(main.flow_timeline.selected_purpose == "Commercial" and main.flow_detail_label.text.contains("Commercial"), "chart and neighborhood counts must follow the selected purpose")
	_check(is_equal_approx(main.flow_timeline._hourly_values("Commercial")[12], main.flow_profile.get_hourly_total(12, "Commercial")), "commercial chart must plot only commercial trips")
	main._on_purpose_selected(3)
	main.map_view.set_hour(7)
	var early_social_flows: Array[Dictionary] = main.map_view._get_net_flows()
	_check(early_social_flows.size() > main.region.neighborhoods.size(), "quiet-hour social travel must still show multiple residential routes")
	early_social_flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	var displayed_social_flows: Array[Dictionary] = main.map_view._choose_flows_for_display(early_social_flows)
	var covered_neighborhoods: Dictionary = {}
	for flow in displayed_social_flows:
		covered_neighborhoods[flow["origin"]] = true
		covered_neighborhoods[flow["destination"]] = true
	for neighborhood in main.region.neighborhoods:
		if neighborhood.population > 0:
			_check(covered_neighborhoods.has(neighborhood.id), "social arrows should reach every populated neighborhood")
	main.map_view.set_hour(20)
	var evening_social_flows: Array[Dictionary] = main.map_view._get_net_flows()
	evening_social_flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	_check(main.map_view.selected_purpose == "Social" and evening_social_flows.size() > 0, "social filter must display residential visit flows")
	_check(main.map_view._choose_flows_for_display(evening_social_flows).size() > displayed_social_flows.size(), "social map must show more routes at the evening peak than at the quiet morning hour")
	_check(main.flow_detail_label.text.contains("Social") and main.hourly_trip_label.text.contains("social"), "social counts must appear in the inspector and hourly summary")
	_check(main.flow_timeline.selected_purpose == "Social" and is_equal_approx(main.flow_timeline._hourly_values("Social")[20], main.flow_profile.get_hourly_total(20, "Social")), "social filter must show only the social line")
	main._on_purpose_selected(0)
	main.map_view.set_hour(17)
	var all_map_purposes: Dictionary = {}
	for flow in main.map_view._get_net_flows():
		all_map_purposes[flow["purpose"]] = true
	_check(all_map_purposes.has("Work") and all_map_purposes.has("Commercial") and all_map_purposes.has("Social"), "All map must preserve each trip type for purpose colors")
	_check(main.map_view._purpose_color("Work") != main.map_view._purpose_color("Commercial") and main.map_view._purpose_color("Commercial") != main.map_view._purpose_color("Social"), "trip types must have distinct map colors")
	var total_chart_value: float = main.flow_timeline._hourly_values("All")[20]
	var combined_value: float = main.flow_profile.get_hourly_total(20, "Work") + main.flow_profile.get_hourly_total(20, "Commercial") + main.flow_profile.get_hourly_total(20, "Social")
	_check(main.flow_timeline.selected_purpose == "All" and absf(total_chart_value - combined_value) < 0.01, "All chart must combine all three trip purposes")
	for neighborhood in main.region.neighborhoods:
		main.map_view.neighborhood_selected.emit(neighborhood.id)
		_check(main.inspector.text.contains(neighborhood.name), "selection must update the inspector for %s" % neighborhood.name)
		_check(main.inspector.autowrap_mode == TextServer.AUTOWRAP_OFF, "inspector stats must keep fixed line breaks")
		for line in main.inspector.get_parsed_text().split("\n"):
			var font_size := 22 if line == neighborhood.name else 14
			var line_width: float = main.inspector.get_theme_default_font().get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			_check(line_width + 18.0 <= main.inspector.size.x, "inspector line must fit without clipping: %s" % line)
	_check(main.flow_detail_label.autowrap_mode == TextServer.AUTOWRAP_OFF, "flow summary must keep fixed line breaks")
	for line in main.flow_detail_label.text.split("\n"):
		var line_width: float = main.flow_detail_label.get_theme_default_font().get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		_check(line_width + 18.0 <= main.flow_detail_label.size.x, "flow summary line must fit without clipping: %s" % line)
	var inspector_scroll: VScrollBar = main.inspector.get_v_scroll_bar()
	_check(inspector_scroll.max_value > inspector_scroll.page, "minimum window size must keep inspector stats scrollable")
	inspector_scroll.value = maxf(0.0, (inspector_scroll.max_value - inspector_scroll.page) * 0.5)
	var previous_scroll: float = inspector_scroll.value
	main._on_neighborhood_selected(main.map_view.selected_id, false)
	_check(is_equal_approx(inspector_scroll.value, previous_scroll), "daily stat refresh must keep the inspector scroll position")
	main.flow_timeline.time_selected.emit(17, 30)
	_check(main.calendar_clock.get_hour() == 17 and main.calendar_clock.get_minute() == 30 and not main.playing, "chart scrubbing must set the minute and pause playback")
	var half_hour_x: float = main.flow_timeline.LEFT_MARGIN + 17.5 * (main.flow_timeline.size.x - main.flow_timeline.LEFT_MARGIN - main.flow_timeline.RIGHT_MARGIN) / 24.0
	_check(main.flow_timeline._time_at(half_hour_x) == Vector2i(17, 30), "chart position must map to the corresponding minute")
	main._on_speed_selected(2)
	_check(is_equal_approx(main.speed_multiplier, 16.0), "16× speed must advance sixteen hours per second")
	var before_day: int = main.last_dynamics_day_key
	var before_population: int = main.region.get_region_totals()["population"]
	_send_key(main, KEY_4)
	_check(is_equal_approx(main.speed_multiplier, 64.0) and main.speed_selector.get_item_text(3) == "64×", "4 must expose 64× speed in the selector")
	main._on_play_pressed()
	main._process(0.125)
	_check(main.calendar_clock.get_hour() == 1 and main.calendar_clock.get_minute() == 30 and main.last_dynamics_day_key == before_day + 1, "64× speed must advance eight simulated hours and process midnight")
	main._on_play_pressed()
	_send_key(main, KEY_5)
	_check(is_equal_approx(main.speed_multiplier, 256.0) and main.speed_selector.get_item_text(4) == "256×" and not main.playing, "5 must expose 256× speed without resuming")
	main._on_play_pressed()
	main._process(0.125)
	_check(main.calendar_clock.get_hour() == 9 and main.calendar_clock.get_minute() == 30, "256× speed must advance 32 simulated hours in one eighth of a second")
	_check(main.last_dynamics_day_key == before_day + 2 and main.region.get_region_totals()["population"] != before_population, "higher speeds must apply daily migration across each midnight")
	main.seed_input.value = 1730
	main._on_generate_pressed()
	_check(main.region.generation_seed == 1730, "Generate must use the entered seed")
	_check(main.map_view.selected_id == 0, "regeneration must select the first neighborhood")
	if failures == 0:
		print("UI smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)


func _send_key(main, keycode: Key, repeated: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.echo = repeated
	main._input(event)
