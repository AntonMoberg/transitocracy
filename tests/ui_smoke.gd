extends SceneTree

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	main._on_play_pressed()
	await process_frame
	_check(main.map_view.size.x > 0 and main.map_view.size.y > 0, "map must have visible layout size")
	_check(main.flow_timeline.size.x > 0 and main.flow_timeline.size.y > 0, "hour chart must have visible layout size")
	_check(main.region.neighborhoods.size() == 12, "main scene must generate twelve neighborhoods")
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
	_send_key(main, KEY_3)
	_send_key(main, KEY_SPACE)
	_check(is_equal_approx(main.speed_multiplier, 1.0) and main.playing, "shortcuts must not interfere with seed entry")
	main.seed_input.get_line_edit().release_focus()
	main.calendar_clock.set_time(23, 30)
	main._sync_clock_view()
	var tomorrow_profile = main.next_day_profile
	main._process(0.5)
	_check(main.calendar_clock.get_hour() == 0 and main.calendar_clock.get_minute() == 0 and main.flow_profile == tomorrow_profile, "continuous clock must switch to tomorrow's flow profile at midnight")
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
	main.flow_timeline.time_selected.emit(17, 30)
	_check(main.calendar_clock.get_hour() == 17 and main.calendar_clock.get_minute() == 30 and not main.playing, "chart scrubbing must set the minute and pause playback")
	var half_hour_x: float = main.flow_timeline.LEFT_MARGIN + 17.5 * (main.flow_timeline.size.x - main.flow_timeline.LEFT_MARGIN - main.flow_timeline.RIGHT_MARGIN) / 24.0
	_check(main.flow_timeline._time_at(half_hour_x) == Vector2i(17, 30), "chart position must map to the corresponding minute")
	main._on_speed_selected(2)
	_check(is_equal_approx(main.speed_multiplier, 16.0), "16× speed must advance sixteen hours per second")
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
