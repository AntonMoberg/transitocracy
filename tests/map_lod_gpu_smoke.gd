extends SceneTree
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const Renderer = preload("res://scripts/ui/map_chunk_renderer.gd")
const Style = preload("res://scripts/ui/map_style.gd")
var errors: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test requires a GPU renderer")
		quit(1)
		return
	root.size = Vector2i(1000,900)
	root.content_scale_size = root.size
	var renderer := Renderer.new()
	root.add_child(renderer)
	renderer.map = {"base_map_style":"Map","map_mode":"Roads","show_traffic_overlay":false,"selected_local_street":Vector2i(-1,-1),"selected_road_link_id":-1}
	var features := []
	for style in range(5):
		var y: float = .4 + style * .8
		features.append({"identity":"road:%d"%style,"kind":"line","layer":"roads","points":PackedVector2Array([Vector2(.1,y),Vector2(3.9,y)]),"slot":style,"style":style,"local":style==0,"highway":style==4,"min_ppk":Style.road_range(style).x,"fade":Style.road_range(style)})
		renderer.traffic_slots[style] = style
	features.append({"identity":"clearance:0","kind":"block","layer":"clearance","points":PackedVector2Array([Vector2(.5,0),Vector2(3.5,0),Vector2(3.5,.1),Vector2(.5,.1)]),"color":Color("24343b")})
	renderer.epoch = 1
	renderer.source = Geometry.index_source({"bounds":Rect2(0,0,4,4),"epoch":1,"features":features})
	renderer._setup_traffic()
	var packet := Geometry.build(renderer.source,Vector3i.ZERO,"roads")
	packet.merge({"part":0,"nodes":[],"bytes":0})
	renderer.uploads.append(packet)
	var clearance := Geometry.build(renderer.source,Vector3i.ZERO,"clearance")
	clearance.merge({"part":0,"nodes":[],"bytes":0})
	renderer.uploads.append(clearance)
	renderer._publish(Time.get_ticks_usec()+1000000)
	for entry in renderer.chunks.values():
		for node in entry.nodes: node.show()
	var publications: int = renderer.publish_count
	for ppk in [8.0,16.0,40.0,80.0,150.0,8.0]:
		renderer.transform = Transform2D(Vector2(ppk,0),Vector2(0,ppk),Vector2(100,100))
		renderer._update_materials(ppk)
		await process_frame
		await RenderingServer.frame_post_draw
		var pixels := root.get_texture().get_image()
		var background := pixels.get_pixel(20,20)
		for style in range(5):
			var sample := pixels.get_pixel(roundi(100+2*ppk),roundi(100+(.4+style*.8)*ppk))
			var visible: bool = sample.r-background.r > .1
			var expected: bool = Style.visibility(ppk,Style.road_range(style)) > .05
			_check(visible==expected,"GPU visibility differs from picking: style %d, ppk %s" % [style,ppk])
		_check(renderer.publish_count==publications,"zoom visibility caused mesh publication")
	renderer.map.selected_road_link_id = 0
	renderer._update_materials(8)
	await process_frame
	await RenderingServer.frame_post_draw
	var selected := root.get_texture().get_image().get_pixel(116,103)
	_check(selected.r>.75,"selected street must remain visible in cached mesh")
	renderer.transform = Transform2D(Vector2(150,0),Vector2(0,150),Vector2(100,100))
	renderer._update_materials(150)
	await process_frame
	await RenderingServer.frame_post_draw
	var verge := root.get_texture().get_image().get_pixel(400,108)
	_check(verge.r > .8 and verge.b > .8,"Map road-clearance masks must not draw dark asphalt strips")
	print("GPU live cartographic LOD: ","PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
