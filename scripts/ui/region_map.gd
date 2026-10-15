extends Control

signal neighborhood_selected(neighborhood_id: int)

const WORLD_CENTER = Vector2(35.0, 29.0)
const WORLD_SIZE = Vector2(70.0, 58.0)
const CITY_COLORS = [
	Color("4b8fbf"),
	Color("9872c5"),
	Color("bc8d50"),
]

var region
var selected_id: int = -1
var hovered_id: int = -1
var zoom: float = 1.0
var pan: Vector2 = Vector2.ZERO
var pointer_down: bool = false
var pointer_dragged: bool = false
var pointer_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(480, 460)
	resized.connect(queue_redraw)


func set_region(new_region) -> void:
	region = new_region
	selected_id = -1
	hovered_id = -1
	zoom = 1.0
	pan = Vector2.ZERO
	queue_redraw()


func set_selected(neighborhood_id: int) -> void:
	selected_id = neighborhood_id
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("101b2b"))
	_draw_grid()
	if region == null:
		return
	_draw_cities()
	_draw_neighborhoods()
	_draw_legend()


func _draw_grid() -> void:
	var grid_color := Color(0.32, 0.47, 0.60, 0.15)
	for x in range(0, 71, 10):
		draw_line(_world_to_screen(Vector2(x, 0)), _world_to_screen(Vector2(x, WORLD_SIZE.y)), grid_color, 1.0)
	for y in range(0, 59, 10):
		draw_line(_world_to_screen(Vector2(0, y)), _world_to_screen(Vector2(WORLD_SIZE.x, y)), grid_color, 1.0)


func _draw_cities() -> void:
	var font := get_theme_default_font()
	for city in region.cities:
		var center: Vector2 = _world_to_screen(city["center_km"])
		var color: Color = CITY_COLORS[city["id"]]
		var radius: float = 12.0 * _map_scale() * zoom
		draw_circle(center, radius, Color(color.r, color.g, color.b, 0.08))
		draw_arc(center, radius, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.28), 1.0, true)
		draw_string(font, center + Vector2(-36, -radius - 12), str(city["name"]).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(color.r, color.g, color.b, 0.80))


func _draw_neighborhoods() -> void:
	if region.accessibility.is_empty():
		return
	var min_access: float = region.accessibility[0]
	var max_access: float = min_access
	for value in region.accessibility:
		min_access = minf(min_access, value)
		max_access = maxf(max_access, value)
	var font := get_theme_default_font()
	for neighborhood in region.neighborhoods:
		var screen_position: Vector2 = _world_to_screen(neighborhood.position_km)
		var radius: float = _node_radius(neighborhood.population)
		var color := _access_color((region.accessibility[neighborhood.id] - min_access) / maxf(1.0, max_access - min_access))
		draw_circle(screen_position, radius + 3.0, Color("0b1421"))
		draw_circle(screen_position, radius, color)
		draw_arc(screen_position, radius, 0.0, TAU, 32, Color(1, 1, 1, 0.42), 1.0, true)
		if neighborhood.id == selected_id:
			draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("ffffff"), 2.5, true)
		elif neighborhood.id == hovered_id:
			draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("a9d7ff"), 2.0, true)
		var label_position := screen_position + Vector2(radius + 7.0, 4.0)
		draw_string(font, label_position + Vector2(1, 1), neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("07111e"))
		draw_string(font, label_position, neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e8f0f7"))


func _draw_legend() -> void:
	var origin := Vector2(18, size.y - 44)
	draw_rect(Rect2(origin - Vector2(9, 25), Vector2(246, 54)), Color(0.04, 0.09, 0.16, 0.90))
	for step in range(8):
		draw_rect(Rect2(origin + Vector2(step * 17.0, 0), Vector2(16, 9)), _access_color(float(step) / 7.0))
	var font := get_theme_default_font()
	draw_string(font, origin + Vector2(0, -6), "JOB ACCESSIBILITY", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, origin + Vector2(0, 26), "lower", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, origin + Vector2(102, 26), "higher", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, Vector2(size.x - 178, size.y - 15), "Drag to pan  •  Scroll to zoom", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("8fa4ba"))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and (mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var old_zoom := zoom
			zoom = clampf(zoom * (1.12 if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 0.6, 2.8)
			var ratio := zoom / old_zoom
			pan = mouse_button.position - size * 0.5 - (mouse_button.position - size * 0.5 - pan) * ratio
			queue_redraw()
			accept_event()
		elif mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				pointer_down = true
				pointer_dragged = false
				pointer_start = mouse_button.position
			else:
				if pointer_down and not pointer_dragged:
					neighborhood_selected.emit(_hit_test(mouse_button.position))
				pointer_down = false
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if pointer_down:
			if motion.position.distance_to(pointer_start) > 4.0:
				pointer_dragged = true
			if pointer_dragged:
				pan += motion.relative
				queue_redraw()
		else:
			var new_hover := _hit_test(motion.position)
			if new_hover != hovered_id:
				hovered_id = new_hover
				queue_redraw()


func _hit_test(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest_id := -1
	var closest_distance := INF
	for neighborhood in region.neighborhoods:
		var distance: float = screen_position.distance_to(_world_to_screen(neighborhood.position_km))
		if distance <= _node_radius(neighborhood.population) + 7.0 and distance < closest_distance:
			closest_id = neighborhood.id
			closest_distance = distance
	return closest_id


func _map_scale() -> float:
	return maxf(1.0, minf((size.x - 110.0) / WORLD_SIZE.x, (size.y - 110.0) / WORLD_SIZE.y))


func _world_to_screen(world_position: Vector2) -> Vector2:
	return size * 0.5 + pan + (world_position - WORLD_CENTER) * _map_scale() * zoom


func _node_radius(population: int) -> float:
	return clampf(7.0 + sqrt(float(population)) * 0.075, 10.0, 18.0)


func _access_color(t: float) -> Color:
	return Color("3bb5c8").lerp(Color("f5a45d"), clampf(t, 0.0, 1.0))
