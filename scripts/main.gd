extends Control

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
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
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")

const DEFAULT_SEED = 1729

var region
var flow_profile
var next_day_profile
var traffic_profile
var next_traffic_profile
var last_dynamics_day_key: int = -1
var flow_purpose: String = FlowProfile.ALL
var calendar_clock
var playing: bool = true
var speed_multiplier: float = 1.0
var map_view
var flow_timeline
var seed_input: SpinBox
var summary_label: Label
var dynamics_label: Label
var tax_input: SpinBox
var calendar_label: Label
var hourly_trip_label: Label
var flow_detail_label: Label
var play_button: Button
var speed_selector: OptionButton
var purpose_selector: OptionButton
var inspector: RichTextLabel
var map_mode_selector: OptionButton
var road_tool_selector: OptionButton
var road_build_button: Button
var road_status_label: Label
var pending_road_preview: Dictionary = {}
var road_start_node: int = -1
var road_waypoints: PackedVector2Array = PackedVector2Array()
var selected_road_link_id: int = -1


func _ready() -> void:
	get_window().min_size = Vector2i(1024, 700)
	_build_interface()
	_generate_region(DEFAULT_SEED)


func _process(delta: float) -> void:
	if not playing or calendar_clock == null:
		return
	calendar_clock.advance_simulation_seconds(delta * 3600.0 * speed_multiplier)
	_sync_clock_view()


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
			_on_speed_selected(0)
		KEY_2, KEY_KP_2:
			_on_speed_selected(1)
		KEY_3, KEY_KP_3:
			_on_speed_selected(2)
		KEY_4, KEY_KP_4:
			_on_speed_selected(3)
		KEY_5, KEY_KP_5:
			_on_speed_selected(4)
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
	seed_label.text = "Region seed"
	seed_label.add_theme_color_override("font_color", Color("b8c9d6"))
	header.add_child(seed_label)
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 9999999
	seed_input.step = 1
	seed_input.rounded = true
	seed_input.value = DEFAULT_SEED
	seed_input.custom_minimum_size = Vector2(116, 0)
	header.add_child(seed_input)
	var generate_button := Button.new()
	generate_button.text = "Generate"
	generate_button.pressed.connect(_on_generate_pressed)
	header.add_child(generate_button)
	var quit_button := Button.new()
	quit_button.text = "Quit"
	quit_button.tooltip_text = "Close Transitocracy"
	quit_button.pressed.connect(_on_quit_pressed)
	header.add_child(quit_button)

	summary_label = Label.new()
	summary_label.add_theme_font_size_override("font_size", 14)
	summary_label.add_theme_color_override("font_color", Color("b5cad9"))
	layout.add_child(summary_label)
	var policy_controls := HBoxContainer.new()
	policy_controls.add_theme_constant_override("separation", 10)
	layout.add_child(policy_controls)
	var tax_label := Label.new()
	tax_label.text = "Income tax"
	tax_label.add_theme_color_override("font_color", Color("b8c9d6"))
	policy_controls.add_child(tax_label)
	tax_input = SpinBox.new()
	tax_input.min_value = 0
	tax_input.max_value = 40
	tax_input.step = 1
	tax_input.suffix = "%"
	tax_input.value = 10
	tax_input.custom_minimum_size = Vector2(94, 0)
	tax_input.tooltip_text = "Regional income tax; changes household finances and migration each day"
	tax_input.value_changed.connect(_on_tax_changed)
	policy_controls.add_child(tax_input)
	dynamics_label = Label.new()
	dynamics_label.add_theme_color_override("font_color", Color("93b9ac"))
	policy_controls.add_child(dynamics_label)

	var clock_controls := HBoxContainer.new()
	clock_controls.add_theme_constant_override("separation", 12)
	layout.add_child(clock_controls)
	play_button = Button.new()
	play_button.text = "Pause"
	play_button.tooltip_text = "Space: play or pause"
	play_button.pressed.connect(_on_play_pressed)
	clock_controls.add_child(play_button)
	speed_selector = OptionButton.new()
	speed_selector.add_item("1×")
	speed_selector.add_item("4×")
	speed_selector.add_item("16×")
	speed_selector.add_item("64×")
	speed_selector.add_item("256×")
	speed_selector.selected = 0
	speed_selector.tooltip_text = "1 / 2 / 3 / 4 / 5: choose simulation speed"
	speed_selector.item_selected.connect(_on_speed_selected)
	clock_controls.add_child(speed_selector)
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
	map_mode_selector.selected = 0
	map_mode_selector.item_selected.connect(_on_map_mode_selected)
	road_controls.add_child(map_mode_selector)
	road_tool_selector = OptionButton.new()
	for tool_name in ["Inspect", "Arterial", "Highway", "Junction", "Interchange", "Widen", "Demolish"]:
		road_tool_selector.add_item(tool_name)
	road_tool_selector.item_selected.connect(_on_road_tool_selected)
	road_controls.add_child(road_tool_selector)
	road_build_button = Button.new()
	road_build_button.text = "Build"
	road_build_button.disabled = true
	road_build_button.pressed.connect(_on_road_build_pressed)
	road_controls.add_child(road_build_button)
	var cancel_road_button := Button.new()
	cancel_road_button.text = "Cancel"
	cancel_road_button.pressed.connect(_cancel_road_preview)
	road_controls.add_child(cancel_road_button)
	road_status_label = Label.new()
	road_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	road_status_label.clip_text = true
	road_status_label.add_theme_color_override("font_color", Color("a9c8d8"))
	road_controls.add_child(road_status_label)

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
	map_view.road_node_clicked.connect(_on_road_node_clicked)
	map_view.road_link_clicked.connect(_on_road_link_clicked)
	map_view.road_empty_clicked.connect(_on_road_empty_clicked)
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
	flow_detail_label = Label.new()
	flow_detail_label.add_theme_font_size_override("font_size", 14)
	flow_detail_label.add_theme_color_override("font_color", Color("f5b67c"))
	flow_detail_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	flow_detail_label.custom_minimum_size.y = 58
	inspector_layout.add_child(flow_detail_label)
	inspector_layout.add_child(HSeparator.new())
	inspector = RichTextLabel.new()
	inspector.bbcode_enabled = true
	inspector.selection_enabled = true
	inspector.autowrap_mode = TextServer.AUTOWRAP_OFF
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
	_generate_region(int(seed_input.value))


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_play_pressed() -> void:
	playing = not playing
	play_button.text = "Pause" if playing else "Play"


func _on_speed_selected(index: int) -> void:
	var speeds := [1.0, 4.0, 16.0, 64.0, 256.0]
	if speed_selector.selected != index:
		speed_selector.select(index)
	speed_multiplier = speeds[index]


func _on_purpose_selected(index: int) -> void:
	flow_purpose = [FlowProfile.ALL, FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL][index]
	map_view.set_purpose(flow_purpose)
	flow_timeline.set_purpose(flow_purpose)
	_update_flow_detail()


func _on_time_selected(hour: int, minute: int) -> void:
	calendar_clock.set_time(hour, minute)
	playing = false
	play_button.text = "Play"
	_sync_clock_view()


func _on_tax_changed(value: float) -> void:
	if region == null:
		return
	region.income_tax_rate = value / 100.0
	NeighborhoodDynamics.refresh_desirability(region)
	_refresh_region_summary()
	_on_neighborhood_selected(map_view.selected_id, false)


func _generate_region(seed_value: int) -> void:
	region = RegionGenerator.generate_region(seed_value)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	region.income_tax_rate = tax_input.value / 100.0
	NeighborhoodDynamics.initialize(region)
	region.daily_road_upkeep = RoadPlanner.calculate_upkeep(region)
	calendar_clock = CalendarClock.new()
	last_dynamics_day_key = floori(float(calendar_clock.unix_seconds) / 86400.0)
	var day_result: Dictionary = RoadTrafficCalculator.build_day(region, calendar_clock.unix_seconds)
	flow_profile = day_result["flow"]
	traffic_profile = day_result["traffic"]
	NeighborhoodDynamics.refresh_desirability(region)
	var errors: PackedStringArray = region.validation_errors()
	if not errors.is_empty():
		push_error("Invalid generated region: " + "; ".join(errors))
		inspector.text = "[color=#ff8c8c]Region generation failed validation.[/color]"
		return
	next_day_profile = null
	next_traffic_profile = null
	road_start_node = -1
	road_waypoints.clear()
	pending_road_preview.clear()
	selected_road_link_id = -1
	map_view.set_region(region)
	map_view.set_map_mode("Roads")
	map_mode_selector.select(0)
	road_tool_selector.select(0)
	road_build_button.text = "Build"
	map_view.set_road_tool("Inspect")
	map_view.set_traffic_profile(traffic_profile)
	map_view.set_flow_profile(flow_profile)
	flow_timeline.set_profile(flow_profile)
	_ensure_day_profiles()
	_update_road_status()
	map_view.set_purpose(flow_purpose)
	flow_timeline.set_purpose(flow_purpose)
	_refresh_region_summary()
	_on_neighborhood_selected(0)
	_sync_clock_view()
	playing = true
	play_button.text = "Pause"


func _refresh_region_summary() -> void:
	var totals: Dictionary = region.get_region_totals()
	summary_label.text = "%s  ›  %s  ›  %s     •     %d cities     •     %d neighborhoods     •     %s people     •     %s jobs" % [
		region.state_name, region.region_name, region.county_name,
		region.cities.size(), region.neighborhoods.size(),
		_format_count(totals["population"]), _format_count(totals["jobs"]),
	]
	dynamics_label.text = "Today: %+d households / %+d people  •  Treasury $%s  •  Net $%s/day" % [
		region.last_household_change, region.last_population_change, _format_count(roundi(region.treasury)), _format_count(roundi(region.daily_tax_revenue - region.daily_road_upkeep))
	]


func _ensure_day_profiles() -> void:
	var day_key := floori(float(calendar_clock.unix_seconds) / 86400.0)
	var dynamics_advanced := false
	if day_key > last_dynamics_day_key:
		for crossed_day in range(last_dynamics_day_key + 1, day_key + 1):
			var prior_profile = flow_profile
			var prior_traffic_profile = traffic_profile
			var roads_changed: bool = RoadPlanner.advance_day(region, crossed_day)
			if roads_changed:
				AccessibilityCalculator.recalculate(region)
			NeighborhoodDynamics.advance_day(region)
			var day_result: Dictionary = RoadTrafficCalculator.build_day(region, crossed_day * 86400, prior_profile, roads_changed, prior_traffic_profile)
			flow_profile = day_result["flow"]
			traffic_profile = day_result["traffic"]
			NeighborhoodDynamics.refresh_desirability(region)
		last_dynamics_day_key = day_key
		next_day_profile = null
		next_traffic_profile = null
		dynamics_advanced = true
	if dynamics_advanced:
		map_view.set_flow_profile(flow_profile)
		map_view.set_traffic_profile(traffic_profile)
		flow_timeline.set_profile(flow_profile)
	if next_day_profile == null or next_day_profile.active_day_key != day_key + 1:
		var next_day_seconds: int = (day_key + 1) * 86400
		next_day_profile = TripFlowCalculator.copy_for_day(flow_profile, region.generation_seed, next_day_seconds, CalendarClock.is_weekend_unix(next_day_seconds))
		next_traffic_profile = RoadTrafficCalculator.assign_day(region, next_day_profile, 1)
		map_view.set_next_day_profile(next_day_profile)
		map_view.set_next_traffic_profile(next_traffic_profile)
		flow_timeline.set_next_day_profile(next_day_profile)
	if dynamics_advanced:
		_refresh_region_summary()
		_refresh_inspector(false)
		_update_road_status()


func _sync_clock_view() -> void:
	_ensure_day_profiles()
	var hour: int = calendar_clock.get_hour()
	var fraction: float = calendar_clock.get_hour_fraction()
	var weekend: bool = calendar_clock.is_weekend()
	calendar_label.text = calendar_clock.get_display_text()
	hourly_trip_label.text = "%s trips/h  •  %s work  •  %s commercial  •  %s social" % [
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.ALL, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.WORK, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.COMMERCIAL, next_day_profile))),
		_format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, FlowProfile.SOCIAL, next_day_profile))),
	]
	flow_timeline.set_time(hour, fraction)
	flow_timeline.set_weekend(weekend)
	map_view.set_time(hour, fraction)
	_update_flow_detail()
	if selected_road_link_id >= 0 and map_mode_selector.selected == 0:
		_show_road_inspector(selected_road_link_id)


func _update_flow_detail() -> void:
	if flow_profile == null or calendar_clock == null:
		return
	var hour: int = calendar_clock.get_hour()
	var minute: int = calendar_clock.get_minute()
	var fraction: float = calendar_clock.get_hour_fraction()
	var neighborhood_id: int = map_view.selected_id
	if neighborhood_id < 0:
		flow_detail_label.text = "%02d:%02d  •  %s\nRegion: %s trips/h" % [hour, minute, flow_purpose, _format_count(roundi(flow_profile.get_interpolated_hourly_total(hour, fraction, flow_purpose, next_day_profile)))]
		return
	var matrix: Array = flow_profile.get_interpolated_hour_matrix(hour, fraction, flow_purpose, next_day_profile)
	var outgoing := 0.0
	var incoming := 0.0
	for trips in matrix[neighborhood_id]:
		outgoing += trips
	for row in matrix:
		incoming += row[neighborhood_id]
	var local_trips: float = matrix[neighborhood_id][neighborhood_id]
	flow_detail_label.text = "%02d:%02d  •  %s\nOut: %s/h     In: %s/h\nLocal: %s/h" % [
		hour, minute, flow_purpose, _format_count(roundi(outgoing)), _format_count(roundi(incoming)), _format_count(roundi(local_trips))
	]


func _on_neighborhood_selected(neighborhood_id: int, reset_scroll: bool = true) -> void:
	selected_road_link_id = -1
	map_view.set_selected_road_link(-1)
	map_view.set_selected(neighborhood_id)
	_update_flow_detail()
	if neighborhood_id < 0:
		inspector.text = "[font_size=21][b]Neighborhood inspector[/b][/font_size]\n\nSelect a neighborhood to inspect its statistics."
		return
	var neighborhood = region.neighborhoods[neighborhood_id]
	var city_totals: Dictionary = region.get_city_totals(neighborhood.city_id)
	var region_totals: Dictionary = region.get_region_totals()
	var access: float = region.accessibility[neighborhood_id]
	var share_of_jobs: float = 100.0 * access / maxf(1.0, float(region_totals["jobs"]))
	var text_lines := PackedStringArray()
	text_lines.append("[font_size=22][b]%s[/b][/font_size]" % neighborhood.name)
	text_lines.append("[color=#91abc0]%s City  •  %.0f ha[/color]" % [region.get_city_name(neighborhood.city_id), neighborhood.land_area_ha])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]NEIGHBORHOOD[/b][/color]")
	text_lines.append("Population: %s" % _format_count(neighborhood.population))
	text_lines.append("Households: %s / %s homes" % [_format_count(neighborhood.households), _format_count(neighborhood.housing_capacity)])
	text_lines.append("Today: %+d households" % neighborhood.last_household_change)
	text_lines.append("People: %+d today" % neighborhood.last_population_change)
	text_lines.append("Jobs: %s / %s capacity" % [_format_count(neighborhood.jobs), _format_count(neighborhood.job_capacity)])
	text_lines.append("Retail jobs: %s" % _format_count(roundi(neighborhood.shopping_attraction)))
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]HOUSING & WEALTH[/b][/color]")
	text_lines.append("Rent: $%s/mo" % _format_count(neighborhood.monthly_rent))
	text_lines.append("Income: $%s/mo" % _format_count(neighborhood.average_monthly_income))
	text_lines.append("After tax: $%s/mo" % _format_count(roundi(float(neighborhood.average_monthly_income) * (1.0 - region.income_tax_rate))))
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
	for id in range(region.neighborhoods.size()):
		travel_order.append(id)
	travel_order.sort_custom(func(a: int, b: int) -> bool: return region.travel_times[neighborhood_id][a] < region.travel_times[neighborhood_id][b])
	for id in travel_order:
		if region.travel_times[neighborhood_id][id] >= 1000000.0:
			text_lines.append("%s: no road route" % region.neighborhoods[id].name)
		else:
			text_lines.append("%s: %.1f min" % [region.neighborhoods[id].name, region.travel_times[neighborhood_id][id]])
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


func _on_map_mode_selected(index: int) -> void:
	map_view.set_map_mode("Roads" if index == 0 else "Trips")
	_cancel_road_preview()
	_refresh_inspector(false)


func _on_road_tool_selected(index: int) -> void:
	map_view.set_road_tool(road_tool_selector.get_item_text(index))
	road_build_button.text = "Demolish" if road_tool_selector.get_item_text(index) == "Demolish" else "Build"
	_cancel_road_preview()
	_update_road_status()


func _on_road_node_clicked(node_id: int) -> void:
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	match tool_name:
		"Arterial", "Highway":
			if road_start_node < 0 or not pending_road_preview.is_empty():
				road_start_node = node_id
				road_waypoints.clear()
				pending_road_preview.clear()
				map_view.set_road_preview(road_start_node, road_waypoints, {})
			else:
				pending_road_preview = RoadPlanner.link_preview(region, road_start_node, node_id, RoadLinkData.HIGHWAY if tool_name == "Highway" else RoadLinkData.ARTERIAL, road_waypoints, _current_day_key())
				map_view.set_road_preview(road_start_node, road_waypoints, pending_road_preview)
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
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name != "Junction":
		selected_road_link_id = link_id
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
	var tool_name: String = road_tool_selector.get_item_text(road_tool_selector.selected)
	if tool_name == "Junction":
		var result: Dictionary = RoadPlanner.add_junction(region, world_position)
		road_status_label.text = "Junction added." if result["ok"] else result["reason"]
		if result["ok"]:
			_rebuild_after_road_change()
	elif (tool_name == "Arterial" or tool_name == "Highway") and road_start_node >= 0:
		road_waypoints.append(world_position)
		map_view.set_road_preview(road_start_node, road_waypoints, {})
		_update_road_status()


func _on_road_build_pressed() -> void:
	if pending_road_preview.get("kind", "") == RoadPlanner.DEMOLISH:
		var result: Dictionary = RoadPlanner.demolish(region, pending_road_preview["target_link_id"])
		if not result["ok"]:
			road_status_label.text = result["reason"]
			return
		selected_road_link_id = -1
		map_view.set_selected_road_link(-1)
		_cancel_road_preview()
		_rebuild_after_road_change()
		road_status_label.text = "Road demolished. %d neighborhood road group%s remain." % [result["components_after"], "s" if result["components_after"] != 1 else ""]
		return
	var result: Dictionary = RoadPlanner.commit(region, pending_road_preview, _current_day_key())
	if not result["ok"]:
		road_status_label.text = result["reason"]
		return
	var project = result["project"]
	_cancel_road_preview()
	map_view.queue_redraw()
	_refresh_region_summary()
	road_status_label.text = "%s funded. Opens in %d days." % [project.kind, project.days_remaining(_current_day_key())]


func _cancel_road_preview() -> void:
	road_start_node = -1
	road_waypoints.clear()
	pending_road_preview.clear()
	if map_view != null:
		map_view.set_road_preview(-1, PackedVector2Array(), {})
	_update_road_status()


func _update_road_status() -> void:
	if road_status_label == null or region == null:
		return
	road_build_button.disabled = pending_road_preview.is_empty() or not pending_road_preview.get("ok", false) or region.treasury < float(pending_road_preview.get("cost", 0))
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
		road_status_label.text = "$%s  •  Opens %d/%d/%d  •  %d days%s" % [
			_format_count(pending_road_preview["cost"]), opening["year"], opening["month"], opening["day"], pending_road_preview["days"], "  •  Insufficient funds" if road_build_button.disabled else ""]
	elif road_start_node >= 0:
		road_status_label.text = "Click another node to finish; click empty map for a waypoint. Esc cancels."
	elif road_tool_selector.get_item_text(road_tool_selector.selected) == "Demolish":
		road_status_label.text = "Click an open road to preview demolition."
	else:
		road_status_label.text = "Draw roads between nodes  •  Junctions connect arterials  •  Highways need interchanges"


func _rebuild_after_road_change() -> void:
	AccessibilityCalculator.recalculate(region)
	var day_result: Dictionary = RoadTrafficCalculator.build_day(region, calendar_clock.unix_seconds, flow_profile)
	flow_profile = day_result["flow"]
	traffic_profile = day_result["traffic"]
	NeighborhoodDynamics.refresh_desirability(region)
	_refresh_region_summary()
	next_day_profile = null
	next_traffic_profile = null
	map_view.set_flow_profile(flow_profile)
	map_view.set_traffic_profile(traffic_profile)
	flow_timeline.set_profile(flow_profile)
	_ensure_day_profiles()
	_refresh_inspector(false)
	map_view.queue_redraw()


func _refresh_inspector(reset_scroll: bool = true) -> void:
	if selected_road_link_id >= 0 and map_mode_selector.selected == 0:
		_show_road_inspector(selected_road_link_id)
	else:
		_on_neighborhood_selected(map_view.selected_id, reset_scroll)


func _show_road_inspector(link_id: int) -> void:
	var index: int = -1
	for link_index in range(region.road_links.size()):
		if region.road_links[link_index].id == link_id:
			index = link_index
			break
	if index < 0:
		return
	var link = region.road_links[index]
	var hour: int = calendar_clock.get_hour()
	var volume: Vector2 = traffic_profile.interpolated_volume(index, hour, calendar_clock.get_hour_fraction(), next_traffic_profile)
	var time: Vector2 = traffic_profile.interpolated_link_time(index, hour, calendar_clock.get_hour_fraction(), next_traffic_profile)
	var capacity: float = (1800.0 if link.road_class == RoadLinkData.HIGHWAY else 900.0) * link.lanes_per_direction
	var project_text := ""
	for project in region.road_projects:
		if project.target_link_id == link_id:
			project_text += "\n%s: %d days left" % [project.kind, project.days_remaining(_current_day_key())]
	inspector.text = "[font_size=22][b]%s %d[/b][/font_size]\n\nLength: %.1f km\nLanes: %d each direction\nCapacity: %s vehicles/h each way\n\n[color=#78c8dc][b]CURRENT HOUR[/b][/color]\nForward: %s vehicles/h (%.0f%%)\nReverse: %s vehicles/h (%.0f%%)\nTime: %.1f / %.1f min\nFree flow: %.1f min\n\nUpkeep: $%s/day%s" % [
		link.road_class, link.id, link.length_km, link.lanes_per_direction, _format_count(roundi(capacity)),
		_format_count(roundi(volume.x)), 100.0 * volume.x / capacity, _format_count(roundi(volume.y)), 100.0 * volume.y / capacity,
		time.x, time.y, link.length_km * 60.0 / (90.0 if link.road_class == RoadLinkData.HIGHWAY else 50.0),
		_format_count(roundi(link.length_km * link.lanes_per_direction * (600.0 if link.road_class == RoadLinkData.HIGHWAY else 200.0))), project_text]


func _format_count(value: int) -> String:
	var digits := str(value)
	var formatted := ""
	while digits.length() > 3:
		formatted = "," + digits.substr(digits.length() - 3, 3) + formatted
		digits = digits.substr(0, digits.length() - 3)
	return digits + formatted
