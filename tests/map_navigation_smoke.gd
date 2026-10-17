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
	_check(is_equal_approx(map.zoom, pow(1.12, 0.25)), "high-resolution wheel input must respect fractional scroll amounts")
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
	map._zoom_at(anchor, 1000.0)
	_check(is_equal_approx(map.zoom, map.MAX_ZOOM), "small maps must support zooming deeply into a California-sized state")
	map._zoom_at(anchor, 0.0001)
	_check(is_equal_approx(map.zoom, 1.0), "zoom out must stop at the whole-state scale")
	map.reset_view()
	var navigation = map.get_node("MapNavigation")
	navigation.get_child(1).pressed.emit()
	_check(is_equal_approx(map.zoom, 1.25), "the plus button must zoom in")
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
	if failures == 0:
		print("Trackpad pinch, pan, smooth wheel, navigation buttons, and camera anchors passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
