extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 300000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		_fail("Region generation timed out")
		return
	main.playing = false
	var map = main.map_view
	await process_frame
	await process_frame
	await process_frame
	var bakes: int = map.static_bake_count
	map.pan += Vector2(100.0, 60.0)
	for _frame in range(10):
		await process_frame
	if map.static_bake_count != bakes:
		_fail("Small pan inside the bake margin rebaked %d times; panning must be transform-only." % (map.static_bake_count - bakes))
		return
	print("Pan inside margin: 0 rebakes")
	bakes = map.static_bake_count
	var zoom_before: float = map.zoom
	map._zoom_at(map.size * 0.5, 1.2)
	if map.zoom <= zoom_before:
		_fail("Zoom did not apply")
		return
	for _frame in range(10):
		await process_frame
	if map.static_bake_count != bakes:
		_fail("Center-anchored zoom inside a band rebaked %d times; wheel zoom must stay transform-only within a band." % (map.static_bake_count - bakes))
		return
	print("Zoom inside band: 0 rebakes")
	bakes = map.static_bake_count
	map.pan += Vector2(700.0, 500.0)
	await process_frame
	await process_frame
	if map.static_bake_count == bakes:
		_fail("A pan beyond the bake margin must trigger a rebake")
		return
	var rebaked: int = map.static_bake_count
	for _frame in range(10):
		await process_frame
	if map.static_bake_count != rebaked:
		_fail("Rebakes kept firing after the large pan: %d extra; the bake must be stable at rest." % (map.static_bake_count - rebaked))
		return
	print("Pan beyond margin: 1 rebake, then stable")
	var band: int = map._zoom_band()
	while map._zoom_band() == band:
		map._zoom_at(map.size * 0.5, 1.35)
		await process_frame
	await process_frame
	await process_frame
	if map.static_bake_count <= rebaked:
		_fail("Crossing a zoom band must trigger a rebake")
		return
	print("Band crossing: rebaked; total bakes %d" % map.static_bake_count)
	quit(0)
