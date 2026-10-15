extends Control

signal time_selected(hour: int, minute: int)

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const LEFT_MARGIN = 24.0
const RIGHT_MARGIN = 24.0
const CURVE_STEPS_PER_HOUR = 12

var flow_profile
var next_day_profile
var selected_purpose: String = FlowProfile.ALL
var selected_hour: int = 8
var hour_fraction: float = 0.0
var weekend: bool = false


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
	queue_redraw()


func set_hour(hour: int) -> void:
	set_time(hour, 0.0)


func set_time(hour: int, fraction: float) -> void:
	selected_hour = clampi(hour, 0, 23)
	hour_fraction = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func set_weekend(value: bool) -> void:
	weekend = value
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("152235"))
	if flow_profile == null:
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
	var marker_x: float = LEFT_MARGIN + (selected_hour + hour_fraction) * slot_width
	draw_line(Vector2(marker_x, 27), Vector2(marker_x, baseline + 2.0), Color(1.0, 1.0, 1.0, 0.78), 2.0)
	for labeled_hour in [0, 6, 12, 18, 24]:
		var x: float = LEFT_MARGIN + labeled_hour * slot_width
		draw_string(font, Vector2(x - 9.0, size.y - 5.0), "%02d" % labeled_hour, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("8fa4ba"))


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
			var selected_time: Vector2i = _time_at(mouse_button.position.x)
			time_selected.emit(selected_time.x, selected_time.y)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var selected_time: Vector2i = _time_at(motion.position.x)
			time_selected.emit(selected_time.x, selected_time.y)
			accept_event()


func _time_at(x: float) -> Vector2i:
	var chart_width: float = maxf(1.0, size.x - LEFT_MARGIN - RIGHT_MARGIN)
	var minute_of_day := clampi(floori((x - LEFT_MARGIN) * 1440.0 / chart_width), 0, 1439)
	return Vector2i(floori(float(minute_of_day) / 60.0), minute_of_day % 60)
