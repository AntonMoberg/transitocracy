extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = await UiFixture.attach_small(self)
	main.playing = false
	var map = main.map_view
	var anchor: Vector2 = map.size * Vector2(0.34, 0.64)
	var world_anchor: Vector2 = map._screen_to_world(anchor)
	var pinch := InputEventMagnifyGesture.new()
	pinch.position = anchor
	pinch.factor = 1.25
	map._gui_input(pinch)
	_check(is_equal_approx(map.zoom, 1.25), "native trackpad pinch must zoom")
	_check(map._screen_to_world(anchor).distance_to(world_anchor) < 0.001, "pinch zoom must preserve the map location under the gesture")
	pinch.factor = 0.8
	map._gui_input(pinch)
	_check(is_equal_approx(map.zoom, 1.0) and map.pan.length() < 0.001, "opposite pinch gestures must restore the original camera")
	var wheel := InputEventMouseButton.new()
	wheel.position = anchor
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.factor = 0.25
	map._gui_input(wheel)
	_check(is_equal_approx(map.zoom, pow(1.35, 0.25)), "high-resolution wheel input must respect fractional scroll amounts")
	_check(map._screen_to_world(anchor).distance_to(world_anchor) < 0.001, "wheel zoom must preserve its anchor")
	var swipe := InputEventPanGesture.new()
	swipe.position = anchor
	swipe.delta = Vector2(0.4, -0.3)
	var original_pan: Vector2 = map.pan
	var original_zoom: float = map.zoom
	map._gui_input(swipe)
	_check(map.pan.is_equal_approx(original_pan - swipe.delta * map.TRACKPAD_PAN_PIXELS) and is_equal_approx(map.zoom, original_zoom), "two-finger scrolling must pan in both axes without changing zoom")
	swipe.meta_pressed = true
	swipe.delta = Vector2(0.0, -0.5)
	world_anchor = map._screen_to_world(anchor)
	map._gui_input(swipe)
	_check(map.zoom > original_zoom and map._screen_to_world(anchor).distance_to(world_anchor) < 0.001, "Command-scroll must provide anchored trackpad zoom")
	world_anchor = map._screen_to_world(anchor)
	map._zoom_at(anchor, 10000000.0)
	_check(is_equal_approx(map._map_scale() * map.zoom, map.MAX_PIXELS_PER_KM), "street zoom must reach ten screen pixels per meter")
	_check(map._screen_to_world(anchor).distance_to(world_anchor) < 0.001, "street zoom must preserve the location under the pointer")
	var pixels_per_meter: float = map._pixels_per_meter()
	_check(absf(map._road_lane_spacing("Highway") / pixels_per_meter - 3.6) < 0.01, "highway lanes must be 3.6 meters wide at street zoom")
	_check(absf(map._road_outer_half_width(2, "Highway") / pixels_per_meter - 10.7) < 0.01, "a two-lane-per-direction highway must include its median and shoulders")
	_check(absf(map._road_outer_half_width(1, "Arterial") / pixels_per_meter - 4.4) < 0.01, "arterial lanes must use their own physical width")
	map._zoom_at(anchor, 0.0000001)
	_check(is_equal_approx(map.zoom, 1.0), "zoom out must stop at the whole-state scale")
	map.reset_view()
	var navigation = map.get_node("MapNavigation")
	navigation.get_child(1).pressed.emit()
	_check(is_equal_approx(map.zoom, 1.6), "the plus button must zoom in")
	navigation.get_child(0).pressed.emit()
	_check(is_equal_approx(map.zoom, 1.0), "the minus button must zoom out")
	map.pan = Vector2(50, -30)
	navigation.get_child(2).pressed.emit()
	_check(is_equal_approx(map.zoom, 1.0) and map.pan == Vector2.ZERO, "Fit must restore the complete state")
	var selections: Array[int] = []
	map.road_node_clicked.connect(func(node_id: int) -> void: selections.append(node_id))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = map._world_to_screen(main.region.neighborhoods[0].position_km)
	press.pressed = true
	map._gui_input(press)
	swipe.meta_pressed = false
	map._gui_input(swipe)
	press.pressed = false
	map._gui_input(press)
	_check(selections.is_empty() and not map.pointer_down, "a gesture during a pointer press must not accidentally select or build a road")
	map.reset_view()
	map.zoom = 8.0
	map.pan = -(main.region.neighborhoods[0].position_km - map._world_center()) * map._map_scale() * map.zoom
	var node_position: Vector2 = map._world_to_screen(main.region.neighborhoods[0].position_km)
	_check(map._hit_road_node(node_position) == main.region.neighborhood_gateway_node_ids[0], "road targets must remain selectable after panning and zooming")
	var longest_segment_km := 0.0
	var street_link_id := -1
	var street_link_lanes := 0
	var street_link_class := ""
	var street_start := Vector2.ZERO
	var street_end := Vector2.ZERO
	for link in main.region.road_links:
		for segment in range(1, link.points.size()):
			var segment_km: float = link.points[segment - 1].distance_to(link.points[segment])
			if segment_km > longest_segment_km:
				longest_segment_km = segment_km
				street_link_id = link.id
				street_link_lanes = link.lanes_per_direction
				street_link_class = link.road_class
				street_start = link.points[segment - 1]
				street_end = link.points[segment]
	_check(street_link_id >= 0, "the map needs a road for street-scale selection")
	if street_link_id >= 0:
		map.zoom = map.MAX_PIXELS_PER_KM / map._map_scale()
		var street_center: Vector2 = (street_start + street_end) * 0.5
		map.pan = -(street_center - map._world_center()) * map._map_scale() * map.zoom
		var screen_tangent: Vector2 = (map._world_to_screen(street_end) - map._world_to_screen(street_start)).normalized()
		var road_edge: Vector2 = map.size * 0.5 + screen_tangent.orthogonal() * (map._road_outer_half_width(street_link_lanes, street_link_class) - 1.0)
		_check(map._hit_road_link(road_edge) == street_link_id, "road shoulders must remain selectable at street zoom")
	if failures == 0:
		print("Trackpad navigation, street zoom, physical road widths, and street-scale selection passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
