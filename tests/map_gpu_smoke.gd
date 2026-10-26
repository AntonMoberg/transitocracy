extends SceneTree
## Small real-GPU check: metadata, extrusion, traffic textures and atomic swaps.
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const Renderer = preload("res://scripts/ui/map_chunk_renderer.gd")
var errors := PackedStringArray()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("map_gpu_smoke requires a graphical renderer")
		quit(1)
		return
	root.size = Vector2i(1200,1000)
	root.content_scale_size = Vector2i(1200,1000)
	var renderer := Renderer.new()
	root.add_child(renderer)
	renderer.map = {"map_mode":"Roads", "show_traffic_overlay":false, "selected_local_street":Vector2i(-1,-1), "selected_road_link_id":0}
	renderer.epoch = 1
	renderer.source = Geometry.index_source({"bounds":Rect2(0,0,1,1), "epoch":1, "terrain":null, "features":[{"identity":"road:0", "kind":"line", "layer":"roads", "points":PackedVector2Array([Vector2(.1,.5),Vector2(.9,.5)]), "slot":0, "lanes":2, "highway":true}]})
	renderer.traffic_slots = {0:0}
	renderer._setup_traffic()
	renderer.transform = Transform2D(Vector2(800,0),Vector2(0,800),Vector2(100,100))
	renderer._update_materials(800)
	var packet := Geometry.build(renderer.source, Vector3i.ZERO, "roads")
	packet.merge({"part":0,"nodes":[],"bytes":0})
	renderer.uploads.append(packet)
	renderer._publish(Time.get_ticks_usec() + 1000000)
	for entry in renderer.chunks.values():
		for node in entry.nodes:
			node.show()
	await process_frame
	await RenderingServer.frame_post_draw
	var pixels := root.get_texture().get_image()
	pixels.save_png("user://gpu_roads.png")
	var selected := pixels.get_pixel(600,497)
	_check(selected.r > .8 and selected.g > .7 and selected.b < .8, "selected road shader did not draw extruded lane geometry")
	# An ordinary unselected road must retain its colored road bed.
	renderer.map.selected_road_link_id = -1
	renderer._update_materials(800)
	await process_frame
	await RenderingServer.frame_post_draw
	var ordinary := root.get_texture().get_image().get_pixel(600,500)
	_check(ordinary.r < .7 and ordinary.g < .75, "road bed became a white casing")
	_check(absf(ordinary.r - selected.r) > .1, "selection must change road color")
	var publications := renderer.publish_count
	renderer.map.selected_road_link_id = -1
	renderer.map.show_traffic_overlay = true
	renderer.traffic_image.fill(Color(0.1,0.95,0.2))
	renderer.traffic_texture.update(renderer.traffic_image)
	renderer._update_materials(800)
	await process_frame
	await RenderingServer.frame_post_draw
	var traffic := root.get_texture().get_image().get_pixel(600,497)
	_check(traffic.g > .8 and traffic.r < .3, "traffic texture did not recolor retained road geometry")
	_check(renderer.publish_count == publications, "traffic color change uploaded new geometry")
	# An incomplete replacement must leave the displayed mesh alive.
	packet = Geometry.build(renderer.source, Vector3i.ZERO, "roads")
	packet.merge({"part":0,"nodes":[],"bytes":0})
	renderer.uploads.append(packet)
	renderer._publish(Time.get_ticks_usec() - 1)
	_check(renderer.chunks["roads:0:0:0"].nodes[0].visible, "queued replacement cleared displayed coverage")
	# Check regional strokes at the zoom scales in the reported regression.
	renderer.uploads.clear()
	renderer.map.show_traffic_overlay = false
	renderer.source.bounds = Rect2(0,0,16,16)
	packet = Geometry.build(renderer.source, Vector3i.ZERO, "roads")
	packet.merge({"part":0,"nodes":[],"bytes":0})
	renderer.uploads.append(packet)
	renderer._publish(Time.get_ticks_usec() + 1000000)
	for node in renderer.chunks["roads:0:0:0"].nodes:
		node.show()
	for ppk in [45.0,80.0,300.0]:
		renderer.transform = Transform2D(Vector2(ppk,0),Vector2(0,ppk),Vector2(100,100))
		renderer._update_materials(ppk)
		await process_frame
		await RenderingServer.frame_post_draw
		var pixel := root.get_texture().get_image().get_pixel(int(100 + ppk * .5),int(100 + ppk * .5))
		_check(pixel.b > .5 and pixel.r < .7, "regional road lost its color at %s px/km" % ppk)
	print("GPU road extrusion, selection, traffic lookup and retained coverage: ", "PASS" if errors.is_empty() else errors)
	renderer.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok:
		errors.append(message)
		push_error(message)
