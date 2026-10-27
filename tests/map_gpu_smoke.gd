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
	renderer.queue_free()
	await process_frame
	await _street_detail_pixels()
	await _tile_metadata_pixels()
	var log_path:=OS.get_user_data_dir()+"/logs/godot.log"
	var arguments:=OS.get_cmdline_args()
	var log_argument:=arguments.find("--log-file")
	if log_argument>=0 and log_argument+1<arguments.size(): log_path=arguments[log_argument+1]
	if FileAccess.file_exists(log_path):
		_check(not FileAccess.get_file_as_string(log_path).contains("ERROR:"),"Godot logged an engine or shader error during the GPU regression")
	print("GPU roads, retained coverage, junction detail and flat buildings: ", "PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)

func _street_detail_pixels() -> void:
	var renderer:=Renderer.new()
	root.add_child(renderer)
	renderer.map={"map_mode":"Roads","show_traffic_overlay":false,"selected_local_street":Vector2i(-1,-1),"selected_road_link_id":-1}
	renderer.epoch=1
	var features:Array=[]
	for path in [PackedVector2Array([Vector2(.01,.06),Vector2(.06,.06),Vector2(.11,.06)]),PackedVector2Array([Vector2(.06,.01),Vector2(.06,.06),Vector2(.06,.11)])]:
		features.append({"identity":"street:%d" % features.size(),"kind":"line","layer":"roads","points":path,"urban":true,"lanes":1,"style":1,"slot":features.size()})
	var footprint:=PackedVector2Array([Vector2(.02,.02),Vector2(.035,.02),Vector2(.035,.04),Vector2(.02,.04)])
	features.append({"identity":"building:fixture","kind":"building_inventory","layer":"buildings","points":footprint,"footprints":[footprint],"color":Color.RED,"constructing":false})
	renderer.source=Geometry.index_source({"bounds":Rect2(0,0,.12,.12),"epoch":1,"terrain":null,"features":features})
	renderer.traffic_slots={0:0,1:1}
	renderer._setup_traffic()
	renderer.transform=Transform2D(Vector2(8000,0),Vector2(0,8000),Vector2(100,100))
	renderer._update_materials(8000)
	for layer in Renderer.LAYERS:
		var packet:=Geometry.build(renderer.source,Vector3i.ZERO,layer)
		packet.merge({"part":0,"nodes":[],"bytes":0})
		renderer.uploads.append(packet)
	renderer._publish(Time.get_ticks_usec()+1000000)
	for entry in renderer.chunks.values():
		for node in entry.nodes: node.show()
	await process_frame
	await RenderingServer.frame_post_draw
	var pixels:=root.get_texture().get_image()
	pixels.save_png("user://gpu_street_detail.png")
	var crossing:=pixels.get_pixel(633,555)
	var center:=pixels.get_pixel(580,580)
	var building:=pixels.get_pixel(300,300)
	_check(crossing.r>.9 and crossing.g>.9,"interior collector junction must render white crosswalk pixels")
	_check(center.r<.8,"centerline must not continue through the junction")
	_check(building.b>.85 and absf(building.r-building.g)<.03,"Map building fill must be flat and neutral regardless of zone")
	# Retained chunks can contain many meshes each. Exceed the old global
	# instance-uniform allocation limit, not just the chunk-cache limit.
	var line_part:Dictionary=Geometry.build(renderer.source,Vector3i.ZERO,"roads").parts[0]
	var fill_part:Dictionary=Geometry.build(renderer.source,Vector3i.ZERO,"buildings").parts[0]
	var stress_parts:Array=[]
	for i in range(8192): stress_parts.append(line_part if i%2==0 else fill_part)
	var stress:Dictionary={"key":Vector3i.ZERO,"layer":"roads","epoch":1,"parts":stress_parts,"part":0,"nodes":[],"bytes":0,"buildings":0,"streets":0,"districts":0}
	renderer.uploads.append(stress)
	while not renderer.uploads.is_empty():
		renderer._publish(Time.get_ticks_usec()+1000)
		await process_frame
	_check(renderer.chunks["roads:0:0:0"].nodes.size()==8192,"stress fixture must retain 8192 mesh instances")
	for node in renderer.chunks["roads:0:0:0"].nodes:
		node.position=Vector2(2,2)
		node.show()
	for frame in range(4):
		await process_frame
		await RenderingServer.frame_post_draw
	print("Retained mesh stress: 8192 line/fill meshes published and rendered")
	renderer.queue_free()
	await process_frame

func _check(ok: bool, message: String) -> void:
	if not ok:
		errors.append(message)
		push_error(message)

func _tile_metadata_pixels() -> void:
	# Check both byte lanes and the high coordinate bits at maximum LOD.
	for key in [Vector3i(10,513,517),Vector3i(18,135679,196611)]:
		var renderer:=Renderer.new()
		root.add_child(renderer)
		renderer.map={"map_mode":"Roads","show_traffic_overlay":false,"selected_local_street":Vector2i(-1,-1),"selected_road_link_id":-1}
		renderer.epoch=1
		var extent:=Rect2(0,0,.12,.12)
		var tile:=Geometry.tile_rect(extent,key)
		var y:=tile.get_center().y
		renderer.source=Geometry.index_source({"bounds":extent,"epoch":1,"terrain":null,"features":[{"identity":"clip-test","kind":"line","layer":"roads","points":PackedVector2Array([Vector2(0,y),Vector2(.12,y)]),"slot":0,"lanes":1,"highway":false}]})
		renderer.traffic_slots={0:0}
		renderer._setup_traffic()
		var ppk:float=400.0/tile.size.x
		renderer.transform=Transform2D(Vector2(ppk,0),Vector2(0,ppk),Vector2(600,500)-tile.get_center()*ppk)
		renderer._update_materials(ppk)
		var packet:=Geometry.build(renderer.source,key,"roads")
		packet.merge({"part":0,"nodes":[],"bytes":0})
		renderer.uploads.append(packet)
		renderer._publish(Time.get_ticks_usec()+1000000)
		for entry in renderer.chunks.values():
			for node in entry.nodes: node.show()
		await process_frame
		await RenderingServer.frame_post_draw
		var pixels:=root.get_texture().get_image()
		var inside:=pixels.get_pixel(600,500)
		var outside:=pixels.get_pixel(850,500)
		_check(inside.b>.6 and inside.r<.85,"encoded tile address failed at level %d" % key.x)
		_check(absf(outside.b-inside.b)>.15,"line extrusion leaked outside encoded tile bounds at level %d" % key.x)
		renderer.queue_free()
		await process_frame
