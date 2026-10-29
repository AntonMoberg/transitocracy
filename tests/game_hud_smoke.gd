extends SceneTree

const Fixture = preload("res://tests/ui_fixture.gd")
var failures: Array[String] = []
var map_clicks := 0

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1920,1080)
	var main = await Fixture.attach_small(self)
	main.playing = false
	var map = main.map_view
	var hud = main.hud
	_check(map.size==main.size and map.position==Vector2.ZERO,"Map does not fill the window")
	_check(hud.section.is_empty() and not hud.inspector_panel.visible,"HUD did not start uncluttered")
	_check(not main.flow_timeline.is_visible_in_tree(),"Statistics leaked into the default view")
	map.jurisdiction_selected.connect(func(_id): map_clicks+=1)
	map.road_empty_clicked.connect(func(_point): map_clicks+=1)
	map.road_node_clicked.connect(func(_id): map_clicks+=1)
	map.road_link_clicked.connect(func(_id,_point): map_clicks+=1)
	map.candidate_selected.connect(func(_id): map_clicks+=1)
	for resolution in [Vector2i(1024,700),Vector2i(1920,1080),Vector2i(2560,1440)]:
		root.size = resolution
		for step in range(5): await process_frame
		var center: Vector2 = map._screen_to_world(map.size*.5)
		var pixels: float = map._map_scale()*map.zoom
		var map_size: Vector2 = map.size
		await _capture("hud_%d_overview" % resolution.x)
		for section in ["Roads","Planning","Zoning","Map","Statistics","Menu"]:
			hud.section_buttons[section].pressed.emit()
			for step in range(3): await process_frame
			_check(hud.section==section and hud.drawers[section].visible,"Toolbar did not open "+section)
			_check(map.size==map_size,"Opening "+section+" resized the map")
			_check(map._screen_to_world(map.size*.5).distance_to(center)<.0001 and absf(map._map_scale()*map.zoom-pixels)<.001,"Opening "+section+" changed the camera")
			var drawer: Rect2 = hud.drawers[section].get_global_rect()
			_check(drawer.position.x>=0 and drawer.end.x<=main.size.x+.1 and drawer.end.y<hud.footer.position.y,"Drawer does not fit: "+section)
			# Clicking a panel's padding must not select or build underneath it.
			await _click(drawer.position+Vector2(3,3))
			await _wheel(drawer.position+Vector2(3,3))
			_check(map_clicks==0,"A panel click reached the map")
			_check(absf(map._map_scale()*map.zoom-pixels)<.001,"Scrolling a panel zoomed the map")
			main._dismiss_hud()
			_check(hud.section.is_empty() and map.road_tool=="Inspect","Escape did not return to inspection")
		await _click(hud.footer.get_global_rect().position+Vector2(3,3))
		_check(map_clicks==0,"Toolbar click reached the map")
	# Road palettes and the shared selector must drive the same tool state.
	hud.section_buttons.Roads.pressed.emit()
	hud.tool_buttons[2].pressed.emit()
	_check(map.road_tool=="Highway" and main.road_tool_selector.selected==2,"Highway palette is not wired")
	main.road_start_node = 0
	main._dismiss_hud()
	_check(main.road_start_node==-1 and hud.section=="Roads","Escape must cancel the unfinished route before closing its tools")
	main._dismiss_hud()
	hud.section_buttons.Planning.pressed.emit()
	hud.tool_buttons[5].pressed.emit()
	_check(map.road_tool=="Station site","Planning palette is not wired")
	main._dismiss_hud()
	hud.section_buttons.Map.pressed.emit()
	hud.map_buttons.Traffic.button_pressed = true
	_check(map.show_traffic_overlay,"Traffic overlay toggle failed")
	main._dismiss_hud()
	hud.section_buttons.Statistics.pressed.emit()
	_check(main.flow_timeline.is_visible_in_tree() and map.map_mode=="Roads","Statistics should open without changing map analysis")
	hud.trips_toggle.button_pressed = true
	_check(map.map_mode=="Trips","Trips analysis toggle failed")
	await _capture("hud_statistics")
	main._dismiss_hud()
	_check(map.map_mode=="Roads" and map.show_traffic_overlay,"Closing statistics lost the independent traffic overlay")
	map.set_overlay("Traffic",false)
	main._on_jurisdiction_selected(main.region.city_jurisdiction_ids[0])
	_check(hud.inspector_panel.visible,"Selecting a city did not open the inspector")
	main._dismiss_hud()
	main._refresh_inspector(false)
	_check(not hud.inspector_panel.visible,"Live inspector refresh reopened a dismissed panel")
	# Text entry must keep global keyboard shortcuts from changing the clock.
	hud.section_buttons.Menu.pressed.emit()
	main.seed_input.get_line_edit().grab_focus()
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_SPACE
	main._input(key)
	_check(not main.playing,"Typing into a field toggled playback")
	main.seed_input.get_line_edit().release_focus()
	main._dismiss_hud()
	key.keycode = KEY_W
	main._input(key)
	_check(main.speed_selector.selected==1,"Playback shortcut stopped working")
	# Capture populated contextual panels, including detailed city geometry.
	root.size = Vector2i(1920,1080)
	for step in range(5): await process_frame
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id<0:
			candidate_id = candidate.id
			break
	if candidate_id>=0:
		var point: Vector2 = main.region.development_candidates[candidate_id].center_km
		map.zoom = 200.0/map._map_scale()
		map.pan = -(point-map._world_center())*map._map_scale()*map.zoom
		hud.section_buttons.Zoning.pressed.emit()
		main._on_candidate_selected(candidate_id)
		await Fixture.settle_map(self,map)
		await _capture("hud_zoning")
		main.development_controls.zoning_popup.popup_centered(Vector2i(380,0))
		await process_frame
		await _capture("hud_development")
		main._dismiss_hud()
		_check(not main.development_controls.zoning_popup.visible and hud.inspector_panel.visible,"Escape did not dismiss the zoning popup before its inspector")
		hud.select_section("Roads")
		await _capture("hud_roads")
	if not failures.is_empty(): push_error("; ".join(failures))
	print("HUD: full-window map, drawers, input interception, camera stability, tools, layers and keyboard checked. Screenshots: ",ProjectSettings.globalize_path("user://hud_zoning.png"))
	main.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _click(point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event,true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event,true)
	await process_frame

func _wheel(point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_WHEEL_UP
	event.pressed = true
	root.push_input(event,true)
	await process_frame

func _capture(filename: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("user://"+filename+".png")

func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)
