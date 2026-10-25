extends SceneTree

var shot_index := 0
var last_bakes: int = -1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while main.region == null:
		await process_frame
	main.playing = false
	await process_frame
	await process_frame
	var map = main.map_view
	last_bakes = map.static_bake_count
	_diag(map, "A_default")
	_capture(map, "A_default")
	map.pan += Vector2(120.0, 80.0)
	await process_frame
	await process_frame
	_diag(map, "B_pan_small")
	_capture(map, "B_pan_small")
	map.pan += Vector2(400.0, 300.0)
	await process_frame
	await process_frame
	await process_frame
	_diag(map, "C_pan_large")
	_capture(map, "C_pan_large")
	map._zoom_at(map.size * 0.5, 1.35)
	await process_frame
	await process_frame
	_diag(map, "D_zoom1")
	_capture(map, "D_zoom1")
	for _step in range(6):
		map._zoom_at(map.size * 0.5, 1.35)
		await process_frame
	_diag(map, "E_zoom7")
	_capture(map, "E_zoom7")
	for _step in range(12):
		map._zoom_at(map.size * 0.5, 1.35)
		await process_frame
	await process_frame
	_diag(map, "F_zoom19")
	_capture(map, "F_zoom19")
	for _step in range(6):
		map._zoom_at(map.size * 0.5, 0.5)
		await process_frame
	await process_frame
	_diag(map, "G_zoomout")
	_capture(map, "G_zoomout")
	quit(0)


func _diag(map, label: String) -> void:
	var bakes: int = map.static_bake_count
	print("%s: zoom %.2f band %d bake_zoom %.2f bake_pan %s pan %s bakes %d (+%d since last)" % [label, map.zoom, map._zoom_band(), map.bake_zoom, map.bake_pan, map.pan, bakes, 0 if last_bakes < 0 else bakes - last_bakes])
	last_bakes = bakes


func _capture(map, label: String) -> void:
	var image := root.get_texture().get_image()
	var path := "E:/Godot/transitocracy/probe_shot_%s.png" % label
	image.save_png(path)
	print("saved ", path, " bake_us=", map.last_draw_us, " overlay_us=", map.last_overlay_us)
