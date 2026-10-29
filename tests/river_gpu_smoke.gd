extends SceneTree
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const River = preload("res://scripts/ui/river_geometry.gd")
const Renderer = preload("res://scripts/ui/map_chunk_renderer.gd")
const Style = preload("res://scripts/ui/map_style.gd")
var errors: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("River GPU test requires a graphical renderer")
		quit(1)
		return
	root.size = Vector2i(1000,1000)
	root.content_scale_size = root.size
	var background := ColorRect.new()
	background.color = Style.LAND
	background.size = Vector2(1000,1000)
	root.add_child(background)
	var feature := {"identity":"river:0","kind":"line","layer":"water","points":PackedVector2Array([Vector2(.2,.1),Vector2(.8,.5),Vector2(.9,.9),Vector2(.4,1.4),Vector2(.9,1.9)]),"widths":PackedFloat32Array([.02,.03,.04,.06,.09]),"meters":90.0,"slot":-2}
	var source := Geometry.index_source({"bounds":Rect2(0,0,2,2),"epoch":1,"features":[feature]})
	for level in [0,2,4]:
		var renderer := Renderer.new()
		root.add_child(renderer)
		renderer.map = {"map_mode":"Roads","show_traffic_overlay":false,"selected_local_street":Vector2i(-1,-1),"selected_road_link_id":-1}
		renderer.epoch = 1
		renderer.source = source
		renderer._setup_traffic()
		renderer.transform = Transform2D(Vector2(400,0),Vector2(0,400),Vector2(200,100))
		renderer._update_materials(400)
		var count: int = 1<<level
		for y in range(count):
			for x in range(count):
				var packet := Geometry.build(source,Vector3i(level,x,y),"water")
				if packet.parts.is_empty(): continue
				packet.merge({"part":0,"nodes":[],"bytes":0})
				renderer.uploads.append(packet)
		renderer._publish(Time.get_ticks_usec()+10000000)
		for chunk in renderer.chunks.values():
			for node in chunk.nodes: node.show()
		await process_frame
		await RenderingServer.frame_post_draw
		var pixels := root.get_texture().get_image()
		var samples := River.segments(feature,source.bounds,256.0*count)
		var holes := 0
		for i in range(samples.size()):
			var segment: Dictionary = samples[i]
			for fraction in [.02,.5,.98]:
				for side in [-.7,0.0,.7]:
					var a: Vector2 = segment.a+segment.na*segment.wa*.5*side
					var b: Vector2 = segment.b+segment.nb*segment.wb*.5*side
					var sample: Vector2 = renderer.transform*a.lerp(b,fraction)
					var color := pixels.get_pixel(floori(sample.x),floori(sample.y))
					if absf(color.r-Style.WATER.r)>.04 or absf(color.b-Style.WATER.b)>.04:
						holes+=1
						if holes<=3: print("River coverage probe ",level,"/",i," at ",sample," side=",side," color=",color)
		if holes>0: errors.append("%d interior water gaps at tile LOD %d" % [holes,level])
		if level==2: pixels.save_png("user://gpu_rivers.png")
		renderer.queue_free()
		await process_frame
	print("GPU river curves and tile coverage: ","PASS" if errors.is_empty() else errors)
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(0 if errors.is_empty() else 1)
