extends SceneTree
const Fixture = preload("res://tests/ui_fixture.gd")
var errors: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var main = await Fixture.attach_small(self)
	main.playing = false
	main._discard_pending_day()
	main.dev_mode_enabled = true
	main.region.dev_mode = true
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id < 0 and candidate.frontage_link_id >= 0:
			candidate_id = candidate.id
			break
	if candidate_id < 0:
		push_error("No approval fixture")
		quit(1)
		return
	var map = main.map_view
	var key: String = main.region.development_candidates[candidate_id].key
	var anchor: Vector2 = main.region.development_candidates[candidate_id].center_km
	map.zoom = 200.0 / map._map_scale()
	map.pan = -(anchor - map._world_center()) * map._map_scale() * map.zoom
	for step in range(5): await process_frame
	var before: Vector2 = map._world_to_screen(anchor)
	var before_pixels: float = map._map_scale() * map.zoom
	main._on_map_mode_selected(2)
	for step in range(5): await process_frame
	_check(map._world_to_screen(anchor).distance_to(before) < .1, "First zoning activation moved the camera")
	main._on_candidate_selected(candidate_id)
	# A rapid click joins in-flight preparation rather than duplicating it.
	await process_frame
	var count: int = main.region.neighborhoods.size()
	var started := Time.get_ticks_usec()
	main.zoning_button.pressed.emit()
	var deadline := Time.get_ticks_msec() + 20000
	while main.region.neighborhoods.size() == count and Time.get_ticks_msec() < deadline: await process_frame
	var elapsed := (Time.get_ticks_usec()-started)/1000.0
	_check(main.region.neighborhoods.size() == count+1, "Approval did not publish exactly one district")
	_check(map._world_to_screen(anchor).distance_to(before) < .1, "First approval moved the camera")
	_check(absf(map._map_scale()*map.zoom-before_pixels) < .01, "Approval changed map scale")
	var id: int = main.region.development_candidate_keys.get(key, -1)
	_check(id >= 0 and main.region.development_candidates[id].neighborhood_id >= 0, "Published zone is not approved")
	# Wait for suggestions and assert they cannot roll back the new district.
	deadline = Time.get_ticks_msec()+20000
	while (main.development_thread != null or not main.development_dirty_cities.is_empty()) and Time.get_ticks_msec()<deadline: await process_frame
	_check(main.development_dirty_cities.is_empty(), "Suggestion refresh did not finish")
	_check(main.region.neighborhoods.size() == count+1, "Suggestion refresh replaced simulation state")
	main._on_map_mode_selected(0)
	main._on_map_mode_selected(2)
	for step in range(5): await process_frame
	_check(map._world_to_screen(anchor).distance_to(before) < .1, "Repeated zoning activation moved the camera")
	# Keep simulation active while a selected district is prepared, then
	# approve from that packet and send a duplicate click.
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id < 0 and candidate.frontage_link_id >= 0:
			candidate_id = candidate.id
			break
	main.playing = true
	main._on_candidate_selected(candidate_id)
	deadline = Time.get_ticks_msec()+20000
	while main.development_prepared.get("stamp",-1) != preload("res://scripts/simulation/development_planner.gd").preparation_stamp(main.region,main.region.development_candidates[candidate_id],main.development_controls.shares(),main.development_controls.densities()) and Time.get_ticks_msec()<deadline: await process_frame
	_check(not main.development_prepared.is_empty(), "Selected district did not prepare while simulation was running")
	count = main.region.neighborhoods.size()
	started = Time.get_ticks_usec()
	main.zoning_button.pressed.emit()
	main.zoning_button.pressed.emit()
	deadline = Time.get_ticks_msec()+20000
	while main.region.neighborhoods.size() == count and Time.get_ticks_msec()<deadline: await process_frame
	var warm_ms := (Time.get_ticks_usec()-started)/1000.0
	_check(main.region.neighborhoods.size() == count+1, "Duplicate click created multiple districts")
	_check(main.last_road_rebuild_stages_us.get("used_preparation",0) == 1, "Running approval did not reuse the selected district's preparation")
	_check(map._world_to_screen(anchor).distance_to(before) < .1, "Running approval moved camera")
	main.playing = false
	var world_center: Vector2 = map._screen_to_world(map.size*.5)
	var previous_size: Vector2 = map.size
	map.size -= Vector2(100, 50)
	_check(map._screen_to_world(map.size*.5).distance_to(world_center) < .001, "Viewport resize changed world center")
	_check(absf(map._map_scale()*map.zoom-before_pixels) < .01, "Viewport resize changed physical scale")
	map.size = previous_size
	print("Zoning camera stable; rapid click %.1f ms; prepared approval while running %.1f ms; stages=%s" % [elapsed,warm_ms,main.last_road_rebuild_stages_us])
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
