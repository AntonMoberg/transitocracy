extends SceneTree
const Layer = preload("res://scripts/ui/map_terrain_layer.gd")
const TileBuilder = preload("res://scripts/ui/terrain_detail_tile.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
const Style = preload("res://scripts/ui/map_style.gd")
var errors: Array[String] = []
class FieldTerrain:
	extends RefCounted
	func visual_elevation_at(_point: Vector2) -> float: return 100.0
	func land_cover_at(point: Vector2, _elevation: float, _gradient: Vector2) -> Vector3:
		return Vector3(clampf(point.x / 2.0, 0, 1), 0, 0)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	root.size = Vector2i(1000,800)
	root.content_scale_size = root.size
	var background := ColorRect.new()
	background.color = Style.WATER
	background.size = Vector2(1000,800)
	root.add_child(background)
	var layer := Layer.new()
	root.add_child(layer)
	var maker := RegionMap.new()
	var terrain := FieldTerrain.new()
	# Concave coast: a bay enters an otherwise rectangular land tile.
	var land := PackedVector2Array([Vector2(0,0),Vector2(4,0),Vector2(4,3),Vector2(2.8,3),Vector2(2.8,1.6),Vector2(2.2,1.6),Vector2(2.2,3),Vector2(0,3)])
	var base_data := TileBuilder.render(terrain,land,Vector2.ZERO,4.0/128.0,true)
	var tile := Layer.Tile.new()
	tile.map = {"show_terrain_overlay":false,"show_slope_overlay":false,"show_contours":false}
	tile.rect = Rect2(0,0,4,4)
	tile.textures = {"map_mesh":maker._cartographic_mesh(base_data),"map_field":ImageTexture.create_from_image(base_data.map_field)}
	layer.add_child(tile)
	tile.configure(layer.land_material)
	var mesh = tile.ground.mesh
	for ppk in [150.0,300.0,600.0]:
		layer.transform = Transform2D(Vector2(ppk,0),Vector2(0,ppk),Vector2(80,600-3*ppk))
		await process_frame
		await RenderingServer.frame_post_draw
		var pixels := root.get_texture().get_image()
		# Coast remains exactly at y=600, including while stretching the base.
		_check(_distance(pixels.get_pixel(100,603),Style.WATER)<.015,"coarse coast leaks into water at %s ppk" % ppk)
		_check(_distance(pixels.get_pixel(100,597),Style.LAND)<.015,"land fades into water at %s ppk" % ppk)
		# Woodland starts at x=.6 km. Only the immediate AA pixel may blend.
		var edge := roundi(80+.6*ppk)
		_check(_distance(pixels.get_pixel(edge-3,570),Style.LAND)<.015,"land-cover edge is blurred on land side")
		_check(_distance(pixels.get_pixel(edge+3,570),Style.WOODS)<.015,"land-cover edge is blurred on woods side")
		_check(tile.ground.mesh==mesh,"zoom recreated coastline mesh")
		if ppk==150:
			_check(_distance(pixels.get_pixel(455,500),Style.WATER)<.015,"concave bay must stay water")
		pixels.save_png("user://shore_%d.png" % ppk)
	# Terrain relief uses the same sharp coastline as the plain Map.
	var rasters := TileBuilder.render(terrain,land,Vector2.ZERO,4.0/128.0)
	for name in ["terrain", "slope", "contours"]:
		tile.textures[name] = ImageTexture.create_from_image(rasters[name])
	tile.map.show_terrain_overlay = true
	tile.configure(layer.land_material)
	await process_frame
	await RenderingServer.frame_post_draw
	var relief := root.get_texture().get_image()
	_check(_distance(relief.get_pixel(100,603),Style.WATER)<.015,"Terrain leaks beyond coast")
	_check(_distance(relief.get_pixel(100,597),relief.get_pixel(100,570))<.015,"Terrain fades at coast")
	# Adjacent gutters must evaluate the same world coordinates.
	var left := TileBuilder.render_field(terrain,Rect2(0,0,2,2),Vector2i(128,128))
	var right := TileBuilder.render_field(terrain,Rect2(2,0,2,2),Vector2i(128,128))
	for y in range(130):
		_check(left.get_pixel(128,y)==right.get_pixel(0,y) and left.get_pixel(129,y)==right.get_pixel(1,y),"land-cover gutter seam")
	maker.free()
	print("GPU coastline and land-cover sharpness: ", "PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _distance(a:Color,b:Color) -> float:
	return Vector3(a.r-b.r,a.g-b.g,a.b-b.b).length()
func _check(ok:bool,message:String) -> void:
	if not ok: errors.append(message)
