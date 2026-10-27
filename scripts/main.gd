extends Control

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const RegionData = preload("res://scripts/simulation/region_data.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
const FlowTimeline = preload("res://scripts/ui/flow_timeline.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadPreviewJob = preload("res://scripts/simulation/road_preview_job.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const MultiScaleWeekBuffer = preload("res://scripts/simulation/multiscale_week_buffer.gd")
const CompactHourPrecompute = preload("res://scripts/simulation/compact_hour_precompute.gd")
const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadRebuild = preload("res://scripts/simulation/road_rebuild.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const DevelopmentBudget = preload("res://scripts/simulation/development_budget.gd")
const DevelopmentControls = preload("res://scripts/ui/development_controls.gd")
const RoadTrafficSummary = preload("res://scripts/simulation/road_traffic_summary.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const ANIMATED_MAP_REDRAW_INTERVAL_MS = 150


var region
var flow_profile
var next_day_profile
var traffic_profile
var traffic_state
var inspected_hour: int = -1
var inspected_minute: int = 0
var pending_day_thread: Thread
var week_thread: Thread
var week_buffer
var compact_hour_thread: Thread
var compact_hour_buffer
var compact_hour_prepared_count: int = 0
var active_snapshot_buffers: Array = []
var deferred_region_edits: Array[Callable] = []
var deferred_mode_index: int = -1
var pending_day_key: int = -1
var pending_day_source_mode: int = -1
var pending_day_result: Dictionary = {}
var pending_day_result_key: int = -1
var retired_day_threads: Array[Thread] = []
var retired_data_threads: Array[Thread] = []
var retired_data_backlog: Array[Dictionary] = []
var day_worker_retry_at_msec: int = 0
var last_dynamics_day_key: int = -1
var week_timeline_start_key: int = -1
var week_timeline_history: Dictionary = {}
var flow_purpose: String = FlowProfile.ALL
var calendar_clock
var playing: bool = true
var speed_multiplier: float = 60.0 / 3600.0
var simulation_mode: int = MultiScaleTraffic.MINUTE
var pace_index: int = 0
var simulation_credit: float = 0.0
var real_rate_seconds: float = 0.0
var game_rate_seconds: float = 0.0
var measured_rate: float = 0.0
var map_view
var flow_timeline
var seed_input: SpinBox
var seed_generate_button: Button
var generation_rng := RandomNumberGenerator.new()
var map_size_selector: OptionButton
var generate_button: Button
var generation_thread: Thread
var road_rebuild_thread: Thread
var last_road_rebuild_publish_us:int=0
var last_road_rebuild_stages_us:Dictionary={}
var discard_road_rebuild: bool = false
var summary_label: Label
var dynamics_label: Label
var tax_input: SpinBox
var state_tax_controls: HBoxContainer
var jurisdiction_policy_controls: HBoxContainer
var selected_jurisdiction_id: int = 0
var policy_selector: OptionButton
var policy_input: SpinBox
var fiscal_label: Label
var scope_breadcrumb: RichTextLabel
var policy_options: Array[Dictionary] = []
var suppress_policy_input: bool = false
var calendar_label: Label
var hourly_trip_label: Label
var flow_detail_label: Label
var flow_detail_separator: HSeparator
var play_button: Button
var dev_mode_button: Button
var dev_mode_enabled: bool = false
var speed_selector: OptionButton
var mode_selector: OptionButton
var rate_label: Label
var purpose_selector: OptionButton
var inspector: RichTextLabel
var map_mode_selector: OptionButton
var growth_policy_controls: VBoxContainer
var urban_policy_inputs: Dictionary = {}
var suppress_urban_policy_input: bool = false
var review_queue: ItemList
var review_queue_label: Label
var review_queue_keys: Array[String] = []
var review_approve_button: Button
var road_tool_selector: OptionButton
var road_draw_selector: OptionButton
var road_snap_toggle: CheckBox
var road_length_snap_toggle: CheckBox
var crossing_selector: OptionButton
var crossing_level_selector: OptionButton
var crossing_controls: HBoxContainer
var road_impact_label: Label
var road_build_button: Button
var road_cancel_button: Button
var zoning_tool_message: String = "Amber dots mark suggested districts. Zoom in and click one to review and approve it."
var toll_forward_input: SpinBox
var toll_reverse_input: SpinBox
var toll_label: Label
var toll_controls: HBoxContainer
var suppress_toll_input: bool = false
var road_status_label: Label
var pending_road_preview: Dictionary = {}
var road_start_node: int = -1
var road_start_position := Vector2.INF
var road_preview_thread: Thread
var road_preview_job
var road_preview_serial := 0
var road_preview_request: Dictionary = {}
var planning_start_point: Vector2 = Vector2.ZERO
var planning_has_start: bool = false
var road_waypoints: PackedVector2Array = PackedVector2Array()
var road_last_guide_click: bool = false
var road_last_click_position: Vector2 = Vector2.ZERO
var selected_road_link_id: int = -1
var selected_candidate_id: int = -1
var selected_candidate_key: String = ""
var zoning_controls: HBoxContainer
var zoning_button: Button
var zoning_status_label: Label
var development_controls
var last_process_us: int = 0
var last_handoff_us: int = 0
var last_advance_us: int = 0
var last_sync_us: int = 0
var last_handoff_breakdown: Dictionary = {}
var pending_inspector_refresh: bool = false
var last_live_road_redraw_msec: int = -ANIMATED_MAP_REDRAW_INTERVAL_MS
var last_trip_redraw_msec: int = -ANIMATED_MAP_REDRAW_INTERVAL_MS
var trip_redraw_pending: bool = false


func _ready() -> void:
	get_window().min_size = Vector2i(1024, 700)
	generation_rng.randomize()
	_build_interface()
	_on_generate_pressed()


func _exit_tree() -> void:
	if road_preview_thread != null: road_preview_thread.wait_to_finish()
	if generation_thread != null:
		generation_thread.wait_to_finish()
	if road_rebuild_thread != null:
		road_rebuild_thread.wait_to_finish()
	_discard_pending_day()
	for worker in retired_day_threads:
		worker.wait_to_finish()
	retired_day_threads.clear()
	for worker in retired_data_threads:
		worker.wait_to_finish()
	retired_data_threads.clear()


func _process(delta: float) -> void:
	var process_started: int = Time.get_ticks_usec()
	_poll_generation()
	_poll_road_rebuild()
	_poll_road_preview()
	_reap_finished_day_threads()
	_reap_finished_data_threads()
	_poll_day_worker()
	_poll_compact_hour_worker()
	if pending_inspector_refresh:
		pending_inspector_refresh = false
		_refresh_inspector(false)
	if simulation_mode == MultiScaleTraffic.DAY and traffic_state != null:
		_ensure_week_worker()
		_poll_week_worker()
	if _region_snapshot_busy():
		return
	if deferred_mode_index >= 0:
		var requested_mode: int = deferred_mode_index
		deferred_mode_index = -1
		_on_mode_selected(requested_mode)
	if not deferred_region_edits.is_empty():
		var edits: Array[Callable] = deferred_region_edits.duplicate()
		deferred_region_edits.clear()
		for edit in edits:
			edit.call()
	if _region_snapshot_busy():
		return
	var handoff_started: int = Time.get_ticks_usec()
	_ensure_day_profiles()
	last_handoff_us = Time.get_ticks_usec() - handoff_started
	_ensure_compact_hour_worker()
	if not playing or calendar_clock == null or traffic_state == null:
		return
	var target_rate: float = [1.0, 60.0, 3600.0, 86400.0][simulation_mode] * [1.0, 2.0, 4.0][pace_index]
	var effective_rate: float = _effective_day_rate(target_rate) if simulation_mode == MultiScaleTraffic.DAY else target_rate
	speed_multiplier = target_rate / 3600.0
	var compact_day: bool = simulation_mode == MultiScaleTraffic.DAY and region.is_large_scale
	var compact_hour: bool = simulation_mode == MultiScaleTraffic.HOUR and region.is_large_scale
	simulation_credit = minf(simulation_credit + delta * effective_rate, maxf(86400.0 if compact_day else (3600.0 if compact_hour else 1.0), effective_rate * 0.25))
	var game_start: int = traffic_state.unix_seconds
	var advance_started: int = Time.get_ticks_usec()
	var budget_end: int = Time.get_ticks_usec() + 2500
	while simulation_credit >= 1.0 and Time.get_ticks_usec() < budget_end:
		var day_end: int = (traffic_state.day_key + 1) * 86400
		if traffic_state.unix_seconds >= day_end:
			_queue_next_day(traffic_state.day_key)
			break
		if compact_day and simulation_credit < float(day_end - traffic_state.unix_seconds):
			break
		if compact_day and week_buffer != null and pending_day_result_key != traffic_state.day_key + 1:
			# Keep the display at the day edge until the worker publishes the
			# prepared snapshot instead of doing a costly fallback on this frame.
			break
		if compact_hour and simulation_credit < float(mini(day_end, (traffic_state.unix_seconds / 3600 + 1) * 3600) - traffic_state.unix_seconds):
			break
		var quantum: int = 1 if simulation_mode == MultiScaleTraffic.SECOND else (60 if simulation_mode == MultiScaleTraffic.MINUTE else (86400 if compact_day else 3600))
		var duration: int = mini(floori(simulation_credit), mini(quantum, day_end - traffic_state.unix_seconds))
		if duration <= 0:
			break
		if compact_day and pending_day_result_key == traffic_state.day_key + 1:
			# The week worker has already simulated this entire day to produce the
			# next snapshot. Avoid repeating the same traffic work on the UI thread.
			traffic_state.unix_seconds = day_end
		else:
			var pending_policies_before: int = region.pending_policy_changes.size()
			MultiScaleTraffic.advance(region, flow_profile, traffic_state, traffic_state.unix_seconds + duration, simulation_mode)
			if region.pending_policy_changes.size() != pending_policies_before:
				_refresh_fiscal_controls()
				_refresh_inspector(false)
		simulation_credit -= duration
		calendar_clock.unix_seconds = traffic_state.unix_seconds
		if traffic_state.unix_seconds >= day_end:
			_queue_next_day(traffic_state.day_key)
			break
	if compact_day and pending_day_result_key == traffic_state.day_key + 1 and traffic_state.unix_seconds >= (traffic_state.day_key + 1) * 86400:
		# Carry any fractional-day credit into the prepared day in this frame.
		# Waiting for the next frame would visibly jump past midnight.
		_ensure_day_profiles()
	calendar_clock.fractional_second = minf(0.999, simulation_credit) if simulation_mode == MultiScaleTraffic.SECOND else 0.0
	if compact_hour or compact_day:
		var seconds_until_day_end: float = float((traffic_state.day_key + 1) * 86400 - traffic_state.unix_seconds)
		var display_window: float = seconds_until_day_end
		if compact_hour:
			var seconds_until_hour_end: float = float((traffic_state.unix_seconds / 3600 + 1) * 3600 - traffic_state.unix_seconds)
			display_window = minf(display_window, seconds_until_hour_end)
		calendar_clock.visual_offset_seconds = minf(simulation_credit, maxf(0.0, display_window - 0.001))
	else:
		calendar_clock.visual_offset_seconds = 0.0
	last_advance_us = Time.get_ticks_usec() - advance_started
	game_rate_seconds += traffic_state.unix_seconds - game_start
	if traffic_state.unix_seconds != game_start and map_view.show_traffic_overlay and map_view.road_traffic_mode == RegionMap.ROAD_LIVE:
		var now_msec: int = Time.get_ticks_msec()
		if now_msec - last_live_road_redraw_msec >= ANIMATED_MAP_REDRAW_INTERVAL_MS:
			map_view.queue_redraw()
			last_live_road_redraw_msec = now_msec
	real_rate_seconds += delta
	if real_rate_seconds >= 1.0:
		measured_rate = game_rate_seconds / real_rate_seconds
		rate_label.text = "Actual %s/s%s" % [_format_sim_duration(measured_rate), "  •  capped" if measured_rate < target_rate * 0.9 else ""]
		real_rate_seconds = 0.0
		game_rate_seconds = 0.0
	inspected_hour = -1
	var sync_started: int = Time.get_ticks_usec()
	_sync_clock_view()
	last_sync_us = Time.get_ticks_usec() - sync_started
	last_process_us = Time.get_ticks_usec() - process_started


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.ctrl_pressed or key_event.alt_pressed or key_event.meta_pressed:
		return
	var focused_control := get_viewport().gui_get_focus_owner()
	if focused_control is LineEdit or focused_control is TextEdit:
		return
	match key_event.keycode:
		KEY_SPACE:
			_on_play_pressed()
		KEY_1, KEY_KP_1:
			_on_mode_selected(0)
		KEY_2, KEY_KP_2:
			_on_mode_selected(1)
		KEY_3, KEY_KP_3:
			_on_mode_selected(2)
		KEY_4, KEY_KP_4:
			_on_mode_selected(3)
		KEY_Q:
			_on_speed_selected(0)
		KEY_W:
			_on_speed_selected(1)
		KEY_E:
			_on_speed_selected(2)
		KEY_ESCAPE:
			_cancel_road_preview()
		_:
			return
	get_viewport().set_input_as_handled()


func _build_interface() -> void:
	var background := ColorRect.new()
	background.color = Color("0b1421")
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	layout.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	var title := Label.new()
	title.text = "TRANSITOCRACY"
	title.add_theme_font_size_override("font_size", 27)
	title.add_theme_color_override("font_color", Color("e8f1f7"))
	titles.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Regional trip flow prototype"
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color("8ea4b8"))
	titles.add_child(subtitle)

	var seed_label := Label.new()
	seed_label.text = "Seed"
	seed_label.add_theme_color_override("font_color", Color("b8c9d6"))
	header.add_child(seed_label)
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 9999999
	seed_input.step = 1
	seed_input.rounded = true
	seed_input.value = 1
	seed_input.tooltip_text = "Reuse this seed with From seed to recreate a map"
	seed_input.custom_minimum_size = Vector2(116, 0)
	header.add_child(seed_input)
	var map_size_label := Label.new()
	map_size_label.text = "Detail"
	map_size_label.add_theme_color_override("font_color", Color("b8c9d6"))
	header.add_child(map_size_label)
	map_size_selector = OptionButton.new()
	map_size_selector.add_item("32 cities", 32)
	map_size_selector.add_item("256 cities", 256)
	map_size_selector.add_item("768 cities", 768)
	map_size_selector.select(1)
	map_size_selector.tooltip_text = "City detail within the same California-sized state"
	header.add_child(map_size_selector)
	generate_button = Button.new()
	generate_button.text = "New map"
	generate_button.tooltip_text = "Generate a new random state"
	generate_button.pressed.connect(_on_generate_pressed)
	header.add_child(generate_button)
	seed_generate_button = Button.new()
	seed_generate_button.text = "From seed"
	seed_generate_button.tooltip_text = "Generate the state described by the displayed seed"
	seed_generate_button.pressed.connect(func() -> void: _generate_region(int(seed_input.value)))
	header.add_child(seed_generate_button)
	var quit_button := Button.new()
	quit_button.text = "Quit"
	quit_button.tooltip_text = "Close Transitocracy"
	quit_button.pressed.connect(_on_quit_pressed)
	header.add_child(quit_button)

	summary_label = Label.new()
	summary_label.add_theme_font_size_override("font_size", 14)
	summary_label.add_theme_color_override("font_color", Color("b5cad9"))
	layout.add_child(summary_label)
	dynamics_label = Label.new()
	dynamics_label.add_theme_color_override("font_color", Color("93b9ac"))
	layout.add_child(dynamics_label)

	var clock_controls := HBoxContainer.new()
	clock_controls.add_theme_constant_override("separation", 12)
	layout.add_child(clock_controls)
	play_button = Button.new()
	play_button.text = "Pause"
	play_button.tooltip_text = "Space: play or pause"
	play_button.pressed.connect(_on_play_pressed)
	clock_controls.add_child(play_button)
	dev_mode_button = Button.new()
	dev_mode_button.text = "Dev Mode: Off"
	dev_mode_button.toggle_mode = true
	dev_mode_button.tooltip_text = "Use unlimited funds for road projects and neighborhood development."
	dev_mode_button.toggled.connect(_on_dev_mode_toggled)
	clock_controls.add_child(dev_mode_button)
	mode_selector = OptionButton.new()
	for label in ["Second", "Minute", "Hour", "Day"]:
		mode_selector.add_item(label)
	mode_selector.selected = MultiScaleTraffic.MINUTE
	mode_selector.tooltip_text = "1 / 2 / 3 / 4: choose simulation detail and base clock rate"
	mode_selector.item_selected.connect(_on_mode_selected)
	clock_controls.add_child(mode_selector)
	speed_selector = OptionButton.new()
	for label in ["Normal", "Faster 2×", "Fastest 4×"]:
		speed_selector.add_item(label)
	speed_selector.selected = 0
	speed_selector.tooltip_text = "Q / W / E: choose playback pace"
	speed_selector.item_selected.connect(_on_speed_selected)
	clock_controls.add_child(speed_selector)
	rate_label = Label.new()
	rate_label.text = "Actual --"
	rate_label.custom_minimum_size.x = 120
	clock_controls.add_child(rate_label)
	purpose_selector = OptionButton.new()
	purpose_selector.add_item("All")
	purpose_selector.add_item("Work")
	purpose_selector.add_item("Commercial")
	purpose_selector.add_item("Social")
	purpose_selector.selected = 0
	purpose_selector.tooltip_text = "Filter the map and chart by trip purpose"
	purpose_selector.item_selected.connect(_on_purpose_selected)
	clock_controls.add_child(purpose_selector)
	calendar_label = Label.new()
	calendar_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	calendar_label.add_theme_font_size_override("font_size", 17)
	calendar_label.add_theme_color_override("font_color", Color("e8f1f7"))
	clock_controls.add_child(calendar_label)
	hourly_trip_label = Label.new()
	hourly_trip_label.add_theme_color_override("font_color", Color("f5b67c"))
	clock_controls.add_child(hourly_trip_label)

	var road_controls := HBoxContainer.new()
	road_controls.add_theme_constant_override("separation", 8)
	layout.add_child(road_controls)
	map_mode_selector = OptionButton.new()
	map_mode_selector.add_item("Roads")
	map_mode_selector.add_item("Trips")
	map_mode_selector.add_item("Zoning")
	map_mode_selector.selected = 0
	map_mode_selector.item_selected.connect(_on_map_mode_selected)
	road_controls.add_child(map_mode_selector)
	road_tool_selector = OptionButton.new()
	for tool_name in ["Inspect", "Arterial", "Highway", "Growth corridor", "Rail corridor", "Station site", "Junction", "Interchange", "Widen", "Demolish"]:
		road_tool_selector.add_item(tool_name)
	road_tool_selector.item_selected.connect(_on_road_tool_selected)
	road_controls.add_child(road_tool_selector)
	road_draw_selector = OptionButton.new()
	for mode_name in [RoadRouteBuilder.STRAIGHT, RoadRouteBuilder.CURVED, RoadRouteBuilder.MULTIPOINT]:
		road_draw_selector.add_item(mode_name)
	road_draw_selector.item_selected.connect(_on_road_draw_selected)
	road_draw_selector.visible = false
	road_controls.add_child(road_draw_selector)
	road_snap_toggle = CheckBox.new()
	road_snap_toggle.text = "Snap 5°"
	road_snap_toggle.toggled.connect(_on_road_snap_toggled)
	road_snap_toggle.visible = false
	road_controls.add_child(road_snap_toggle)
	road_length_snap_toggle = CheckBox.new()
	road_length_snap_toggle.text = "Snap 5 m"
	road_length_snap_toggle.tooltip_text = "Snap the distance from the previous road point to 5 m steps"
	road_length_snap_toggle.toggled.connect(_on_road_length_snap_toggled)
	road_length_snap_toggle.visible = false
	road_controls.add_child(road_length_snap_toggle)
	road_build_button = Button.new()
	road_build_button.text = "Build"
	road_build_button.disabled = true
	road_build_button.pressed.connect(_on_road_build_pressed)
	road_controls.add_child(road_build_button)
	road_cancel_button = Button.new()
	road_cancel_button.text = "Cancel"
	road_cancel_button.pressed.connect(_cancel_road_preview)
	road_controls.add_child(road_cancel_button)
	road_status_label = Label.new()
	road_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	road_status_label.clip_text = true
	road_status_label.add_theme_color_override("font_color", Color("a9c8d8"))
	road_controls.add_child(road_status_label)
	crossing_controls = HBoxContainer.new()
	crossing_controls.visible = false
	layout.add_child(crossing_controls)
	var crossing_label := Label.new()
	crossing_label.text = "Highway crossing"
	crossing_controls.add_child(crossing_label)
	crossing_selector = OptionButton.new()
	crossing_selector.item_selected.connect(_on_crossing_selected)
	crossing_controls.add_child(crossing_selector)
	crossing_level_selector = OptionButton.new()
	crossing_level_selector.add_item("Above")
	crossing_level_selector.add_item("Below")
	crossing_level_selector.item_selected.connect(_on_crossing_level_selected)
	crossing_controls.add_child(crossing_level_selector)
	road_impact_label = Label.new()
	road_impact_label.clip_text = true
	road_impact_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crossing_controls.add_child(road_impact_label)
	toll_controls = HBoxContainer.new()
	toll_controls.add_theme_constant_override("separation", 8)
	layout.add_child(toll_controls)
	toll_controls.visible = false
	toll_label = Label.new()
	toll_label.text = "Select a road to set directional tolls"
	toll_label.custom_minimum_size.x = 260
	toll_controls.add_child(toll_label)
	var forward_label := Label.new()
	forward_label.text = "Forward toll"
	toll_controls.add_child(forward_label)
	toll_forward_input = SpinBox.new()
	toll_forward_input.min_value = 0
	toll_forward_input.max_value = 50
	toll_forward_input.step = 0.25
	toll_forward_input.suffix = "$"
	toll_forward_input.editable = false
	toll_forward_input.value_changed.connect(func(value: float) -> void: _on_toll_changed("toll_forward", value))
	toll_controls.add_child(toll_forward_input)
	var reverse_label := Label.new()
	reverse_label.text = "Reverse toll"
	toll_controls.add_child(reverse_label)
	toll_reverse_input = SpinBox.new()
	toll_reverse_input.min_value = 0
	toll_reverse_input.max_value = 50
	toll_reverse_input.step = 0.25
	toll_reverse_input.suffix = "$"
	toll_reverse_input.editable = false
	toll_reverse_input.value_changed.connect(func(value: float) -> void: _on_toll_changed("toll_reverse", value))
	toll_controls.add_child(toll_reverse_input)

	var timeline_panel := PanelContainer.new()
	timeline_panel.add_theme_stylebox_override("panel", _panel_style(Color("152235"), 0))
	layout.add_child(timeline_panel)
	flow_timeline = FlowTimeline.new()
	flow_timeline.time_selected.connect(_on_time_selected)
	timeline_panel.add_child(flow_timeline)

	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	layout.add_child(content)

	var map_panel := PanelContainer.new()
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_panel.add_theme_stylebox_override("panel", _panel_style(Color("101b2b"), 0))
	content.add_child(map_panel)
	map_view = RegionMap.new()
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_view.neighborhood_selected.connect(_on_neighborhood_selected)
	map_view.candidate_selected.connect(_on_candidate_selected)
	map_view.local_street_selected.connect(_on_local_street_selected)
	map_view.jurisdiction_selected.connect(_on_map_jurisdiction_selected)
	map_view.road_node_clicked.connect(_on_road_node_clicked)
	map_view.road_link_clicked.connect(_on_road_link_clicked)
	map_view.road_empty_clicked.connect(_on_road_empty_clicked)
	map_view.road_empty_double_clicked.connect(_on_road_empty_double_clicked)
	map_view.road_cancel_requested.connect(_cancel_road_preview)
	map_panel.add_child(map_view)

	var inspector_panel := PanelContainer.new()
	inspector_panel.custom_minimum_size = Vector2(340, 0)
	inspector_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_panel.add_theme_stylebox_override("panel", _panel_style(Color("152235"), 16))
	content.add_child(inspector_panel)
	var inspector_layout := VBoxContainer.new()
	inspector_layout.add_theme_constant_override("separation", 8)
	inspector_panel.add_child(inspector_layout)
	var inspector_controls_scroll := ScrollContainer.new()
	inspector_controls_scroll.custom_minimum_size.y = 200
	inspector_controls_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_controls_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector_layout.add_child(inspector_controls_scroll)
	var inspector_controls := VBoxContainer.new()
	inspector_controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_controls.add_theme_constant_override("separation", 8)
	inspector_controls_scroll.add_child(inspector_controls)
	flow_detail_label = Label.new()
	flow_detail_label.add_theme_font_size_override("font_size", 14)
	flow_detail_label.add_theme_color_override("font_color", Color("f5b67c"))
	flow_detail_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	flow_detail_label.custom_minimum_size.y = 58
	inspector_controls.add_child(flow_detail_label)
	flow_detail_separator = HSeparator.new()
	inspector_controls.add_child(flow_detail_separator)
	flow_detail_label.visible = false
	flow_detail_separator.visible = false
	scope_breadcrumb = RichTextLabel.new()
	scope_breadcrumb.bbcode_enabled = true
	scope_breadcrumb.scroll_active = false
	scope_breadcrumb.custom_minimum_size.y = 44
	scope_breadcrumb.meta_clicked.connect(_on_inspector_meta_clicked)
	inspector_controls.add_child(scope_breadcrumb)
	fiscal_label = Label.new()
	fiscal_label.clip_text = true
	fiscal_label.add_theme_color_override("font_color", Color("93b9ac"))
	inspector_controls.add_child(fiscal_label)
	zoning_controls = HBoxContainer.new()
	zoning_controls.visible = false
	inspector_controls.add_child(zoning_controls)
	zoning_button = Button.new()
	zoning_button.pressed.connect(_on_zoning_pressed)
	zoning_controls.add_child(zoning_button)
	zoning_status_label = Label.new()
	zoning_status_label.clip_text = true
	zoning_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoning_controls.add_child(zoning_status_label)
	development_controls = DevelopmentControls.new()
	development_controls.visible = false
	development_controls.allocation_requested.connect(_on_development_allocation)
	development_controls.zoning_requested.connect(_on_development_zoning)
	development_controls.design_requested.connect(_on_development_design)
	development_controls.character_requested.connect(_on_development_character)
	inspector_controls.add_child(development_controls)
	zoning_controls.visibility_changed.connect(func() -> void: development_controls.visible = zoning_controls.visible)
	review_queue_label = Label.new()
	review_queue_label.text = "GROWTH REVIEW · select several to approve"
	review_queue_label.visible = false
	inspector_controls.add_child(review_queue_label)
	review_queue = ItemList.new()
	review_queue.select_mode = ItemList.SELECT_MULTI
	review_queue.custom_minimum_size.y = 112
	review_queue.visible = false
	review_queue.item_activated.connect(func(index: int) -> void:
		if index >= 0 and index < review_queue_keys.size() and region != null:
			var candidate_id: int = int(region.development_candidate_keys.get(review_queue_keys[index], -1))
			if candidate_id >= 0:
				_on_candidate_selected(candidate_id))
	inspector_controls.add_child(review_queue)
	review_approve_button = Button.new()
	review_approve_button.text = "Approve selected projects"
	review_approve_button.visible = false
	review_approve_button.pressed.connect(_approve_review_selection)
	inspector_controls.add_child(review_approve_button)
	growth_policy_controls = VBoxContainer.new()
	growth_policy_controls.visible = false
	inspector_controls.add_child(growth_policy_controls)
	for field in ["growth_focus", "block_design", "land_use_focus", "density"]:
		var row := HBoxContainer.new()
		growth_policy_controls.add_child(row)
		var label := Label.new()
		label.text = {"growth_focus": "Growth", "block_design": "Blocks", "land_use_focus": "Land use", "density": "Density"}[field]
		label.custom_minimum_size.x = 72
		row.add_child(label)
		var input := OptionButton.new()
		for option in {
			"growth_focus": ["Balanced", "Near center", "Road corridors"],
			"block_design": ["Fine grid", "Long across", "Long along"],
			"land_use_focus": ["Local mix", "Homes", "Jobs", "Mixed use"],
			"density": ["Low", "Medium", "High"],
		}[field]:
			input.add_item(option)
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input.item_selected.connect(_on_urban_policy_selected.bind(field))
		row.add_child(input)
		urban_policy_inputs[field] = input
	state_tax_controls = HBoxContainer.new()
	state_tax_controls.add_theme_constant_override("separation", 8)
	inspector_controls.add_child(state_tax_controls)
	var tax_label := Label.new()
	tax_label.text = "State income tax"
	state_tax_controls.add_child(tax_label)
	tax_input = SpinBox.new()
	tax_input.min_value = 0
	tax_input.max_value = 40
	tax_input.step = 1
	tax_input.suffix = "%"
	tax_input.value = 10
	tax_input.custom_minimum_size.x = 94
	tax_input.tooltip_text = "Changes at the next midnight"
	tax_input.value_changed.connect(_on_tax_changed)
	state_tax_controls.add_child(tax_input)
	jurisdiction_policy_controls = HBoxContainer.new()
	jurisdiction_policy_controls.add_theme_constant_override("separation", 8)
	inspector_controls.add_child(jurisdiction_policy_controls)
	policy_selector = OptionButton.new()
	policy_selector.custom_minimum_size.x = 175
	policy_selector.item_selected.connect(_on_policy_selected)
	jurisdiction_policy_controls.add_child(policy_selector)
	policy_input = SpinBox.new()
	policy_input.custom_minimum_size.x = 105
	policy_input.value_changed.connect(_on_policy_changed)
	jurisdiction_policy_controls.add_child(policy_input)
	inspector_layout.add_child(HSeparator.new())
	inspector = RichTextLabel.new()
	inspector.bbcode_enabled = true
	inspector.selection_enabled = true
	inspector.meta_clicked.connect(_on_inspector_meta_clicked)
	inspector.autowrap_mode = TextServer.AUTOWRAP_OFF
	inspector.custom_minimum_size.y = 90
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector.add_theme_font_size_override("normal_font_size", 14)
	inspector_layout.add_child(inspector)


func _panel_style(color: Color, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(12)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


func _on_generate_pressed() -> void:
	if generation_thread != null:
		return
	var seed_value: int = generation_rng.randi_range(1, int(seed_input.max_value))
	while seed_value == int(seed_input.value) or (region != null and seed_value == region.generation_seed):
		seed_value = generation_rng.randi_range(1, int(seed_input.max_value))
	_generate_region(seed_value)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_play_pressed() -> void:
	playing = not playing
	if playing:
		inspected_hour = -1
	elif map_view != null and map_view.map_mode in ["Roads", "Trips"]:
		map_view.queue_redraw()
		trip_redraw_pending = false
	play_button.text = "Pause" if playing else "Play"


func _on_dev_mode_toggled(enabled: bool) -> void:
	dev_mode_enabled = enabled
	dev_mode_button.text = "Dev Mode: On" if enabled else "Dev Mode: Off"
	if region == null:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_apply_dev_mode"))
		return
	_apply_dev_mode()


func _apply_dev_mode() -> void:
	_discard_pending_day()
	region.dev_mode = dev_mode_enabled
	_refresh_region_summary()
	_update_road_status()
	_refresh_inspector(false)
	_queue_next_day(last_dynamics_day_key)


func _on_speed_selected(index: int) -> void:
	pace_index = clampi(index, 0, 2)
	if speed_selector.selected != pace_index:
		speed_selector.select(pace_index)
	speed_multiplier = [1.0, 60.0, 3600.0, 86400.0][simulation_mode] * [1.0, 2.0, 4.0][pace_index] / 3600.0


func _on_mode_selected(index: int) -> void:
	# A new district changes the neighborhood count immediately, while its
	# matching demand and traffic profiles arrive from the rebuild worker.
	if region != null and _region_snapshot_busy():
		deferred_mode_index = index
		mode_selector.select(simulation_mode)
		return
	if index < 0 or index > MultiScaleTraffic.DAY:
		return
	if index >= MultiScaleTraffic.HOUR and region != null and selected_jurisdiction_id >= 0:
		if region.jurisdictions[selected_jurisdiction_id].kind not in ["State", "Region"]:
			mode_selector.select(simulation_mode)
			return
	var old_mode: int = simulation_mode
	if old_mode != index:
		simulation_credit = 0.0
		if calendar_clock != null:
			calendar_clock.visual_offset_seconds = 0.0
	if old_mode != index and (old_mode == MultiScaleTraffic.DAY or index == MultiScaleTraffic.DAY):
		_discard_pending_day(false)
	elif old_mode == MultiScaleTraffic.HOUR and index != MultiScaleTraffic.HOUR:
		_discard_compact_hour_precompute()
	simulation_mode = index
	mode_selector.select(index)
	if old_mode != index:
		week_timeline_history.clear()
		week_timeline_start_key = traffic_state.day_key if index == MultiScaleTraffic.DAY and traffic_state != null else -1
	if region != null and traffic_state != null:
		if traffic_state.unix_seconds < (traffic_state.day_key + 1) * 86400:
			MultiScaleTraffic.change_mode(region, flow_profile, traffic_state, old_mode, index)
		map_view.set_detail_level("Neighborhood" if index <= MultiScaleTraffic.MINUTE else ("Region" if index == MultiScaleTraffic.HOUR else "State"))
		map_view.queue_redraw()
	_on_speed_selected(pace_index)
	if simulation_mode == MultiScaleTraffic.DAY and traffic_state != null:
		_ensure_week_worker()
	if traffic_state != null and traffic_state.unix_seconds >= (traffic_state.day_key + 1) * 86400:
		_queue_next_day(traffic_state.day_key)
		if old_mode == MultiScaleTraffic.DAY and simulation_mode <= MultiScaleTraffic.MINUTE:
			pending_day_source_mode = old_mode
	if calendar_clock != null:
		_sync_clock_view()


func _format_sim_duration(seconds: float) -> String:
	if seconds >= 86400.0:
		return "%.2f d" % (seconds / 86400.0)
	if seconds >= 3600.0:
		return "%.1f h" % (seconds / 3600.0)
	if seconds >= 60.0:
		return "%.1f min" % (seconds / 60.0)
	return "%.1f s" % seconds


func _on_purpose_selected(index: int) -> void:
	flow_purpose = [FlowProfile.ALL, FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL][index]
	map_view.set_purpose(flow_purpose)
	flow_timeline.set_purpose(flow_purpose)
	_update_flow_detail()


func _on_time_selected(hour: int, minute: int) -> void:
	inspected_hour = hour
	inspected_minute = minute
	playing = false
	play_button.text = "Play"
	_sync_clock_view()


func _on_tax_changed(value: float) -> void:
	if region == null:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_tax_changed").bind(value))
		return
	_discard_pending_day()
	FiscalCalculator.queue_policy(region, 0, "income_tax_rate", value / 100.0, calendar_clock.unix_seconds)
	_invalidate_traffic_forecast()
	_queue_next_day(last_dynamics_day_key)
	_refresh_fiscal_controls()
	_refresh_inspector(false)


func _on_jurisdiction_selected(area_id: int) -> void:
	if region == null or area_id < 0 or area_id >= region.jurisdictions.size():
		return
	map_view.selected_local_street = Vector2i(-1, -1)
	selected_candidate_id = -1
	selected_candidate_key = ""
	zoning_controls.visible = false
	map_view.set_selected_candidate(-1)
	selected_jurisdiction_id = area_id
	var area = region.jurisdictions[area_id]
	_refresh_growth_policy_controls()
	var local_scope: bool = area.kind not in ["State", "Region"]
	mode_selector.set_item_disabled(MultiScaleTraffic.HOUR, local_scope)
	mode_selector.set_item_disabled(MultiScaleTraffic.DAY, local_scope)
	if simulation_mode >= MultiScaleTraffic.HOUR and local_scope:
		_on_mode_selected(MultiScaleTraffic.MINUTE)
	_cancel_road_preview()
	selected_road_link_id = -1
	_refresh_toll_controls()
	map_view.set_selected_road_link(-1)
	map_view.set_selected_jurisdiction(area.id)
	map_view.set_selected(-1)
	policy_options.clear()
	policy_selector.clear()
	match area.kind:
		"County":
			policy_options = [
				{"label": "Income tax", "property": "income_tax_rate", "max": 30.0, "step": 0.5, "percent": true},
				{"label": "Property tax", "property": "property_tax_rate", "max": 2.0, "step": 0.1, "percent": true},
				{"label": "Sales tax", "property": "sales_tax_rate", "max": 15.0, "step": 0.5, "percent": true},
			]
		"City":
			policy_options = [
				{"label": "Parking fee", "property": "parking_fee", "max": 50.0, "step": 0.25, "percent": false},
				{"label": "Congestion fee", "property": "congestion_fee", "max": 50.0, "step": 0.25, "percent": false},
				{"label": "Charge starts", "property": "congestion_start_hour", "max": 23.0, "step": 1.0, "percent": false},
				{"label": "Charge ends", "property": "congestion_end_hour", "max": 23.0, "step": 1.0, "percent": false},
			]
		"Neighborhood":
			policy_options = [{"label": "Parking fee", "property": "parking_fee", "max": 50.0, "step": 0.25, "percent": false}]
	for option in policy_options:
		policy_selector.add_item(option["label"])
	state_tax_controls.visible = area.kind == "State"
	jurisdiction_policy_controls.visible = not policy_options.is_empty()
	_on_policy_selected(0)
	_refresh_fiscal_controls()
	_refresh_scope_breadcrumb()
	_update_flow_detail()
	if area.kind == "Neighborhood":
		_on_neighborhood_selected(area.neighborhood_ids[0])
	else:
		_show_jurisdiction_inspector()


func _on_policy_selected(index: int) -> void:
	if region == null or policy_options.is_empty():
		return
	var option: Dictionary = policy_options[index]
	var area = region.jurisdictions[selected_jurisdiction_id]
	suppress_policy_input = true
	policy_input.min_value = 0.0
	policy_input.max_value = option["max"]
	policy_input.step = option["step"]
	policy_input.suffix = "%" if option["percent"] else ("h" if str(option["property"]).contains("hour") else "$")
	policy_input.value = float(area.get(option["property"])) * (100.0 if option["percent"] else 1.0)
	suppress_policy_input = false


func _on_policy_changed(value: float) -> void:
	if suppress_policy_input or region == null or policy_options.is_empty():
		return
	var option: Dictionary = policy_options[policy_selector.selected]
	var policy_value: float = value / 100.0 if option["percent"] else value
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_apply_specific_policy").bind(selected_jurisdiction_id, option["property"], policy_value))
		return
	_apply_specific_policy(selected_jurisdiction_id, option["property"], policy_value)


func _apply_specific_policy(area_id: int, property_name: String, policy_value: float) -> void:
	_discard_pending_day()
	FiscalCalculator.queue_policy(region, area_id, property_name, policy_value, calendar_clock.unix_seconds)
	_invalidate_traffic_forecast()
	_queue_next_day(last_dynamics_day_key)
	_refresh_fiscal_controls()


func _refresh_fiscal_controls() -> void:
	if region == null or selected_jurisdiction_id < 0 or selected_jurisdiction_id >= region.jurisdictions.size():
		return
	var area = region.jurisdictions[selected_jurisdiction_id]
	var pending_text := ""
	for policy in region.pending_policy_changes:
		if int(policy.get("jurisdiction_id", -1)) == area.id:
			var effective: Dictionary = Time.get_datetime_dict_from_unix_time(int(policy["effective_seconds"]))
			pending_text = "  •  Next change %02d:%02d" % [effective["hour"], effective["minute"]]
	var balance: float = area.treasury
	var income: float = area.daily_income_revenue
	var property: float = area.daily_property_revenue
	var sales: float = area.daily_sales_revenue
	var fees: float = area.daily_fee_revenue
	var grants: float = area.daily_grant_revenue
	var transfers: float = area.daily_transfer_expense
	var upkeep: float = area.daily_road_upkeep
	var child_balance := 0.0
	if area.kind == "Region":
		var stack: Array = area.child_ids.duplicate()
		while not stack.is_empty():
			var child = region.jurisdictions[stack.pop_back()]
			child_balance += child.treasury
			stack.append_array(child.child_ids)
	var totals: Dictionary = region.get_jurisdiction_totals(area.id)
	var available_text: String = "∞" if region.dev_mode else _format_count(roundi(balance))
	fiscal_label.text = "%s  •  $%s available  •  $%s reserved  •  $%s/day net%s" % [area.name, available_text, _format_count(region.reserved_development_funds(area.id)), _format_count(roundi(income + property + sales + fees + grants - upkeep - transfers)), pending_text]
	fiscal_label.tooltip_text = "%s: %s people, %s jobs\nAvailable treasury $%s • Development reserves $%s\nIncome $%s/day  •  Property $%s/day\nSales $%s today  •  Fees $%s today\nState grants $%s/day  •  Transfers $%s/day\nRoad upkeep $%s/day" % [
		area.name, _format_count(totals["population"]), _format_count(totals["jobs"]), available_text, _format_count(region.reserved_development_funds(area.id)),
		_format_count(roundi(income)), _format_count(roundi(property)),
		_format_count(roundi(sales)), _format_count(roundi(fees)), _format_count(roundi(grants)), _format_count(roundi(transfers)), _format_count(roundi(upkeep))]
	if area.kind == "Region":
		fiscal_label.tooltip_text += "\nOther local treasuries $%s" % _format_count(roundi(child_balance))


func _refresh_scope_breadcrumb() -> void:
	var area = region.jurisdictions[selected_jurisdiction_id]
	if area.parent_id >= 0:
		var parent = region.jurisdictions[area.parent_id]
		scope_breadcrumb.text = "[url=jurisdiction:%d]← %s[/url]\n[b]%s · %s[/b]" % [parent.id, parent.name, area.kind, area.name]
	else:
		scope_breadcrumb.text = "[b]%s · %s[/b]" % [area.kind, area.name]


func _on_inspector_meta_clicked(meta: Variant) -> void:
	var link: String = str(meta)
	if link.begins_with("development:"):
		var neighborhood_id: int = int(link.trim_prefix("development:"))
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) == neighborhood_id:
				_on_candidate_selected(candidate["id"])
				return
	if not link.begins_with("jurisdiction:"):
		return
	var id_text: String = link.trim_prefix("jurisdiction:")
	if id_text.is_valid_int():
		_on_jurisdiction_selected(int(id_text))


func _show_jurisdiction_inspector(reset_scroll: bool = true) -> void:
	var area = region.jurisdictions[selected_jurisdiction_id]
	_refresh_growth_policy_controls()
	if area.kind == "Neighborhood":
		_on_neighborhood_selected(area.neighborhood_ids[0], reset_scroll)
		return
	var totals: Dictionary = region.get_jurisdiction_totals(area.id)
	var lines := PackedStringArray()
	lines.append("[font_size=22][b]%s[/b][/font_size]" % area.name)
	lines.append("[color=#91abc0]%s[/color]" % area.kind)
	if area.kind == "City":
		lines.append("Development: %s" % region.city_development_state(area.id))
	if area.kind in ["State", "Region", "County", "City"]:
		lines.append("New development awaits approval in the growth review queue. City policies guide its proposed street and land-use plans.")
	lines.append("")
	lines.append("Population: %s" % _format_count(totals["population"]))
	lines.append("Households: %s / %s homes" % [_format_count(totals["households"]), _format_count(totals["housing_capacity"])])
	lines.append("Jobs: %s / %s capacity" % [_format_count(totals["jobs"]), _format_count(totals["job_capacity"])])
	var visible_children: Array[int] = []
	for child_id in area.child_ids:
		var child = region.jurisdictions[child_id]
		if child.kind == "Neighborhood" and (child.neighborhood_ids.is_empty() or region.neighborhoods[child.neighborhood_ids[0]].street_layout == null):
			continue
		visible_children.append(child_id)
	if not visible_children.is_empty():
		var child_kind: String = region.jurisdictions[visible_children[0]].kind
		var child_heading: String = {"County": "COUNTIES", "City": "CITIES"}.get(child_kind, child_kind.to_upper() + "S")
		lines.append("")
		lines.append("[color=#78c8dc][b]%s · CLICK A NAME TO OPEN[/b][/color]" % child_heading)
		for child_id in visible_children:
			var child = region.jurisdictions[child_id]
			var child_totals: Dictionary = region.get_jurisdiction_totals(child_id)
			lines.append("[url=jurisdiction:%d][color=#9bd3ef]%s[/color][/url]" % [child_id, child.name])
			lines.append("  %s people  •  %s jobs" % [_format_count(child_totals["population"]), _format_count(child_totals["jobs"])])
	var previous_scroll: float = inspector.get_v_scroll_bar().value
	inspector.text = "\n".join(lines)
	if reset_scroll:
		inspector.scroll_to_line(0)
	else:
		inspector.get_v_scroll_bar().value = previous_scroll


func _generate_region(seed_value: int) -> void:
	if generation_thread != null:
		return
	discard_road_rebuild = road_rebuild_thread != null
	seed_input.set_value_no_signal(seed_value)
	seed_input.editable = false
	var city_count: int = map_size_selector.get_selected_id()
	generate_button.disabled = true
	seed_generate_button.disabled = true
	map_size_selector.disabled = true
	summary_label.text = "Generating %s…" % map_size_selector.get_item_text(map_size_selector.selected)
	var worker := Thread.new()
	var task := Callable(RegionSetup, "build").bind(seed_value, city_count, tax_input.value / 100.0)
	if worker.start(task, Thread.PRIORITY_NORMAL) != OK:
		generate_button.disabled = false
		seed_generate_button.disabled = false
		seed_input.editable = true
		map_size_selector.disabled = false
		push_error("Could not start region generation worker.")
		return
	generation_thread = worker


func _poll_generation() -> void:
	if generation_thread == null or generation_thread.is_alive():
		return
	var result: Dictionary = generation_thread.wait_to_finish()
	generation_thread = null
	generate_button.disabled = false
	seed_generate_button.disabled = false
	seed_input.editable = true
	map_size_selector.disabled = false
	if result.is_empty():
		push_error("Region generation returned no data.")
		return
	_apply_generated_region(result)


func _apply_generated_region(result: Dictionary) -> void:
	_discard_pending_day()
	deferred_region_edits.clear()
	deferred_mode_index = -1
	region = result["region"]
	region.dev_mode = dev_mode_enabled
	flow_profile = result["flow"]
	traffic_state = result["traffic_state"]
	calendar_clock = result["clock"]
	last_dynamics_day_key = traffic_state.day_key
	traffic_profile = traffic_state.profile
	week_timeline_history.clear()
	week_timeline_start_key = traffic_state.day_key if simulation_mode == MultiScaleTraffic.DAY else -1
	inspected_hour = -1
	var errors: PackedStringArray = result["errors"]
	if not errors.is_empty():
		push_error("Invalid generated region: " + "; ".join(errors))
		inspector.text = "[color=#ff8c8c]Region generation failed validation.[/color]"
		return
	next_day_profile = null
	road_preview_serial+=1
	road_preview_request.clear()
	road_start_position=Vector2.INF
	road_start_node = -1
	planning_has_start = false
	road_waypoints.clear()
	road_last_guide_click = false
	pending_road_preview.clear()
	selected_road_link_id = -1
	selected_candidate_id = -1
	selected_candidate_key = ""
	zoning_controls.visible = false
	map_view.set_region(region)
	map_view.selected_local_street = Vector2i(-1, -1)
	map_view.set_map_mode("Roads")
	map_view.set_detail_level("Neighborhood" if simulation_mode <= MultiScaleTraffic.MINUTE else ("Region" if simulation_mode == MultiScaleTraffic.HOUR else "State"))
	map_mode_selector.select(0)
	road_tool_selector.select(0)
	road_build_button.text = "Build"
	map_view.set_road_tool("Inspect")
	map_view.set_traffic_profile(traffic_profile)
	map_view.set_flow_profile(flow_profile)
	flow_timeline.set_profile(flow_profile)
	_update_road_status()
	map_view.set_purpose(flow_purpose)
	flow_timeline.set_purpose(flow_purpose)
	_refresh_region_summary()
	_on_jurisdiction_selected(0)
	_sync_clock_view()
	playing = true
	play_button.text = "Pause"
	simulation_credit = 0.0


func _refresh_region_summary(prepared_stats: Dictionary = {}) -> void:
	var totals: Dictionary = prepared_stats if not prepared_stats.is_empty() else region.get_region_totals()
	summary_label.text = "%s  •  %d regions  •  %d counties  •  %d cities  •  %d neighborhoods  •  %s people  •  %s jobs" % [
		region.state_name, region.region_ids.size(), region.county_ids.size(), region.cities.size(), region.neighborhoods.size(),
		_format_count(totals["population"]), _format_count(totals["jobs"]),
	]
	var balance: float = float(prepared_stats.get("balance", 0.0))
	var net: float = float(prepared_stats.get("net", 0.0))
	if prepared_stats.is_empty():
		for area in region.jurisdictions:
			balance += area.treasury
			net += area.daily_net()
		balance += region.reserved_development_funds()
	dynamics_label.text = "Today: %+d households / %+d people  •  Total funds $%s  •  Net $%s/day" % [
		region.last_household_change, region.last_population_change, "∞" if region.dev_mode else _format_count(roundi(balance)), _format_count(roundi(net))
	]
	_refresh_fiscal_controls()


func _ensure_day_profiles() -> void:
	if pending_day_result_key != last_dynamics_day_key + 1 or traffic_state == null:
		return
	if traffic_state.unix_seconds < pending_day_result_key * 86400:
		return
	_discard_compact_hour_precompute()
	if simulation_mode == MultiScaleTraffic.DAY:
		map_view.promote_day_road_summary()
	elif simulation_mode == MultiScaleTraffic.HOUR:
		map_view.set_hour_carry_summary(RoadTrafficSummary.completed_hour(traffic_state, 23))
	var handoff_started: int = Time.get_ticks_usec()
	last_handoff_breakdown.clear()
	if simulation_mode == MultiScaleTraffic.DAY and week_timeline_start_key >= 0:
		week_timeline_history[traffic_state.day_key] = flow_profile.get_daily_totals()
	var old_data: Dictionary = {"region": region, "flow": flow_profile, "traffic_state": traffic_state, "traffic_profile": traffic_profile}
	var summary_stats: Dictionary = pending_day_result.get("summary_stats", {})
	region = pending_day_result["region"]
	region.dev_mode = dev_mode_enabled
	flow_profile = pending_day_result["flow"]
	traffic_state = pending_day_result["traffic_state"]
	traffic_profile = traffic_state.profile
	if pending_day_source_mode >= 0 and pending_day_source_mode != simulation_mode:
		MultiScaleTraffic.change_mode(region, flow_profile, traffic_state, pending_day_source_mode, simulation_mode)
	pending_day_source_mode = -1
	pending_day_result = {}
	pending_day_result_key = -1
	last_dynamics_day_key = traffic_state.day_key
	calendar_clock.unix_seconds = traffic_state.unix_seconds
	map_view.region = region
	map_view.set_flow_profile(flow_profile)
	map_view.set_traffic_profile(traffic_profile)
	flow_timeline.set_profile(flow_profile)
	next_day_profile = null
	map_view.set_next_day_profile(null)
	flow_timeline.set_next_day_profile(null)
	last_handoff_breakdown["assign"] = Time.get_ticks_usec() - handoff_started
	_retire_simulation_data(old_data)
	last_handoff_breakdown["retire"] = Time.get_ticks_usec() - handoff_started
	_refresh_region_summary(summary_stats)
	last_handoff_breakdown["summary"] = Time.get_ticks_usec() - handoff_started
	pending_inspector_refresh = true
	_update_road_status()
	last_handoff_breakdown["total"] = Time.get_ticks_usec() - handoff_started


func _retire_simulation_data(payload: Dictionary) -> void:
	var worker := Thread.new()
	if worker.start(Callable(RegionSnapshot, "release_retired_data").bind(payload), Thread.PRIORITY_LOW) == OK:
		retired_data_threads.append(worker)
	else:
		# Keep the payload alive and retry on a later frame if a thread cannot start.
		retired_data_backlog.append(payload)


func _ensure_compact_hour_worker() -> void:
	if simulation_mode != MultiScaleTraffic.HOUR or region == null or not region.is_large_scale or traffic_state == null:
		return
	if traffic_state.unix_seconds >= (traffic_state.day_key + 1) * 86400:
		return
	if compact_hour_thread != null or traffic_state.compact_hourly_links.size() == 24 or _region_snapshot_busy():
		return
	var snapshot = MultiScaleTraffic.fork_for_week(traffic_state)
	var buffer = CompactHourPrecompute.new()
	buffer.bind_source(region, flow_profile, traffic_state.day_key)
	var worker := Thread.new()
	var task := Callable(CompactHourPrecompute, "prepare").bind(region, flow_profile, snapshot, buffer)
	if worker.start(task, Thread.PRIORITY_LOW) != OK:
		push_warning("Could not start hourly route preparation worker; using direct calculation.")
		return
	compact_hour_buffer = buffer
	compact_hour_thread = worker
	active_snapshot_buffers.append(buffer)


func _poll_compact_hour_worker() -> void:
	if compact_hour_thread == null:
		return
	if compact_hour_buffer != null and traffic_state != null and compact_hour_buffer.source_region == region and compact_hour_buffer.source_flow == flow_profile and compact_hour_buffer.source_day_key == traffic_state.day_key:
		var prepared: Dictionary = compact_hour_buffer.snapshot_hours()
		if int(prepared["count"]) > compact_hour_prepared_count:
			traffic_state.compact_hourly_links = prepared["links"]
			traffic_state.compact_hourly_revenue = prepared["revenue"]
			compact_hour_prepared_count = int(prepared["count"])
	if compact_hour_thread.is_alive():
		return
	var result: Dictionary = compact_hour_thread.wait_to_finish()
	compact_hour_thread = null
	compact_hour_buffer = null
	if result.is_empty() or traffic_state == null:
		return
	if result["region"] != region or result["flow"] != flow_profile or result["day_key"] != traffic_state.day_key or result["link_ids"] != traffic_state.link_ids:
		return


func _discard_compact_hour_precompute() -> void:
	if compact_hour_buffer != null:
		compact_hour_buffer.cancel()
		compact_hour_buffer = null
	if compact_hour_thread != null:
		retired_day_threads.append(compact_hour_thread)
		compact_hour_thread = null
	if traffic_state != null:
		traffic_state.compact_hourly_links.clear()
		traffic_state.compact_hourly_revenue.clear()
	compact_hour_prepared_count = 0


func _reap_finished_data_threads() -> void:
	for index in range(retired_data_threads.size() - 1, -1, -1):
		if not retired_data_threads[index].is_alive():
			retired_data_threads[index].wait_to_finish()
			retired_data_threads.remove_at(index)
	if not retired_data_backlog.is_empty():
		var payload: Dictionary = retired_data_backlog.pop_back()
		_retire_simulation_data(payload)


func _ensure_week_worker() -> void:
	if week_thread != null and not week_thread.is_alive():
		week_thread.wait_to_finish()
		week_thread = null
		week_buffer = null
	if week_thread != null or week_buffer != null or pending_day_thread != null or pending_day_result_key >= 0:
		return
	if _region_snapshot_busy():
		return
	if Time.get_ticks_msec() < day_worker_retry_at_msec:
		return
	var traffic_snapshot = MultiScaleTraffic.fork_for_week(traffic_state)
	var buffer = MultiScaleWeekBuffer.new()
	var worker := Thread.new()
	var task := Callable(MultiScaleDayCalculator, "produce_seven_day_windows").bind(region, flow_profile, traffic_snapshot, buffer)
	if worker.start(task, Thread.PRIORITY_LOW) != OK:
		day_worker_retry_at_msec = Time.get_ticks_msec() + 1000
		push_warning("Could not start seven-day worker; simulation will retry.")
		return
	week_buffer = buffer
	week_thread = worker
	active_snapshot_buffers.append(buffer)


func _region_snapshot_busy() -> bool:
	if road_preview_thread != null and not road_preview_job.snapshot_ready(): return true
	if road_rebuild_thread != null:
		return true
	for index in range(active_snapshot_buffers.size() - 1, -1, -1):
		if bool(active_snapshot_buffers[index].status()["snapshot_ready"]):
			active_snapshot_buffers.remove_at(index)
	return not active_snapshot_buffers.is_empty()


func _poll_week_worker() -> void:
	if week_buffer == null or pending_day_result_key >= 0:
		return
	var target_day_key: int = last_dynamics_day_key + 1
	var result: Dictionary = week_buffer.take(target_day_key)
	if result.is_empty():
		return
	pending_day_result = result
	pending_day_result_key = target_day_key
	pending_day_source_mode = MultiScaleTraffic.DAY
	_set_next_day_flow(pending_day_result["flow"])
	var completed_road_day: Dictionary = pending_day_result.get("completed_road_day", {})
	if int(completed_road_day.get("day_key", -1)) == traffic_state.day_key:
		map_view.set_current_day_road_summary(completed_road_day)


func _effective_day_rate(target_rate: float) -> float:
	if week_buffer == null:
		return minf(target_rate, 86400.0)
	var status: Dictionary = week_buffer.status()
	var ready_days: int = int(status["ready"]) + int(pending_day_result_key == last_dynamics_day_key + 1)
	var production_rate: float = maxf(0.75, float(status["rate"]))
	var safe_days_per_second: float = maxf(0.7, production_rate * 0.95 + maxf(0.0, float(ready_days - 1)) * 0.35)
	return minf(target_rate, safe_days_per_second * 86400.0)


func _queue_next_day(current_day_key: int) -> void:
	if traffic_state == null or traffic_state.unix_seconds < (current_day_key + 1) * 86400:
		return
	if simulation_mode == MultiScaleTraffic.DAY:
		_ensure_week_worker()
		_poll_week_worker()
		if week_buffer != null:
			return
	if Time.get_ticks_msec() < day_worker_retry_at_msec:
		return
	var target_day_key: int = current_day_key + 1
	if pending_day_result_key == target_day_key or pending_day_key == target_day_key:
		return
	if pending_day_thread != null:
		_discard_pending_day()
	var snapshot = RegionSnapshot.copy_region(region)
	var worker := Thread.new()
	var traffic_snapshot = MultiScaleTraffic.fork_for_day(traffic_state)
	var task := Callable(MultiScaleDayCalculator, "advance_day").bind(snapshot, target_day_key, flow_profile, traffic_snapshot)
	if worker.start(task, Thread.PRIORITY_LOW) != OK:
		day_worker_retry_at_msec = Time.get_ticks_msec() + 1000
		push_warning("Could not start next-day worker; simulation will retry.")
		return
	pending_day_thread = worker
	pending_day_key = target_day_key
	pending_day_source_mode = simulation_mode


func _poll_day_worker() -> void:
	if pending_day_thread == null or pending_day_thread.is_alive():
		return
	pending_day_result = pending_day_thread.wait_to_finish()
	pending_day_result_key = pending_day_key
	pending_day_thread = null
	pending_day_key = -1
	_set_next_day_flow(pending_day_result["flow"])


func _set_next_day_flow(profile) -> void:
	next_day_profile = profile
	if map_view != null:
		map_view.set_next_day_profile(profile)
	if flow_timeline != null:
		flow_timeline.set_next_day_profile(profile)


func _discard_pending_day(clear_road_display: bool = true) -> void:
	_discard_compact_hour_precompute()
	_set_next_day_flow(null)
	if clear_road_display and map_view != null:
		map_view.clear_day_road_summaries()
	if week_buffer != null:
		week_buffer.cancel()
		week_buffer = null
	if week_thread != null:
		retired_day_threads.append(week_thread)
		week_thread = null
	if pending_day_thread != null:
		retired_day_threads.append(pending_day_thread)
		pending_day_thread = null
		pending_day_key = -1
	pending_day_result = {}
	pending_day_result_key = -1
	pending_day_source_mode = -1
	_reap_finished_day_threads()


func _reap_finished_day_threads() -> void:
	for index in range(retired_day_threads.size() - 1, -1, -1):
		if not retired_day_threads[index].is_alive():
			retired_day_threads[index].wait_to_finish()
			retired_day_threads.remove_at(index)


func _invalidate_traffic_forecast() -> void:
	if traffic_state == null:
		return
	MultiScaleTraffic.invalidate(traffic_state)
	traffic_profile = traffic_state.profile
	map_view.set_traffic_profile(traffic_profile)
	_discard_pending_day()


func _sync_clock_view() -> void:
	var hour: int = inspected_hour if inspected_hour >= 0 else calendar_clock.get_hour()
	var fraction: float = float(inspected_minute) / 60.0 if inspected_hour >= 0 else calendar_clock.get_hour_fraction()
	var weekend: bool = calendar_clock.is_weekend()
	var forecast: bool = inspected_hour >= 0 and hour * 60 + inspected_minute > calendar_clock.get_hour() * 60 + calendar_clock.get_minute()
	var requested_bin: int = hour * 4 + floori(fraction * 4.0)
	var traffic_ready: bool = requested_bin >= traffic_state.first_recorded_bin and requested_bin < traffic_state.next_bin
	var traffic_display_time: Vector2 = _display_traffic_time(hour, fraction)
	var inspection_status: String = ("uncalculated forecast" if forecast else "scheduled demand") if not traffic_ready else ("forecast" if forecast else "history")
	var next_day_pending: bool = traffic_state.unix_seconds >= (traffic_state.day_key + 1) * 86400 and pending_day_result_key != traffic_state.day_key + 1
	calendar_label.text = calendar_clock.get_display_text(simulation_mode == MultiScaleTraffic.SECOND)
	if simulation_mode >= MultiScaleTraffic.HOUR:
		calendar_label.text += "  •  estimated traffic"
	if inspected_hour >= 0:
		calendar_label.text += "  •  Inspecting %02d:%02d %s" % [hour, inspected_minute, inspection_status]
	if next_day_pending:
		calendar_label.text += ("  •  Preparing seven-day cycle" if simulation_mode == MultiScaleTraffic.DAY else "  •  Preparing next day")
	hourly_trip_label.text = "%s trips/h  •  %s work  •  %s commercial  •  %s social" % [
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.ALL, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.WORK, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.COMMERCIAL, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.SOCIAL, next_day_profile))),
	]
	flow_timeline.set_time(hour, fraction)
	flow_timeline.set_clock_time(calendar_clock.get_hour(), calendar_clock.get_hour_fraction())
	flow_timeline.set_weekend(weekend)
	if simulation_mode == MultiScaleTraffic.DAY:
		_sync_week_timeline()
	else:
		flow_timeline.set_week_mode(false)
	var latest_completed_hour: int = -1
	var previous_completed_hour: int = -1
	if simulation_mode == MultiScaleTraffic.HOUR and inspected_hour < 0:
		var candidate_hour: int = (traffic_state.unix_seconds - traffic_state.day_key * 86400) / 3600 - 1
		if candidate_hour >= 0 and candidate_hour * 4 + 3 < traffic_state.next_bin and candidate_hour * 4 + 3 >= traffic_state.first_recorded_bin:
			latest_completed_hour = candidate_hour
			if candidate_hour > 0 and (candidate_hour - 1) * 4 + 3 >= traffic_state.first_recorded_bin:
				previous_completed_hour = candidate_hour - 1
	map_view.set_hourly_road_history(previous_completed_hour, latest_completed_hour, fraction)
	var road_display_mode: int = RegionMap.ROAD_DAY if simulation_mode == MultiScaleTraffic.DAY else (RegionMap.ROAD_HISTORY if inspected_hour >= 0 else (RegionMap.ROAD_HOUR if simulation_mode == MultiScaleTraffic.HOUR else RegionMap.ROAD_LIVE))
	map_view.set_road_traffic_mode(road_display_mode, traffic_state)
	map_view.set_day_road_fraction(fposmod(calendar_clock.get_display_unix_seconds(), 86400.0) / 86400.0)
	if map_view.map_mode == "Trips":
		var trip_time_changed: bool = map_view.selected_hour != hour or not is_equal_approx(map_view.hour_fraction, fraction)
		map_view.set_time(hour, fraction, false)
		trip_redraw_pending = trip_redraw_pending or trip_time_changed
		var now_msec: int = Time.get_ticks_msec()
		if trip_redraw_pending and (not playing or inspected_hour >= 0 or now_msec - last_trip_redraw_msec >= ANIMATED_MAP_REDRAW_INTERVAL_MS):
			map_view.queue_redraw()
			last_trip_redraw_msec = now_msec
			trip_redraw_pending = false
	else:
		map_view.set_time(int(traffic_display_time.x), traffic_display_time.y)
	map_view.set_recorded_bin(traffic_state.next_bin, traffic_state.first_recorded_bin)
	_update_flow_detail()
	if selected_road_link_id >= 0 and map_mode_selector.selected == 0:
		_show_road_inspector(selected_road_link_id)


func _sync_week_timeline() -> void:
	if week_timeline_start_key < 0 or traffic_state.day_key >= week_timeline_start_key + 7:
		week_timeline_start_key = traffic_state.day_key
		week_timeline_history.clear()
	var totals: Dictionary = week_timeline_history.duplicate()
	totals[traffic_state.day_key] = flow_profile.get_daily_totals()
	if pending_day_result_key >= week_timeline_start_key and pending_day_result_key < week_timeline_start_key + 7:
		totals[pending_day_result_key] = pending_day_result["flow"].get_daily_totals()
	if week_buffer != null:
		var prepared_flows: Dictionary = week_buffer.snapshot_flows()
		for day_key in prepared_flows:
			if int(day_key) >= week_timeline_start_key and int(day_key) < week_timeline_start_key + 7:
				totals[day_key] = prepared_flows[day_key].get_daily_totals()
	flow_timeline.set_week_mode(true)
	flow_timeline.set_week_window(week_timeline_start_key, calendar_clock.get_display_unix_seconds(), totals)


func _display_traffic_time(hour: int, fraction: float) -> Vector2:
	if simulation_mode == MultiScaleTraffic.HOUR and region.is_large_scale and inspected_hour < 0:
		var completed_hour: int = (traffic_state.unix_seconds - traffic_state.day_key * 86400) / 3600 - 1
		if completed_hour >= 0 and completed_hour * 4 + 3 < traffic_state.next_bin and completed_hour * 4 + 3 >= traffic_state.first_recorded_bin:
			return Vector2(completed_hour, 0.75)
	var requested_bin: int = hour * 4 + floori(fraction * 4.0)
	if inspected_hour >= 0 or requested_bin < traffic_state.next_bin or traffic_state.next_bin <= traffic_state.first_recorded_bin:
		return Vector2(hour, fraction)
	var last_bin: int = traffic_state.next_bin - 1
	return Vector2(floori(float(last_bin) / 4.0), (float(last_bin % 4) + 0.999) / 4.0)


func _update_flow_detail() -> void:
	if flow_profile == null or calendar_clock == null:
		return
	var hour: int = inspected_hour if inspected_hour >= 0 else calendar_clock.get_hour()
	var minute: int = inspected_minute if inspected_hour >= 0 else calendar_clock.get_minute()
	var fraction: float = float(minute) / 60.0 if inspected_hour >= 0 else calendar_clock.get_hour_fraction()
	var neighborhood_id: int = map_view.selected_id
	if neighborhood_id < 0:
		flow_detail_label.text = "%02d:%02d  •  %s\nRegion: %s trips/h" % [hour, minute, flow_purpose, _format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, flow_purpose, next_day_profile)))]
		return
	var totals: Vector3 = flow_profile.get_interpolated_neighborhood_totals(neighborhood_id, hour, fraction, flow_purpose, next_day_profile)
	flow_detail_label.text = "%02d:%02d  •  %s\nOut: %s/h     In: %s/h\nLocal: %s/h" % [
		hour, minute, flow_purpose, _format_count(roundi(totals.x)), _format_count(roundi(totals.y)), _format_count(roundi(totals.z))
	]


func _on_neighborhood_selected(neighborhood_id: int, reset_scroll: bool = true) -> void:
	map_view.selected_local_street = Vector2i(-1, -1)
	selected_candidate_id = -1
	selected_candidate_key = ""
	zoning_controls.visible = false
	map_view.set_selected_candidate(-1)
	selected_road_link_id = -1
	_refresh_toll_controls()
	map_view.set_selected_road_link(-1)
	if neighborhood_id < 0:
		var current = region.jurisdictions[selected_jurisdiction_id]
		if current.kind == "Neighborhood":
			_on_jurisdiction_selected(current.parent_id)
		else:
			_show_jurisdiction_inspector(reset_scroll)
		return
	map_view.set_selected(neighborhood_id)
	selected_jurisdiction_id = region.neighborhoods[neighborhood_id].jurisdiction_id
	map_view.set_selected_jurisdiction(selected_jurisdiction_id)
	_refresh_scope_breadcrumb()
	state_tax_controls.visible = false
	jurisdiction_policy_controls.visible = true
	policy_options = [{"label": "Parking fee", "property": "parking_fee", "max": 50.0, "step": 0.25, "percent": false}]
	policy_selector.clear()
	policy_selector.add_item("Parking fee")
	_on_policy_selected(0)
	_refresh_fiscal_controls()
	_update_flow_detail()
	var neighborhood = region.neighborhoods[neighborhood_id]
	var city_totals: Dictionary = region.get_city_totals(neighborhood.city_id)
	var region_totals: Dictionary = region.get_region_totals()
	var access: float = region.accessibility[neighborhood_id]
	var share_of_jobs: float = 100.0 * access / maxf(1.0, float(region_totals["jobs"]))
	var text_lines := PackedStringArray()
	text_lines.append("[font_size=22][b]%s[/b][/font_size]" % neighborhood.name)
	text_lines.append("[color=#91abc0]%s City  •  %.0f ha[/color]" % [region.get_city_name(neighborhood.city_id), neighborhood.land_area_ha])
	text_lines.append("[color=#91abc0]Developable area: %.0f ha[/color]" % neighborhood.developable_area_ha)
	if neighborhood.development_plan != null:
		text_lines.append("[url=development:%d]Manage development budget and zoning[/url]" % neighborhood_id)
		text_lines.append("Plan: %s • Phase %d/3 • Reserved $%d" % [neighborhood.development_plan.status, neighborhood.development_plan.completed_phase, neighborhood.development_plan.reserved])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]NEIGHBORHOOD[/b][/color]")
	text_lines.append("Development: %s" % neighborhood.development_state)
	if not neighborhood.character_profile.is_empty():
		text_lines.append("Character: %s" % neighborhood.character_profile)
	if neighborhood.development_state == "Dormant":
		text_lines.append("Connect this gateway to an established city to begin growth.")
	elif neighborhood.development_state == "Disconnected":
		text_lines.append("Road access lost. Residents and jobs are leaving gradually.")
	elif neighborhood.development_state == "Developing":
		text_lines.append("Connected land is attracting residents and jobs each day.")
	text_lines.append("Population: %s" % _format_count(neighborhood.population))
	text_lines.append("Households: %s / %s homes" % [_format_count(neighborhood.households), _format_count(neighborhood.housing_capacity)])
	if neighborhood.building_model_version>0:
		var constructing:=0
		var planned:=0
		var completed:=0
		for building in neighborhood.buildings:
			if building.state=="Constructing": constructing+=1
			elif building.state=="Complete": completed+=1
			else: planned+=1
		text_lines.append("Buildings: %s planned · %s constructing · %s complete" % [_format_count(planned),_format_count(constructing),_format_count(completed)])
		text_lines.append("Completed: %s homes · %s job spaces" % [_format_count(neighborhood.housing_capacity),_format_count(neighborhood.job_capacity)])
		text_lines.append("Full plan: %s homes · %s job spaces" % [_format_count(neighborhood.development_plan.target_housing),_format_count(neighborhood.development_plan.target_jobs)])
	text_lines.append("Today: %+d households" % neighborhood.last_household_change)
	text_lines.append("People: %+d today" % neighborhood.last_population_change)
	text_lines.append("Jobs: %s / %s capacity" % [_format_count(neighborhood.jobs), _format_count(neighborhood.job_capacity)])
	text_lines.append("Retail jobs: %s" % _format_count(roundi(neighborhood.shopping_attraction)))
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]HOUSING & WEALTH[/b][/color]")
	text_lines.append("Rent: $%s/mo" % _format_count(neighborhood.monthly_rent))
	text_lines.append("Income: $%s/mo" % _format_count(neighborhood.average_monthly_income))
	text_lines.append("After income tax: $%s/mo" % _format_count(roundi(FiscalCalculator.after_income_tax(region, neighborhood))))
	text_lines.append("Property tax in housing cost: $%s/mo" % _format_count(roundi(FiscalCalculator.property_cost_monthly(region, neighborhood))))
	text_lines.append("Wealth: $%s/household" % _format_count(roundi(neighborhood.average_household_wealth)))
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]DESIRABILITY[/b][/color]")
	text_lines.append("Desirability: %.1f / 100" % neighborhood.desirability)
	text_lines.append("Job access: [b]%s[/b]" % _format_count(roundi(access)))
	text_lines.append("Travel-weighted: %.1f%% of jobs" % share_of_jobs)
	text_lines.append("[color=#91abc0]Rent • wealth • vacancy • tax[/color]")
	text_lines.append("[color=#91abc0]Access • local amenities[/color]")
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]ZONING · SHARE / DENSITY[/b][/color]")
	for zone in RegionData.ZONE_TYPES:
		text_lines.append("%s: %d%% / %s" % [zone, neighborhood.zone_shares[zone], RegionData.DENSITY_NAMES[neighborhood.zone_density[zone]]])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]JOBS BY SKILL[/b][/color]")
	for skill in ["Entry", "Skilled", "Professional"]:
		text_lines.append("%s: %s" % [skill, _format_count(neighborhood.jobs_by_skill[skill])])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]TRAVEL TIMES[/b][/color]")
	var travel_order: Array[int] = []
	if region.is_large_scale:
		# Keep the inspector bounded at state scale. Nearby destinations are the useful ones.
		for id in region.cities[neighborhood.city_id]["neighborhood_ids"]:
			if region.neighborhoods[id].street_layout != null:
				travel_order.append(id)
		for city in region.cities:
			if city["id"] != neighborhood.city_id:
				for id in city["neighborhood_ids"]:
					if region.neighborhoods[id].street_layout != null:
						travel_order.append(id)
						break
	else:
		for id in range(region.neighborhoods.size()):
			if region.neighborhoods[id].street_layout != null:
				travel_order.append(id)
	travel_order.sort_custom(func(a: int, b: int) -> bool: return region.travel_time_between(neighborhood_id, a) < region.travel_time_between(neighborhood_id, b))
	for id in travel_order.slice(0, 24 if region.is_large_scale else travel_order.size()):
		var minutes: float = region.travel_time_between(neighborhood_id, id)
		if minutes >= 1000000.0:
			text_lines.append("%s: no road route" % region.neighborhoods[id].name)
		else:
			text_lines.append("%s: %.1f min" % [region.neighborhoods[id].name, minutes])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]%s CITY TOTAL[/b][/color]" % region.get_city_name(neighborhood.city_id).to_upper())
	text_lines.append("Population: %s" % _format_count(city_totals["population"]))
	text_lines.append("Jobs: %s" % _format_count(city_totals["jobs"]))
	var previous_scroll: float = inspector.get_v_scroll_bar().value
	inspector.text = "\n".join(text_lines)
	if reset_scroll:
		inspector.scroll_to_line(0)
	else:
		inspector.get_v_scroll_bar().value = previous_scroll


func _current_day_key() -> int:
	return floori(float(calendar_clock.unix_seconds) / 86400.0)


func _on_local_street_selected(neighborhood_id: int, edge_id: int) -> void:
	_on_neighborhood_selected(neighborhood_id)
	map_view.selected_local_street = Vector2i(neighborhood_id, edge_id)
	_show_local_street_inspector()
	map_view.queue_redraw()


func _show_local_street_inspector(reset_scroll: bool = true) -> void:
	var neighborhood_id: int = map_view.selected_local_street.x
	var edge_id: int = map_view.selected_local_street.y
	if neighborhood_id < 0 or neighborhood_id >= region.neighborhoods.size():
		return
	var neighborhood = region.neighborhoods[neighborhood_id]
	var layout = neighborhood.street_layout
	var record: Dictionary = traffic_state.local_districts.get(neighborhood_id, {})
	var rate: Vector2 = preload("res://scripts/simulation/local_street_traffic.gd").edge_rate(record, edge_id) if not record.is_empty() else Vector2.ZERO
	var queues: Vector2 = record["queues"][edge_id] if not record.is_empty() else Vector2.ZERO
	var multiplier: float = neighborhood.development_plan.installed_multiplier
	var previous_scroll: float = inspector.get_v_scroll_bar().value
	inspector.text = "[font_size=22][b]Local street[/b][/font_size]\n%s • %.0f m\nCity-managed development infrastructure\n\nArrival demand: %.1f / %.1f vehicles/h\nQueued: %.1f / %.1f vehicles\nFree speed: 20 km/h\nCapacity: %.0f vehicles/h\nJunction-adjusted discharge: %.0f vehicles/h\n\n[url=development:%d]Manage neighborhood funding and zoning[/url]" % [neighborhood.name, layout.lengths[edge_id] * 1000.0, rate.x, rate.y, queues.x, queues.y, 300.0 * multiplier, 225.0 * multiplier, neighborhood_id]
	if reset_scroll:
		inspector.scroll_to_line(0)
	else:
		inspector.get_v_scroll_bar().value = previous_scroll


func _on_candidate_selected(candidate_id: int) -> void:
	if region == null or candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return
	var candidate: Dictionary = region.development_candidates[candidate_id]
	_on_jurisdiction_selected(region.city_jurisdiction_ids[candidate["city_id"]])
	selected_candidate_id = candidate_id
	selected_candidate_key = candidate["key"]
	map_view.set_selected_candidate(candidate_id)
	map_view.set_selected(-1)
	growth_policy_controls.visible = false
	_show_candidate_inspector()


func _show_candidate_inspector(reset_scroll: bool = true) -> void:
	if region == null or selected_candidate_id < 0 or selected_candidate_id >= region.development_candidates.size():
		zoning_controls.visible = false
		return
	var candidate: Dictionary = region.development_candidates[selected_candidate_id]
	growth_policy_controls.visible = false
	var neighborhood_id: int = candidate["neighborhood_id"]
	var approved: bool = neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_approved
	var city_id: int = candidate["city_id"]
	var center: Vector2 = candidate["center_km"]
	var distance: float = center.distance_to(region.cities[city_id]["center_km"])
	var hectares: float = StateGeography.polygon_area(candidate["polygon"]) * 100.0
	zoning_controls.visible = true
	state_tax_controls.visible = false
	jurisdiction_policy_controls.visible = false
	zoning_button.text = "Withdraw approval" if approved else "Approve development"
	zoning_button.disabled = not approved and neighborhood_id < 0 and int(candidate["frontage_link_id"]) < 0
	zoning_status_label.text = "Road access lost" if int(candidate["frontage_link_id"]) < 0 else "Funding and zoning update daily"
	development_controls.show_plan(region, candidate, reset_scroll)
	var lines := PackedStringArray()
	lines.append("[font_size=22][b]Connected growth proposal[/b][/font_size]")
	lines.append("[color=#91abc0]%s City  •  %.0f ha[/color]" % [region.get_city_name(city_id), hectares])
	lines.append("Distance to city center: %.1f km" % distance)
	lines.append("Zoning: %s" % ("Approved" if approved else "Awaiting approval"))
	lines.append("Preview streets: %d segments  •  Full cost: $%d" % [candidate["layout"].edges.size(), candidate["layout"].total_cost()])
	if candidate.has("design_variant") and not approved:
		lines.append("Design %d of 3. Compare the street designs in the development panel before approval." % [int(candidate["design_variant"]) + 1])
	lines.append("Character: %s%s" % [candidate["character_profile"], " (Auto)" if neighborhood_id < 0 and candidate.get("character_override", "Auto") == "Auto" else ""])
	if neighborhood_id >= 0:
		var neighborhood = region.neighborhoods[neighborhood_id]
		lines.append("Development: %s" % neighborhood.development_state)
		lines.append("Population: %s  •  Jobs: %s" % [_format_count(neighborhood.population), _format_count(neighborhood.jobs)])
		lines.append("Desirability: %.1f / 100" % neighborhood.desirability)
		if neighborhood.development_plan != null:
			var plan = neighborhood.development_plan
			lines.append("Plan: %s • Phase %d / 3" % [plan.status, plan.completed_phase])
			lines.append("Reserved $%d • Spent $%d" % [plan.reserved, plan.spent])
			lines.append("Remaining construction $%d" % DevelopmentBudget.remaining_cost(neighborhood))
		lines.append("")
		lines.append("[color=#78c8dc][b]CURRENT LAND USE · SHARE / DENSITY[/b][/color]")
		for zone in RegionData.ZONE_TYPES:
			lines.append("%s: %d%% / %s" % [zone, neighborhood.zone_shares[zone], RegionData.DENSITY_NAMES[neighborhood.zone_density[zone]]])
	else:
		var defaults: Dictionary = RegionGenerator.zone_defaults(region, city_id, candidate["grid"])
		lines.append("")
		lines.append("[color=#78c8dc][b]DEFAULT LAND USE · SHARE / DENSITY[/b][/color]")
		for zone in RegionData.ZONE_TYPES:
			lines.append("%s: %d%% / %s" % [zone, defaults["shares"][zone], RegionData.DENSITY_NAMES[defaults["density"][zone]]])
	lines.append("")
	lines.append("Dev Mode funds construction automatically. Paid construction finishes and existing buildings remain." if region.dev_mode else "Approval reserves city funds. Infrastructure opens in phases before residents arrive. Cancellation returns unspent funds; paid construction finishes and existing buildings remain.")
	var previous_scroll: float = inspector.get_v_scroll_bar().value
	inspector.text = "\n".join(lines)
	if reset_scroll:
		inspector.scroll_to_line(0)
	else:
		inspector.get_v_scroll_bar().value = previous_scroll


func _on_zoning_pressed() -> void:
	if region == null or selected_candidate_id < 0:
		return
	var candidate: Dictionary = region.development_candidates[selected_candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	var approved: bool = neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_approved
	_apply_candidate_approval(selected_candidate_id, not approved, roundi(development_controls.allocation_input.value), development_controls.shares(), development_controls.densities())


func _on_development_design(candidate_id: int, variant: int) -> void:
	if region == null or candidate_id != selected_candidate_id:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_development_design").bind(candidate_id, variant))
		return
	if not DevelopmentPlanner.set_candidate_design(region, candidate_id, variant):
		zoning_status_label.text = "That street design cannot connect to the existing network."
		return
	development_controls.show_plan(region, region.development_candidates[candidate_id], false)
	_show_candidate_inspector(false)
	map_view.queue_redraw()


func _on_development_character(candidate_id: int, profile: String) -> void:
	if region == null or candidate_id != selected_candidate_id:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_development_character").bind(candidate_id, profile))
		return
	if DevelopmentPlanner.set_candidate_character(region, candidate_id, profile):
		development_controls.show_plan(region, region.development_candidates[candidate_id], false)
		_show_candidate_inspector(false)
		map_view.queue_redraw()


func _apply_candidate_approval(candidate_id: int, approved: bool, allocation: int, shares: Dictionary, density: Dictionary) -> void:
	if region == null or candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return
	if _region_snapshot_busy():
		# Candidate indices are rebuilt after every approval. Preserve the
		# selected district's stable key while another transaction is running.
		deferred_region_edits.append(Callable(self, "_apply_candidate_approval_key").bind(String(region.development_candidates[candidate_id].key), approved, allocation, shares.duplicate(), density.duplicate()))
		return
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	var current: bool = neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_approved
	if current == approved:
		return
	_start_region_edit({"kind":"approval","candidate_id":candidate_id,"approved":approved,"allocation":allocation,"shares":shares.duplicate(),"density":density.duplicate()})


func _apply_candidate_approval_key(key:String,approved:bool,allocation:int,shares:Dictionary,density:Dictionary) -> void:
	_apply_candidate_approval(int(region.development_candidate_keys.get(key,-1)),approved,allocation,shares,density)


func _on_development_allocation(neighborhood_id: int, amount: int) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_development_allocation").bind(neighborhood_id, amount))
		return
	var result: Dictionary = DevelopmentBudget.allocate(region, neighborhood_id, amount)
	if not result["ok"]:
		zoning_status_label.text = result["reason"]
		development_controls.editor_status_label.text = result["reason"]
		return
	_discard_pending_day()
	_refresh_region_summary()
	_queue_next_day(last_dynamics_day_key)
	_show_candidate_inspector(false)


func _on_development_zoning(neighborhood_id: int, shares: Dictionary, density: Dictionary) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_development_zoning").bind(neighborhood_id, shares.duplicate(), density.duplicate()))
		return
	var result: Dictionary = DevelopmentBudget.queue_zoning(region, neighborhood_id, shares, density, _current_day_key())
	if not result["ok"]:
		zoning_status_label.text = result["reason"]
		return
	_discard_pending_day()
	_queue_next_day(last_dynamics_day_key)
	zoning_status_label.text = "Zoning applies next day"


func _on_map_mode_selected(index: int) -> void:
	map_view.set_map_mode(["Roads", "Trips", "Zoning"][index])
	road_tool_selector.visible = index == 0
	road_draw_selector.visible = index == 0 and road_tool_selector.get_item_text(road_tool_selector.selected) in ["Arterial", "Highway"]
	road_snap_toggle.visible = road_draw_selector.visible
	road_length_snap_toggle.visible = road_draw_selector.visible
	road_build_button.visible = index == 0
	road_cancel_button.visible = index == 0
	flow_detail_label.visible = index == 1
	flow_detail_separator.visible = index == 1
	_cancel_road_preview()
	if index != 0:
		map_view.selected_local_street = Vector2i(-1, -1)
		selected_road_link_id = -1
		map_view.set_selected_road_link(-1)
		_refresh_toll_controls()
	if index != 2:
		selected_candidate_id = -1
		selected_candidate_key = ""
		zoning_controls.visible = false
		map_view.set_selected_candidate(-1)
	if index == 2:
		zoning_tool_message = "Amber dots mark suggested districts. Zoom in and click one to review and approve it."
	_refresh_inspector(false)
	_update_road_status()


func _scope_city_ids(area_id: int) -> Array[int]:
	var ids: Array[int] = []
	for city_id in range(region.cities.size()):
		var cursor: int = region.city_jurisdiction_ids[city_id]
		while cursor >= 0:
			if cursor == area_id:
				ids.append(city_id)
				break
			cursor = region.jurisdictions[cursor].parent_id
	return ids


func _refresh_growth_policy_controls() -> void:
	if growth_policy_controls == null or region == null:
		return
	var city_id: int = region.city_jurisdiction_ids.find(selected_jurisdiction_id)
	growth_policy_controls.visible = city_id >= 0 and selected_candidate_id < 0
	if not growth_policy_controls.visible:
		return
	var policy: Dictionary = region.cities[city_id].get("urban_policy", {})
	suppress_urban_policy_input = true
	for field in urban_policy_inputs:
		urban_policy_inputs[field].select(int(policy.get(field, 0)))
	suppress_urban_policy_input = false


func _on_urban_policy_selected(value: int, field: String) -> void:
	if suppress_urban_policy_input or region == null:
		return
	var city_id: int = region.city_jurisdiction_ids.find(selected_jurisdiction_id)
	if city_id < 0:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_urban_policy_selected").bind(value, field))
		return
	_discard_pending_day()
	var city: Dictionary = region.cities[city_id]
	var policy: Dictionary = city.get("urban_policy", {}).duplicate()
	policy[field] = value
	city["urban_policy"] = policy
	region.cities[city_id] = city
	DevelopmentPlanner.refresh_candidates(region)
	_refresh_inspector(false)
	map_view.queue_redraw()



func _on_map_jurisdiction_selected(area_id: int) -> void:
	_on_jurisdiction_selected(area_id)


func _on_road_tool_selected(index: int) -> void:
	map_view.set_road_tool(road_tool_selector.get_item_text(index))
	road_draw_selector.visible = road_tool_selector.get_item_text(index) in ["Arterial", "Highway"]
	road_snap_toggle.visible = road_draw_selector.visible
	road_length_snap_toggle.visible = road_draw_selector.visible
	road_build_button.text = "Demolish" if road_tool_selector.get_item_text(index) == "Demolish" else "Build"
	_cancel_road_preview()
	_update_road_status()


func _on_planning_point(point: Vector2) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_planning_point").bind(point))
		return
	var city_id: int = region.city_id_at_point(point)
	if city_id < 0:
		road_status_label.text = "Place planning guides inside a city."
		return
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name == "Station site":
		region.station_sites.append({"city_id": city_id, "point": point})
		map_view.set_transit_overlay(true)
		road_status_label.text = "Station site reserved for %s." % region.get_city_name(city_id)
	elif not planning_has_start:
		planning_start_point = point
		planning_has_start = true
		map_view.set_planning_preview(point, tool_name)
		_update_road_status()
		return
	else:
		var start_city: int = region.city_id_at_point(planning_start_point)
		if start_city != city_id or point.distance_to(planning_start_point) < 0.1:
			road_status_label.text = "Choose a second point at least 100 m away in the same city."
			return
		var guide: Dictionary = {"city_id": city_id, "points": PackedVector2Array([planning_start_point, point])}
		if tool_name == "Growth corridor":
			region.urban_corridors.append(guide)
			road_status_label.text = "Growth corridor added for %s." % region.get_city_name(city_id)
		else:
			region.rail_reservations.append(guide)
			map_view.set_transit_overlay(true)
			road_status_label.text = "Rail corridor reserved for %s." % region.get_city_name(city_id)
		planning_has_start = false
		map_view.set_planning_preview(Vector2.INF)
	DevelopmentPlanner.refresh_candidates(region)
	_refresh_inspector(false)
	map_view.queue_redraw()


func _on_road_draw_selected(_index: int) -> void:
	_cancel_road_preview()
	_update_road_snapping()


func _on_road_snap_toggled(_enabled: bool) -> void:
	_update_road_snapping()


func _on_road_length_snap_toggled(_enabled: bool) -> void:
	_update_road_snapping()


func _update_road_snapping() -> void:
	map_view.set_road_input_mode(_road_draw_mode(), road_snap_toggle.button_pressed, road_length_snap_toggle.button_pressed)


func _road_draw_mode() -> String:
	return road_draw_selector.get_item_text(road_draw_selector.selected)


func _road_required_guides() -> int:
	return 1 if _road_draw_mode() in [RoadRouteBuilder.CURVED, RoadRouteBuilder.MULTIPOINT] else 0


func _road_class() -> String:
	return RoadLinkData.HIGHWAY if road_tool_selector.get_item_text(road_tool_selector.selected) == "Highway" else RoadLinkData.ARTERIAL


func _on_road_node_clicked(node_id: int) -> void:
	map_view.selected_local_street = Vector2i(-1, -1)
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name in ["Growth corridor", "Rail corridor", "Station site"]:
		_on_planning_point(region.road_nodes[node_id].position_km)
		return
	match tool_name:
		"Arterial", "Highway":
			if road_start_node == -1 or not pending_road_preview.is_empty():
				_cancel_road_preview()
				road_start_node = node_id
				road_start_position = Vector2.INF
				road_waypoints.clear()
				road_last_guide_click = false
				pending_road_preview.clear()
				map_view.set_road_preview(road_start_node, road_waypoints, {},road_start_position)
			else:
				if road_waypoints.size() < _road_required_guides() or (_road_draw_mode() == RoadRouteBuilder.MULTIPOINT and road_waypoints.size() % 2 == 0):
					road_status_label.text = "Place a curve guide before choosing the end." if _road_draw_mode() == RoadRouteBuilder.MULTIPOINT else "Add a curve guide before choosing the end."
					return
				_request_road_preview(node_id,region.road_nodes[node_id].position_km)
			_refresh_crossing_controls()
		"Interchange":
			pending_road_preview = RoadPlanner.interchange_preview(region, node_id, -1, Vector2.ZERO, _current_day_key())
			map_view.set_road_preview(-1, PackedVector2Array(), pending_road_preview)
		_:
			var node = region.road_nodes[node_id]
			if node.neighborhood_id >= 0:
				_on_neighborhood_selected(node.neighborhood_id)
			else:
				selected_road_link_id = -1
				inspector.text = "[font_size=21][b]%s[/b][/font_size]\n\nNode %d  •  %.1f, %.1f km\nHighway access: %s" % [node.display_name(), node_id, node.position_km.x, node.position_km.y, "yes" if node.is_interchange else "no"]
	_update_road_status()


func _on_road_link_clicked(link_id: int, world_position: Vector2) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_road_link_clicked").bind(link_id, world_position))
		return
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name in ["Growth corridor", "Rail corridor", "Station site"]:
		_on_planning_point(world_position)
		return
	if tool_name in ["Arterial","Highway"]:
		if road_start_node == -1 or not pending_road_preview.is_empty():
			_cancel_road_preview()
			road_start_node=-2
			var index:int=RoadGraph.link_index(region,link_id)
			if index<0: return
			road_start_position=RoadPlanner.closest_point(region.road_links[index].points,world_position)
			road_waypoints.clear()
			pending_road_preview.clear()
			map_view.set_road_preview(road_start_node,road_waypoints,{},road_start_position)
		else:
			if road_waypoints.size()<_road_required_guides() or _road_draw_mode()==RoadRouteBuilder.MULTIPOINT and road_waypoints.size()%2==0:
				road_status_label.text="Place a curve guide before choosing the end."
				return
			_request_road_preview(-1,world_position)
		_update_road_status()
		return
	if tool_name != "Junction":
		map_view.selected_local_street = Vector2i(-1, -1)
		selected_road_link_id = link_id
		_refresh_toll_controls()
		map_view.set_selected_road_link(link_id)
		_show_road_inspector(link_id)
	match tool_name:
		"Junction":
			var result: Dictionary = RoadPlanner.add_junction(region, world_position, link_id)
			road_status_label.text = "Junction added." if result["ok"] else result["reason"]
			if result["ok"]:
				_rebuild_after_road_change()
		"Interchange":
			pending_road_preview = RoadPlanner.interchange_preview(region, -1, link_id, world_position, _current_day_key())
			map_view.set_road_preview(-1, PackedVector2Array(), pending_road_preview)
			_update_road_status()
		"Widen":
			pending_road_preview = RoadPlanner.widen_preview(region, link_id, _current_day_key())
			map_view.set_road_preview(-1, PackedVector2Array(), pending_road_preview)
			_update_road_status()
		"Demolish":
			pending_road_preview = RoadPlanner.demolish_preview(region, link_id)
			map_view.set_road_preview(-1, PackedVector2Array(), pending_road_preview)
			_update_road_status()
		_:
			_update_road_status()


func _on_road_empty_clicked(world_position: Vector2) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_road_empty_clicked").bind(world_position))
		return
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name in ["Growth corridor", "Rail corridor", "Station site"]:
		_on_planning_point(world_position)
		return
	if tool_name == "Junction":
		var result: Dictionary = RoadPlanner.add_junction(region, world_position)
		road_status_label.text = "Junction added." if result["ok"] else result["reason"]
		if result["ok"]:
			_rebuild_after_road_change()
	elif (tool_name == "Arterial" or tool_name == "Highway") and road_start_node != -1:
		if _road_draw_mode() == RoadRouteBuilder.STRAIGHT or (_road_draw_mode() == RoadRouteBuilder.CURVED and road_waypoints.size() >= 1):
			road_status_label.text = "Double click empty land to finish the arterial, or choose an existing node."
			return
		var point: Vector2 = RoadPlanner.snap_position(region, road_start_node, road_waypoints, world_position, _road_class(), _road_draw_mode(), road_snap_toggle.button_pressed, road_length_snap_toggle.button_pressed) if road_start_node>=0 and (road_snap_toggle.button_pressed or road_length_snap_toggle.button_pressed) else world_position
		var placing_guide: bool = _road_draw_mode() == RoadRouteBuilder.MULTIPOINT and road_waypoints.size() % 2 == 0
		if placing_guide:
			var curve_start: Vector2 = road_waypoints[-1] if not road_waypoints.is_empty() else _road_start_world()
			if point.distance_to(curve_start) < 0.02:
				road_status_label.text = "Move the curve guide away from its start."
				return
		if _road_draw_mode() == RoadRouteBuilder.MULTIPOINT and road_waypoints.size() % 2 == 1:
			if (RoadPlanner.player_route(region, road_start_node, point, _road_class(), road_waypoints, RoadRouteBuilder.MULTIPOINT) if road_start_node>=0 else RoadRouteBuilder.build_player(region,road_start_position,point,_road_class(),road_waypoints,RoadRouteBuilder.MULTIPOINT)).is_empty():
				road_status_label.text = "This curve cannot be placed here. Adjust its guide or end."
				return
		road_waypoints.append(point)
		road_last_guide_click = placing_guide
		road_last_click_position = world_position
		map_view.set_road_preview(road_start_node, road_waypoints, {},road_start_position)
		_update_road_status()


func _on_road_empty_double_clicked(world_position: Vector2) -> void:
	if road_start_node == -1 or _road_class() != RoadLinkData.ARTERIAL:
		return
	var guides: PackedVector2Array = road_waypoints.duplicate()
	var endpoint: Vector2 = world_position
	if _road_draw_mode() == RoadRouteBuilder.MULTIPOINT:
		if road_last_guide_click and guides.size() % 2 == 1 and road_last_click_position.distance_to(world_position) < 0.02:
			guides.remove_at(guides.size() - 1)
		if guides.size() % 2 == 0 and not guides.is_empty():
			endpoint = guides[-1]
			guides.remove_at(guides.size() - 1)
		if guides.is_empty() or guides.size() % 2 == 0:
			road_status_label.text = "Place a curve guide and end before finishing."
			return
	elif guides.size() < _road_required_guides():
		road_status_label.text = "Add %d curve guide%s first." % [_road_required_guides(), "s" if _road_required_guides() != 1 else ""]
		return
	if endpoint == world_position and road_start_node>=0 and (road_snap_toggle.button_pressed or road_length_snap_toggle.button_pressed):
		endpoint = RoadPlanner.snap_position(region, road_start_node, guides, world_position, _road_class(), _road_draw_mode(), road_snap_toggle.button_pressed, road_length_snap_toggle.button_pressed)
	_request_road_preview(-1,endpoint,{},guides)
	_update_road_status()


func _on_crossing_selected(index: int) -> void:
	if index < 0 or index >= pending_road_preview.get("crossings", []).size():
		return
	crossing_level_selector.select(0 if pending_road_preview["crossings"][index]["above"] else 1)


func _on_crossing_level_selected(index: int) -> void:
	if pending_road_preview.is_empty() or crossing_selector.selected < 0:
		return
	var choices: Dictionary = {}
	for crossing in pending_road_preview["crossings"]:
		choices[crossing["key"]] = crossing["above"]
	var selected_crossing: Dictionary = pending_road_preview["crossings"][crossing_selector.selected]
	choices[selected_crossing["key"]] = index == 0
	_request_road_preview(pending_road_preview["to"],pending_road_preview["end_position"],choices,pending_road_preview["waypoints"])
	_update_road_status()


func _refresh_crossing_controls() -> void:
	var crossings: Array = pending_road_preview.get("crossings", [])
	var selected_index: int = maxi(0, crossing_selector.selected)
	crossing_controls.visible = pending_road_preview.get("kind", "") == "New road" and pending_road_preview.get("ok", false)
	crossing_controls.get_child(0).visible = not crossings.is_empty()
	crossing_selector.visible = not crossings.is_empty()
	crossing_level_selector.visible = not crossings.is_empty()
	crossing_selector.clear()
	for index in range(crossings.size()):
		crossing_selector.add_item("Crossing %d" % (index + 1))
	if not crossings.is_empty():
		selected_index = mini(selected_index, crossings.size() - 1)
		crossing_selector.select(selected_index)
		_on_crossing_selected(selected_index)
	var impact: Dictionary = pending_road_preview.get("land_impact", {})
	road_impact_label.text = "Land %.1f ha  •  Construction $%s  •  Structures $%s  •  Acquisition $%s  •  Demolition/site $%s  •  Local streets $%s" % [
		float(impact.get("land_ha", 0.0)), _format_count(int(pending_road_preview.get("construction_cost", 0))),
		_format_count(int(pending_road_preview.get("structure_cost", 0)) + int(pending_road_preview.get("terrain_impact",{}).get("cost",0)) + int(impact.get("local_bridge_cost", 0))), _format_count(int(impact.get("land_cost", 0))),
		_format_count(int(impact.get("home_cost", 0)) + int(impact.get("job_cost", 0)) + int(impact.get("site_cost", 0))),
		_format_count(int(impact.get("street_cost", 0)))]


func _on_road_build_pressed() -> void:
	if road_preview_thread!=null or not road_preview_request.is_empty():
		road_status_label.text="Preparing road connection…"
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_on_road_build_pressed"))
		return
	_start_region_edit({"kind":"road","preview":pending_road_preview.duplicate(true),"day_key":_current_day_key()})


func _start_region_edit(request:Dictionary) -> void:
	var worker:=Thread.new()
	var task:=Callable(RoadRebuild,"edit").bind(region,traffic_state,calendar_clock.unix_seconds,flow_profile,request)
	if worker.start(task,Thread.PRIORITY_NORMAL)!=OK:
		road_status_label.text="Could not start construction planning. Please retry."
		return
	road_rebuild_thread=worker
	road_build_button.disabled=true
	discard_road_rebuild=false
	_discard_pending_day()
	road_status_label.text="Preparing construction and road access…"
	if request.kind in ["approval","approvals"]: zoning_status_label.text="Preparing development…"


func _cancel_road_preview() -> void:
	road_preview_serial+=1
	road_preview_request.clear()
	road_start_position=Vector2.INF
	road_start_node = -1
	planning_has_start = false
	if map_view != null:
		map_view.set_planning_preview(Vector2.INF)
	road_waypoints.clear()
	road_last_guide_click = false
	pending_road_preview.clear()
	if crossing_controls != null:
		crossing_controls.visible = false
	if map_view != null:
		map_view.set_road_preview(-1, PackedVector2Array(), {})
	_update_road_status()


func _update_road_status() -> void:
	if road_status_label == null or region == null:
		return
	if road_rebuild_thread!=null:
		road_build_button.disabled=true
		road_status_label.text="Preparing construction and road access…"
		return
	if map_view != null and map_view.map_mode == "Zoning":
		road_status_label.text = zoning_tool_message
		return
	if road_preview_thread!=null or not road_preview_request.is_empty():
		road_build_button.disabled=true
		road_status_label.text="Preparing road connection…"
		return
	var owner_id: int = int(pending_road_preview.get("owner_id", 0))
	road_build_button.disabled = pending_road_preview.is_empty() or not pending_road_preview.get("ok", false) or (not region.dev_mode and region.jurisdictions[owner_id].treasury < float(pending_road_preview.get("cost", 0)))
	if not pending_road_preview.is_empty():
		if not pending_road_preview.get("ok", false):
			road_status_label.text = pending_road_preview["reason"]
			return
		if pending_road_preview.get("kind", "") == RoadPlanner.DEMOLISH:
			road_status_label.text = "Remove %.1f km %s  •  No refund  •  Save $%s/day  •  %d road group%s after" % [
				pending_road_preview["length_km"], pending_road_preview["road_class"], _format_count(roundi(pending_road_preview["upkeep_saved"])), pending_road_preview["components_after"], "s" if pending_road_preview["components_after"] != 1 else ""]
			return
		pending_road_preview["open_day_key"] = _current_day_key() + int(pending_road_preview["days"])
		var opening: Dictionary = Time.get_datetime_dict_from_unix_time(int(pending_road_preview["open_day_key"]) * 86400)
		var funding_text: String = "Dev Mode funds" if region.dev_mode else "%s pays" % region.jurisdictions[owner_id].name
		road_status_label.text = "$%s  •  %s  •  Opens %d/%d/%d  •  %d days%s" % [
			_format_count(pending_road_preview["cost"]), funding_text, opening["year"], opening["month"], opening["day"], pending_road_preview["days"], "  •  Insufficient funds" if road_build_button.disabled else ""]
		var terrain_impact: Dictionary = pending_road_preview.get("terrain_impact", {})
		if float(terrain_impact.get("bridge_km", 0.0)) > 0.0:
			road_status_label.text += "  •  %.1f km bridge" % float(terrain_impact["bridge_km"])
		if float(terrain_impact.get("tunnel_km", 0.0)) > 0.0:
			road_status_label.text += "  •  %.1f km tunnel" % float(terrain_impact["tunnel_km"])
		if float(terrain_impact.get("earthwork_km", 0.0)) > 0.0:
			road_status_label.text += "  •  %.1f km grading" % float(terrain_impact["earthwork_km"])
	elif road_start_node != -1:
		if _road_draw_mode() == RoadRouteBuilder.MULTIPOINT:
			if _road_class() == RoadLinkData.HIGHWAY:
				road_status_label.text = "Click a curve guide, then its end. Repeat to continue; choose an interchange to finish. Esc cancels." if road_waypoints.size() % 2 == 0 else "Click the curve end to lock it, or choose an interchange to finish. Esc cancels."
			else:
				road_status_label.text = "Click a curve guide, then its end. Repeat to continue; double click an end to finish. Esc cancels." if road_waypoints.size() % 2 == 0 else "Click the curve end to lock it, or double click there to finish. Esc cancels."
		elif _road_draw_mode() == RoadRouteBuilder.CURVED:
			road_status_label.text = "Click a curve guide, then choose an interchange to finish. Esc cancels." if _road_class() == RoadLinkData.HIGHWAY else "Click a curve guide, then choose a node or double click empty land to finish. Esc cancels."
		else:
			road_status_label.text = "Choose an interchange to finish. Esc cancels." if _road_class() == RoadLinkData.HIGHWAY else "Choose a road node, or double click empty land to finish. Esc cancels."
	elif road_tool_selector.get_item_text(road_tool_selector.selected) == "Demolish":
		road_status_label.text = "Click an open road to preview demolition."
	elif road_tool_selector.get_item_text(road_tool_selector.selected) in ["Growth corridor", "Rail corridor"]:
		road_status_label.text = "Choose the other end of the planning corridor. Esc cancels." if planning_has_start else "Click the first corridor point. This guide shapes future development suggestions."
	elif road_tool_selector.get_item_text(road_tool_selector.selected) == "Station site":
		road_status_label.text = "Click a station site. Nearby districts receive higher growth priority."
	else:
		road_status_label.text = region.road_project_notice if not region.road_project_notice.is_empty() else "Draw between roads or nodes  •  Connections are included in the preview"


func _road_start_world() -> Vector2:
	return region.road_nodes[road_start_node].position_km if road_start_node>=0 else road_start_position


func _request_road_preview(to:int,end:Vector2,choices:Dictionary={},guides:PackedVector2Array=PackedVector2Array()) -> void:
	road_preview_serial+=1
	road_preview_request={"from":road_start_node if road_start_node>=0 else -1,"to":to,"road_class":_road_class(),"waypoints":road_waypoints.duplicate() if guides.is_empty() else guides.duplicate(),"day_key":_current_day_key(),"draw_mode":_road_draw_mode(),"end_position":end,"crossing_choices":choices.duplicate(),"start_position":_road_start_world()}
	_start_road_preview()
	_update_road_status()


func _start_road_preview() -> void:
	if road_preview_thread!=null or road_preview_request.is_empty(): return
	road_preview_job=RoadPreviewJob.new()
	road_preview_job.source=region
	road_preview_job.request=road_preview_request
	road_preview_job.serial=road_preview_serial
	road_preview_request={}
	var worker:=Thread.new()
	if worker.start(road_preview_job.run,Thread.PRIORITY_NORMAL)==OK:
		road_preview_thread=worker
	else:
		pending_road_preview={"ok":false,"reason":"Could not prepare road preview. Try the endpoint again."}


func _poll_road_preview() -> void:
	if road_preview_thread==null: return
	if road_preview_thread.is_alive(): return
	var result:Dictionary=road_preview_thread.wait_to_finish()
	road_preview_thread=null
	if result.get("serial",-1)==road_preview_serial and region!=null:
		if result.seed==region.generation_seed and result.revision==region.road_geometry_revision:
			pending_road_preview=result.preview
		else:
			pending_road_preview={"ok":false,"reason":"Road network changed. Choose the endpoint again to refresh its preview."}
		map_view.set_road_preview(road_start_node,road_waypoints,pending_road_preview,road_start_position)
		_refresh_crossing_controls()
		_update_road_status()
	_start_road_preview()
	_update_road_status()


func _rebuild_after_road_change(changed_city_ids: Array[int] = [], new_district_only: bool = false) -> void:
	_discard_pending_day()
	map_view.set_hour_carry_summary({})
	if region.is_large_scale:
		var worker := Thread.new()
		var task := Callable(RoadRebuild, "build").bind(region, traffic_state, calendar_clock.unix_seconds, changed_city_ids, flow_profile, new_district_only)
		if worker.start(task, Thread.PRIORITY_NORMAL) == OK:
			road_rebuild_thread = worker
			discard_road_rebuild = false
			map_view.set_traffic_profile(null)
			map_view.set_recorded_bin(0, 0)
			road_status_label.text = "Recalculating road access and trips…"
			return
		push_warning("Could not start road rebuild worker; calculating on the main thread.")
	var previous_state = traffic_state
	DevelopmentPlanner.refresh_candidates(region, changed_city_ids)
	region.city_od_candidates.clear()
	AccessibilityCalculator.recalculate(region)
	flow_profile = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow_profile, region.generation_seed, calendar_clock.unix_seconds, CalendarClock.is_weekend_unix(calendar_clock.unix_seconds))
	traffic_state = MultiScaleTraffic.new_day(region, flow_profile, calendar_clock.unix_seconds, previous_state)
	traffic_profile = traffic_state.profile
	map_view.set_flow_profile(flow_profile)
	map_view.set_traffic_profile(traffic_profile)
	flow_timeline.set_profile(flow_profile)
	next_day_profile = null
	map_view.set_next_day_profile(null)
	flow_timeline.set_next_day_profile(null)
	_refresh_region_summary()
	_refresh_inspector(false)
	map_view.queue_redraw()


func _poll_road_rebuild() -> void:
	if road_rebuild_thread == null or road_rebuild_thread.is_alive():
		return
	var result: Dictionary = road_rebuild_thread.wait_to_finish()
	road_rebuild_thread = null
	if discard_road_rebuild:
		discard_road_rebuild = false
		return
	if result.get("edit_failed",false):
		_update_road_status()
		road_status_label.text=result.reason
		if result.edit_kind in ["approval","approvals"]: zoning_status_label.text=result.reason
		return
	if result.is_empty() or not result["errors"].is_empty():
		push_error("Road recalculation failed.")
		return
	var publish_started:=Time.get_ticks_usec()
	last_road_rebuild_stages_us=result.get("stages_us",{})
	var old_data: Dictionary = {"region": region, "flow": flow_profile, "traffic_state": traffic_state, "traffic_profile": traffic_profile}
	region = result["region"]
	region.dev_mode = dev_mode_enabled
	flow_profile = result["flow"]
	traffic_state = result["traffic_state"]
	traffic_profile = traffic_state.profile
	map_view.region = region
	if result.get("edit_kind","")=="road":
		_cancel_road_preview()
		if result.edit_outcome.has("components_after"):
			selected_road_link_id=-1
			map_view.set_selected_road_link(-1)
	if result.get("edit_kind","")=="approval": zoning_status_label.text="Development updated."
	if result.get("edit_kind","")=="approvals":
		zoning_tool_message="%d projects approved. %s"%[result.edit_outcome.approved,result.edit_outcome.reason]
		zoning_status_label.text=zoning_tool_message
	map_view.set_hour_carry_summary({})
	map_view.set_flow_profile(flow_profile)
	map_view.set_traffic_profile(traffic_profile)
	flow_timeline.set_profile(flow_profile)
	next_day_profile = null
	map_view.set_next_day_profile(null)
	flow_timeline.set_next_day_profile(null)
	_retire_simulation_data(old_data)
	_refresh_region_summary()
	_refresh_inspector(false)
	_update_road_status()
	_refresh_toll_controls()
	if result.get("edit_kind","")=="road":
		if result.edit_outcome.has("components_after"):
			road_status_label.text="Road demolished. %d neighborhood road groups remain."%result.edit_outcome.components_after
		elif result.edit_outcome.has("project"):
			var project=result.edit_outcome.project
			road_status_label.text="%s funded. Opens in %d days."%[project.kind,project.days_remaining(_current_day_key())]
	map_view.queue_redraw()
	last_road_rebuild_publish_us=Time.get_ticks_usec()-publish_started


func _refresh_inspector(reset_scroll: bool = true) -> void:
	_refresh_review_queue()
	if not selected_candidate_key.is_empty():
		if selected_candidate_id < 0 or selected_candidate_id >= region.development_candidates.size() or region.development_candidates[selected_candidate_id]["key"] != selected_candidate_key:
			selected_candidate_id = int(region.development_candidate_keys.get(selected_candidate_key, -1))
			map_view.set_selected_candidate(selected_candidate_id)
			if selected_candidate_id < 0:
				selected_candidate_key = ""
	if selected_candidate_id >= 0 and map_view.map_mode == "Zoning":
		_show_candidate_inspector(reset_scroll)
	elif map_view.selected_local_street.x >= 0 and map_view.map_mode == "Roads":
		growth_policy_controls.visible = false
		_show_local_street_inspector(reset_scroll)
	elif selected_road_link_id >= 0 and map_mode_selector.selected == 0:
		growth_policy_controls.visible = false
		_show_road_inspector(selected_road_link_id)
	else:
		_show_jurisdiction_inspector(reset_scroll)


func _refresh_review_queue() -> void:
	if review_queue == null:
		return
	var showing: bool = region != null and map_view.map_mode == "Zoning"
	review_queue_label.visible = showing
	review_queue.visible = showing
	review_approve_button.visible = showing
	if not showing:
		return
	var selected_keys: Dictionary = {}
	for index in review_queue.get_selected_items():
		if index < review_queue_keys.size():
			selected_keys[review_queue_keys[index]] = true
	review_queue.clear()
	review_queue_keys.clear()
	var city_filter: int = region.city_jurisdiction_ids.find(selected_jurisdiction_id)
	review_queue_label.text = "GROWTH REVIEW · %s" % ("city projects" if city_filter >= 0 else "top 80 state projects; select a city for more")
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or not candidate.has("urban_sector"):
			continue
		if city_filter >= 0 and int(candidate["city_id"]) != city_filter:
			continue
		if city_filter < 0 and review_queue_keys.size() >= 80:
			break
		var key: String = candidate["key"]
		var city_name: String = region.cities[int(candidate["city_id"])]["name"]
		review_queue.add_item("%s · %.0f ha · $%s" % [city_name, StateGeography.polygon_area(candidate["polygon"]) * 100.0, _format_count(candidate["layout"].total_cost())])
		review_queue_keys.append(key)
		if selected_keys.has(key):
			review_queue.select(review_queue_keys.size() - 1, false)
	review_approve_button.disabled = review_queue_keys.is_empty()


func _approve_review_selection() -> void:
	if region == null:
		return
	var keys: Array[String] = []
	for index in review_queue.get_selected_items():
		if index < review_queue_keys.size():
			keys.append(review_queue_keys[index])
	if keys.is_empty():
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_approve_review_keys").bind(keys))
		return
	_approve_review_keys(keys)


func _approve_review_keys(keys: Array[String]) -> void:
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_approve_review_keys").bind(keys))
		return
	_start_region_edit({"kind":"approvals","keys":keys.duplicate()})


func _refresh_toll_controls() -> void:
	if toll_label == null:
		return
	var selected_link = null
	if region != null:
		for link in region.road_links:
			if link.id == selected_road_link_id:
				selected_link = link
				break
	toll_controls.visible = selected_link != null
	if region != null and state_tax_controls != null:
		scope_breadcrumb.visible = selected_link == null
		fiscal_label.visible = selected_link == null
		state_tax_controls.visible = selected_link == null and region.jurisdictions[selected_jurisdiction_id].kind == "State"
		jurisdiction_policy_controls.visible = selected_link == null and not policy_options.is_empty()
	suppress_toll_input = true
	toll_forward_input.editable = selected_link != null
	toll_reverse_input.editable = selected_link != null
	if selected_link == null:
		toll_label.text = "Select a road to set directional tolls"
		toll_forward_input.value = 0
		toll_reverse_input.value = 0
	else:
		toll_label.text = "Road %d  •  %s" % [selected_link.id, region.jurisdictions[selected_link.owner_jurisdiction_id].name]
		toll_forward_input.value = selected_link.toll_forward
		toll_reverse_input.value = selected_link.toll_reverse
	suppress_toll_input = false


func _on_toll_changed(property_name: String, value: float) -> void:
	if suppress_toll_input or selected_road_link_id < 0 or region == null:
		return
	if _region_snapshot_busy():
		deferred_region_edits.append(Callable(self, "_apply_specific_toll").bind(selected_road_link_id, property_name, value))
		return
	_apply_specific_toll(selected_road_link_id, property_name, value)


func _apply_specific_toll(link_id: int, property_name: String, value: float) -> void:
	_discard_pending_day()
	FiscalCalculator.queue_toll(region, link_id, property_name, value, calendar_clock.unix_seconds)
	_invalidate_traffic_forecast()
	road_status_label.text = "Toll change begins at the next 15-minute checkpoint."
	_show_road_inspector(link_id)


func _show_road_inspector(link_id: int) -> void:
	var index: int = -1
	for link_index in range(region.road_links.size()):
		if region.road_links[link_index].id == link_id:
			index = link_index
			break
	if index < 0:
		return
	var link = region.road_links[index]
	var road_metrics: Dictionary = map_view.get_road_traffic_metrics(index, link)
	if road_metrics.is_empty():
		inspector.text = "[font_size=22][b]%s %d[/b][/font_size]\n\nLength: %.1f km\nLanes: %d each direction\nOwner: %s\nToll: $%.2f forward / $%.2f reverse\n\n[color=#78c8dc]Directional road traffic for this time is still uncalculated.[/color]\nThe chart shows scheduled trip demand." % [
			link.road_class, link.id, link.length_km, link.lanes_per_direction,
			region.jurisdictions[link.owner_jurisdiction_id].name, link.toll_forward, link.toll_reverse]
		return
	var volume: Vector2 = road_metrics["demand"]
	var served: Vector2 = road_metrics["served"]
	var queue: Vector2 = road_metrics["queue"]
	var time: Vector2 = road_metrics["time"]
	var sample_label: String = road_metrics["label"]
	var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
	var project_text := ""
	for project in region.road_projects:
		if project.target_link_id == link_id:
			project_text += "\n%s: %d days left" % [project.kind, project.days_remaining(_current_day_key())]
	inspector.text = "[font_size=22][b]%s %d[/b][/font_size]\n\nLength: %.1f km\nLanes: %d each direction\nCapacity: %s vehicles/h each way\nOwner: %s\nToll: $%.2f forward / $%.2f reverse\n\n[color=#78c8dc][b]%s[/b][/color]\nForward demand: %s vehicles/h (%.0f%%)\nReverse demand: %s vehicles/h (%.0f%%)\nForward flow: %s vehicles/h\nReverse flow: %s vehicles/h\nForward queue: %s vehicles\nReverse queue: %s vehicles\nTime: %.1f / %.1f min\nFree flow: %.1f min\n\nUpkeep: $%s/day%s" % [
		link.road_class, link.id, link.length_km, link.lanes_per_direction, _format_count(roundi(capacity)),
		region.jurisdictions[link.owner_jurisdiction_id].name, link.toll_forward, link.toll_reverse,
		sample_label,
		_format_count(roundi(volume.x)), 100.0 * volume.x / capacity, _format_count(roundi(volume.y)), 100.0 * volume.y / capacity,
		_format_count(roundi(served.x)), _format_count(roundi(served.y)),
		_format_count(roundi(queue.x)), _format_count(roundi(queue.y)),
		time.x, time.y, link.length_km * 60.0 / RoadGraph.free_speed_kmh(link.road_class),
		_format_count(roundi(link.length_km * link.lanes_per_direction * RoadLinkData.upkeep(link.road_class))), project_text]


func _format_count(value: int) -> String:
	var digits := str(value)
	var formatted := ""
	while digits.length() > 3:
		formatted = "," + digits.substr(digits.length() - 3, 3) + formatted
		digits = digits.substr(0, digits.length() - 3)
	return digits + formatted
