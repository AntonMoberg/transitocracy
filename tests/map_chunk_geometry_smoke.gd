extends SceneTree
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const Renderer = preload("res://scripts/ui/map_chunk_renderer.gd")
var failures := 0
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var points := PackedVector2Array([Vector2(0, 5), Vector2(2, 5.01), Vector2(5, 5), Vector2(10, 5)])
	var simplified := Geometry.simplify(points, 0.1)
	_check(simplified.size() == 2 and simplified[0] == points[0] and simplified[-1] == points[-1], "simplification preserves endpoints")
	var pinned := Geometry.simplify(points, 1.0, PackedInt32Array([1]))
	_check(pinned.has(points[1]), "junction vertices survive simplification")
	var polygon := PackedVector2Array([Vector2(-2,-2),Vector2(12,-2),Vector2(12,12),Vector2(-2,12)])
	var clipped := Geometry.clip_polygon(polygon, Rect2(0,0,10,10))
	_check(clipped.size() == 4 and Geometry.bounds(clipped) == Rect2(0,0,10,10), "polygon clipping preserves complete tile coverage")
	var source := {"bounds": Rect2(0,0,16,16), "epoch": 9, "terrain": null, "features": [{"kind":"line", "layer":"roads", "points":points, "lanes":2, "highway":true, "slot":41}, {"kind":"block", "layer":"water", "points":polygon, "color":Color.BLUE}]}
	source = Geometry.index_source(source)
	var prepared:Dictionary=source.features[0]
	var distant:=Geometry.simplify(prepared.points,10.0,prepared.fixed)
	_check(distant.has(points[1]) and distant.has(points[-2]),"distant LOD must retain both road approach tangents")
	var result := Geometry.build(source, Vector3i.ZERO, "roads")
	_check(result.epoch == 9 and not result.parts.is_empty(), "worker returns versioned road geometry")
	for part in result.parts:
		_check(part.vertices.size() <= Geometry.MAX_VERTICES, "publication chunks are bounded")
		_check(part.vertices.size() == part.uv.size() and part.vertices.size() == part.colors.size() and part.sides.size() == part.vertices.size(), "mesh attributes have matching sizes")
	_check(result.parts[0].line, "line metadata uses floating-point attributes")
	var road_bed := false
	for part in result.parts:
		_check(part.line, "regional roads must not contain oversized arrow polygons")
		for attributes in part.colors:
			road_bed = road_bed or attributes.a == 4.0
			_check(attributes.a not in [2.0,3.0], "subpixel lanes must not replace a solid road stroke")
	_check(road_bed, "regional roads retain a solid colored road bed")
	var left := Geometry.build(source, Vector3i(1,0,0), "water")
	var right := Geometry.build(source, Vector3i(1,1,0), "water")
	_check(not left.parts.is_empty() and not right.parts.is_empty(), "cross-tile polygon is present on both sides")
	var unchanged := Geometry.index_source({"bounds":source.bounds, "features":[{"kind":"line", "layer":"roads", "points":points, "lanes":2, "highway":true, "slot":41}, {"kind":"block", "layer":"water", "points":polygon, "color":Color.BLUE}], "previous":source.fingerprints})
	_check(unchanged.changed.is_empty(), "identical snapshots do not invalidate chunks")
	var removed := Geometry.index_source({"bounds":source.bounds, "features":[], "previous":source.fingerprints})
	_check(removed.changed.has("roads") and removed.changed.has("water"), "removed features invalidate their former coverage")
	var buffer := Geometry.new_buffer()
	var parts: Array = []
	for i in range(Geometry.MAX_VERTICES / 3 + 2):
		Geometry.emit_triangle(buffer, parts, [Vector2.ZERO,Vector2.RIGHT,Vector2.DOWN], [Vector2.ZERO,Vector2.ZERO,Vector2.ZERO], Color.WHITE)
	Geometry.flush(buffer, parts)
	_check(parts.size() == 2 and parts[0].vertices.size() == Geometry.MAX_VERTICES, "large features split into bounded uploads")
	var renderer := Renderer.new()
	renderer.epoch = 2
	var stale := Thread.new()
	stale.start(func() -> Dictionary: return {"epoch":1})
	while stale.is_alive():
		await process_frame
	renderer.workers.append({"thread":stale, "kind":"index", "epoch":1})
	renderer._poll_workers()
	_check(renderer.source.is_empty() and renderer.discarded_count == 1, "stale worker completion cannot replace the active source")
	renderer.source = {"bounds":Rect2(0,0,16,16)}
	renderer.target_level = 5
	renderer.visible_world = Rect2(4,4,1,1)
	renderer._select_chunks(1000)
	var destination_jobs := 0
	for request in renderer.requests.values():
		_check(request.key.x in [0,5], "zooming must not queue intermediate LOD levels")
		if request.key.x == 5:
			destination_jobs += 1
	_check(destination_jobs > 0, "destination detail is requested immediately")
	renderer.free()
	var streets:Dictionary={"features":[]}
	for path in [PackedVector2Array([Vector2(-.1,0),Vector2.ZERO]),PackedVector2Array([Vector2.ZERO,Vector2(.1,0)]),PackedVector2Array([Vector2.ZERO,Vector2(0,.1)])]:
		streets.features.append({"identity":"local:%s" % streets.features.size(),"layer":"roads","kind":"line","points":path,"local":true,"lanes":1,"street_name":"Oak Street"})
	preload("res://scripts/ui/street_detail_geometry.gd").prepare(streets)
	_check(streets.features.any(func(f):return f.layer=="junctions"),"three-arm urban junction gets connected pavement")
	_check(streets.features.any(func(f):return f.identity.begins_with("crosswalk:")),"urban junction gets pedestrian crossings")
	for feature in streets.features:
		if ":center:" in feature.identity:
			_check(not feature.points.has(Vector2.ZERO),"centerlines stop before junction interiors")
	var names=preload("res://scripts/simulation/street_names.gd")
	_check(names.local_key(0,PackedVector2Array([Vector2(-.1,0),Vector2.ZERO]))==names.local_key(0,PackedVector2Array([Vector2(.1,0),Vector2.ZERO])),"street identity survives segmentation and reversed geometry")
	print("Chunk geometry: ", "PASS" if failures == 0 else "FAIL")
	quit(1 if failures else 0)
func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
