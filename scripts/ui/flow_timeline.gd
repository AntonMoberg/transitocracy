extends Control

signal time_selected(hour: int, minute: int)

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const LEFT_MARGIN = 24.0
const RIGHT_MARGIN = 24.0
const CURVE_STEPS_PER_HOUR = 12
const WEEK_DAYS = 7

var flow_profile
var next_day_profile
var selected_purpose: String = FlowProfile.ALL
var selected_hour: int = 8
var hour_fraction: float = 0.0
var actual_hour: int = 8
var actual_fraction: float = 0.0
var weekend: bool = false
var week_mode: bool = false
var week_start_day_key: int = -1
var week_clock_seconds: float = 0.0
var week_totals: Dictionary = {}
var selected_week_day_key: int = -1


func _ready() -> void:
	custom_minimum_size = Vector2(0, 112)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Click or drag to inspect a time"
	resized.connect(queue_redraw)


func set_profile(new_profile) -> void:
	flow_profile = new_profile
	queue_redraw()


func set_next_day_profile(new_profile) -> void:
	next_day_profile = new_profile
	queue_redraw()


func set_purpose(purpose: String) -> void:
	selected_purpose = purpose
	if week_mode and selected_week_day_key >= 0:
		_update_week_tooltip()
	queue_redraw()


func set_hour(hour: int) -> void:
	set_time(hour, 0.0)


func set_time(hour: int, fraction: float) -> void:
	selected_hour = clampi(hour, 0, 23)
	hour_fraction = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func set_clock_time(hour: int, fraction: float) -> void:
	actual_hour = clampi(hour, 0, 23)
	actual_fraction = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func set_weekend(value: bool) -> void:
	weekend = value
	queue_redraw()


func set_week_mode(value: bool) -> void:
	if week_mode == value:
		return
	week_mode = value
	selected_week_day_key = -1
	tooltip_text = "Click a day to see its total trips" if value else "Click or drag to inspect a time"
	queue_redraw()


func set_week_window(start_day_key: int, clock_seconds: float, daily_totals: Dictionary) -> void:
	if week_start_day_key != start_day_key:
		selected_week_day_key = -1
	week_start_day_key = start_day_key
	week_clock_seconds = clock_seconds
	week_totals = daily_totals
	if selected_week_day_key >= start_day_key and selected_week_day_key < start_day_key + WEEK_DAYS:
		_update_week_tooltip()
	else:
		tooltip_text = "Click a day to see its total trips"
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("152235"))
	if flow_profile == null:
		return
	if week_mode:
		_draw_week()
		return
	var font := get_theme_default_font()
	draw_string(font, Vector2(LEFT_MARGIN, 16), "WEEKEND FLOW / H" if weekend else "WEEKDAY FLOW / H", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("a9bfd0"))
	var line_color: Color = _purpose_color()
	var line_label: String = "All = Work + Commercial + Social" if selected_purpose == FlowProfile.ALL else selected_purpose
	draw_line(Vector2(160, 12), Vector2(176, 12), line_color, 3.0, true)
	draw_string(font, Vector2(182, 16), line_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("a9bfd0"))
	var chart_width: float = maxf(1.0, size.x - LEFT_MARGIN - RIGHT_MARGIN)
	var slot_width: float = chart_width / 24.0
	var baseline: float = size.y - 22.0
	var chart_height: float = maxf(1.0, baseline - 32.0)
	var actual_x: float = LEFT_MARGIN + (actual_hour + actual_fraction) * slot_width
	draw_rect(Rect2(Vector2(actual_x, 27.0), Vector2(maxf(0.0, size.x - RIGHT_MARGIN - actual_x), baseline - 25.0)), Color(0.50, 0.64, 0.80, 0.08))
	draw_string(font, Vector2(size.x - RIGHT_MARGIN - 185.0, 32.0), "Forecast →", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("9bb3c5"))
	var values: PackedFloat32Array = _hourly_values(selected_purpose)
	var peak: float = 1.0
	for hour in range(25):
		peak = maxf(peak, values[hour])
	draw_string(font, Vector2(size.x - RIGHT_MARGIN - 116.0, 16), "Peak %d/h" % roundi(peak), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("8fa4ba"))
	for fraction in [0.0, 0.5, 1.0]:
		var guide_y: float = baseline - chart_height * fraction
		draw_line(Vector2(LEFT_MARGIN, guide_y), Vector2(size.x - RIGHT_MARGIN, guide_y), Color(0.65, 0.78, 0.89, 0.13), 1.0)
	var points: PackedVector2Array = _curve_points(values, peak, baseline, chart_height, slot_width)
	draw_polyline(points, line_color, 3.0, true)
	draw_line(Vector2(actual_x, 27.0), Vector2(actual_x, baseline + 2.0), Color("f2b678", 0.8), 1.0)
	var marker_x: float = LEFT_MARGIN + (selected_hour + hour_fraction) * slot_width
	draw_line(Vector2(marker_x, 27), Vector2(marker_x, baseline + 2.0), Color(1.0, 1.0, 1.0, 0.78), 2.0)
	for labeled_hour in [0, 6, 12, 18, 24]:
		var x: float = LEFT_MARGIN + labeled_hour * slot_width
		draw_string(font, Vector2(x - 9.0, size.y - 5.0), "%02d" % labeled_hour, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8fa4ba"))


func _draw_week() -> void:
	if week_start_day_key < 0:
		return
	var font := get_theme_default_font()
	var line_color: Color = _purpose_color()
	var line_label: String = "All = Work + Commercial + Social" if selected_purpose == FlowProfile.ALL else selected_purpose
	draw_string(font, Vector2(LEFT_MARGIN, 16), "SEVEN-DAY TRIPS / DAY", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("a9bfd0"))
	draw_line(Vector2(192, 12), Vector2(208, 12), line_color, 3.0, true)
	draw_string(font, Vector2(214, 16), line_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("a9bfd0"))
	var chart_width: float = maxf(1.0, size.x - LEFT_MARGIN - RIGHT_MARGIN)
	var day_width: float = chart_width / float(WEEK_DAYS)
	var baseline: float = size.y - 22.0
	var chart_height: float = maxf(1.0, baseline - 32.0)
	var actual_x: float = LEFT_MARGIN + clampf((week_clock_seconds / 86400.0 - float(week_start_day_key)) / float(WEEK_DAYS), 0.0, 1.0) * chart_width
	draw_rect(Rect2(Vector2(actual_x, 27.0), Vector2(maxf(0.0, size.x - RIGHT_MARGIN - actual_x), baseline - 25.0)), Color(0.50, 0.64, 0.80, 0.08))
	draw_string(font, Vector2(size.x - RIGHT_MARGIN - 185.0, 32.0), "Forecast →", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("9bb3c5"))
	var values: PackedFloat32Array = _week_values(selected_purpose)
	var peak: float = 1.0
	for value in values:
		peak = maxf(peak, value)
	draw_string(font, Vector2(size.x - RIGHT_MARGIN - 135.0, 16.0), "Peak %d/day" % roundi(peak), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("8fa4ba"))
	for fraction in [0.0, 0.5, 1.0]:
		var guide_y: float = baseline - chart_height * fraction
		draw_line(Vector2(LEFT_MARGIN, guide_y), Vector2(size.x - RIGHT_MARGIN, guide_y), Color(0.65, 0.78, 0.89, 0.13), 1.0)
	var estimated_color := Color(line_color.r, line_color.g, line_color.b, 0.42)
	for day_index in range(WEEK_DAYS - 1):
		var segment_points := PackedVector2Array()
		for step in range(CURVE_STEPS_PER_HOUR + 1):
			var fraction: float = float(step) / float(CURVE_STEPS_PER_HOUR)
			var x: float = LEFT_MARGIN + (float(day_index) + 0.5 + fraction) * day_width
			var y: float = baseline - chart_height * _curve_value(values, day_index, fraction) / peak
			segment_points.append(Vector2(x, y))
		var calculated: bool = week_totals.has(week_start_day_key + day_index) and week_totals.has(week_start_day_key + day_index + 1)
		draw_polyline(segment_points, line_color if calculated else estimated_color, 3.0 if calculated else 2.0, true)
	for day_index in range(WEEK_DAYS):
		var day_key: int = week_start_day_key + day_index
		var x: float = LEFT_MARGIN + (float(day_index) + 0.5) * day_width
		var y: float = baseline - chart_height * values[day_index] / peak
		draw_circle(Vector2(x, y), 3.0, line_color if week_totals.has(day_key) else estimated_color)
		draw_string(font, Vector2(x - 20.0, size.y - 5.0), _week_day_label(day_key), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8fa4ba"))
	if selected_week_day_key >= week_start_day_key and selected_week_day_key < week_start_day_key + WEEK_DAYS:
		var selected_x: float = LEFT_MARGIN + (float(selected_week_day_key - week_start_day_key) + 0.5) * day_width
		draw_line(Vector2(selected_x, 27.0), Vector2(selected_x, baseline + 2.0), Color(1.0, 1.0, 1.0, 0.75), 1.0)
	draw_line(Vector2(actual_x, 27.0), Vector2(actual_x, baseline + 2.0), Color("f2b678", 0.9), 2.0)


func _week_values(purpose: String) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for day_index in range(WEEK_DAYS):
		var totals: Dictionary = _week_totals_for(week_start_day_key + day_index)
		values.append(float(totals.get(purpose, 0.0)))
	return values


func _week_totals_for(day_key: int) -> Dictionary:
	if week_totals.has(day_key):
		return week_totals[day_key]
	var source_day: int = flow_profile.active_day_key
	var source_totals: Dictionary = week_totals[source_day] if week_totals.has(source_day) else flow_profile.get_daily_totals()
	var target_weekend: bool = CalendarClock.is_weekend_unix(day_key * 86400)
	var source_weekend: bool = CalendarClock.is_weekend_unix(source_day * 86400)
	if source_weekend == target_weekend:
		return source_totals
	var work_ratio: float = TripFlowCalculator.WEEKEND_COMMUTE_FRACTION
	var commercial_ratio: float = TripFlowCalculator.WEEKEND_SHOPPING_VISITS_PER_PERSON / TripFlowCalculator.WEEKDAY_SHOPPING_VISITS_PER_PERSON
	var social_ratio: float = TripFlowCalculator.WEEKEND_SOCIAL_VISITS_PER_PERSON / TripFlowCalculator.WEEKDAY_SOCIAL_VISITS_PER_PERSON
	if source_weekend:
		work_ratio = 1.0 / work_ratio
		commercial_ratio = 1.0 / commercial_ratio
		social_ratio = 1.0 / social_ratio
	var work: float = float(source_totals[FlowProfile.WORK]) * work_ratio
	var commercial: float = float(source_totals[FlowProfile.COMMERCIAL]) * commercial_ratio
	var social: float = float(source_totals[FlowProfile.SOCIAL]) * social_ratio
	return {FlowProfile.ALL: work + commercial + social, FlowProfile.WORK: work, FlowProfile.COMMERCIAL: commercial, FlowProfile.SOCIAL: social}


func _week_day_label(day_key: int) -> String:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(day_key * 86400)
	return "%s %d" % [CalendarClock.WEEKDAY_NAMES[int(date["weekday"])], int(date["day"])]


func _purpose_color() -> Color:
	match selected_purpose:
		FlowProfile.WORK:
			return Color("6cc6d5")
		FlowProfile.COMMERCIAL:
			return Color("d49bdf")
		FlowProfile.SOCIAL:
			return Color("f2b678")
		_:
			return Color("e6eff8")


func _hourly_values(purpose: String) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for hour in range(24):
		values.append(flow_profile.get_hourly_total(hour, purpose))
	var midnight_profile = next_day_profile if next_day_profile != null else flow_profile
	values.append(midnight_profile.get_hourly_total(0, purpose))
	values.append(midnight_profile.get_hourly_total(1, purpose))
	return values


func _curve_points(values: PackedFloat32Array, peak: float, baseline: float, chart_height: float, slot_width: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for hour in range(24):
		for step in range(CURVE_STEPS_PER_HOUR):
			var fraction: float = float(step) / float(CURVE_STEPS_PER_HOUR)
			var x: float = LEFT_MARGIN + (hour + fraction) * slot_width
			var y: float = baseline - chart_height * _curve_value(values, hour, fraction) / peak
			points.append(Vector2(x, y))
	points.append(Vector2(LEFT_MARGIN + 24.0 * slot_width, baseline - chart_height * values[24] / peak))
	return points


func _curve_value(values: PackedFloat32Array, segment: int, fraction: float) -> float:
	var start: float = values[segment]
	var finish: float = values[segment + 1]
	var start_slope: float = _curve_slope(values, segment)
	var finish_slope: float = _curve_slope(values, segment + 1)
	var t: float = clampf(fraction, 0.0, 1.0)
	var t2: float = t * t
	var t3: float = t2 * t
	var interpolated: float = (2.0 * t3 - 3.0 * t2 + 1.0) * start + (t3 - 2.0 * t2 + t) * start_slope + (-2.0 * t3 + 3.0 * t2) * finish + (t3 - t2) * finish_slope
	return clampf(interpolated, minf(start, finish), maxf(start, finish))


func _curve_slope(values: PackedFloat32Array, index: int) -> float:
	if index == 0:
		return values[1] - values[0]
	if index == values.size() - 1:
		return values[index] - values[index - 1]
	var before: float = values[index] - values[index - 1]
	var after: float = values[index + 1] - values[index]
	if before * after <= 0.0:
		return 0.0
	return 2.0 * before * after / (before + after)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_LEFT and mouse_button.pressed:
			if week_mode:
				_select_week_day(mouse_button.position.x)
				accept_event()
				return
			var selected_time: Vector2i = _time_at(mouse_button.position.x)
			time_selected.emit(selected_time.x, selected_time.y)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if week_mode:
				_select_week_day(motion.position.x)
				accept_event()
				return
			var selected_time: Vector2i = _time_at(motion.position.x)
			time_selected.emit(selected_time.x, selected_time.y)
			accept_event()


func _time_at(x: float) -> Vector2i:
	var chart_width: float = maxf(1.0, size.x - LEFT_MARGIN - RIGHT_MARGIN)
	var minute_of_day := clampi(floori((x - LEFT_MARGIN) * 1440.0 / chart_width), 0, 1439)
	return Vector2i(floori(float(minute_of_day) / 60.0), minute_of_day % 60)


func _select_week_day(x: float) -> void:
	var chart_width: float = maxf(1.0, size.x - LEFT_MARGIN - RIGHT_MARGIN)
	var day_index: int = clampi(floori((x - LEFT_MARGIN) * float(WEEK_DAYS) / chart_width), 0, WEEK_DAYS - 1)
	selected_week_day_key = week_start_day_key + day_index
	_update_week_tooltip()
	queue_redraw()


func _update_week_tooltip() -> void:
	var totals: Dictionary = _week_totals_for(selected_week_day_key)
	var source: String = "calculated" if week_totals.has(selected_week_day_key) else "estimate"
	tooltip_text = "%s: %d %s trips (%s)" % [_week_day_label(selected_week_day_key), roundi(float(totals.get(selected_purpose, 0.0))), selected_purpose.to_lower(), source]
