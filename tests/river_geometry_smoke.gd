extends SceneTree
const River = preload("res://scripts/ui/river_geometry.gd")
const Geometry = preload("res://scripts/ui/map_geometry.gd")
var errors: Array[String] = []

func _initialize() -> void:
	var original := PackedVector2Array([Vector2(.2,.1),Vector2(.8,.5),Vector2(.9,.9),Vector2(.4,1.4),Vector2(.4,1.4),Vector2(.9,1.9)])
	var feature := {"identity":"river:0","kind":"line","layer":"water","points":original,"widths":PackedFloat32Array([.02,.03,.04,.06,.06,.09]),"meters":90.0,"slot":-2}
	River.prepare(feature)
	_check(feature.points.size()==original.size()-1 and original.size()==6,"Duplicate cleanup must not modify simulation geometry")
	var rect := Rect2(0,0,2,2)
	var low := River.segments(feature,rect,50)
	var high := River.segments(feature,rect,2000)
	_check(high.size()>low.size(),"Zoomed rivers need additional curve detail")
	_check(high[0].a==original[0] and high[-1].b==original[-1],"River endpoints must remain anchored")
	for i in range(high.size()):
		var segment: Dictionary = high[i]
		_check(segment.na.is_finite() and segment.nb.is_finite(),"Invalid river normals")
		_check(segment.wa>0 and segment.wb>0,"River width must stay positive")
		var nearest := INF
		for j in range(1,original.size()): nearest=minf(nearest,segment.a.distance_to(Geometry2D.get_closest_point_to_segment(segment.a,original[j-1],original[j])))
		_check(nearest<=.09*.35+.00001,"Render smoothing moved outside the physical channel envelope")
		if i==0: continue
		var previous: Dictionary = high[i-1]
		_check(previous.b==segment.a and previous.nb.is_equal_approx(segment.na) and is_equal_approx(previous.wb,segment.wa),"River strip has disconnected geometry or width jumps")
	var source := Geometry.index_source({"bounds":rect,"epoch":1,"features":[feature]})
	for key in [Vector3i.ZERO,Vector3i(2,1,1)]:
		var built := Geometry.build(source,key,"water")
		_check(not built.parts.is_empty(),"River tile must contain geometry")
		for part in built.parts:
			_check(part.vertices.size()<=Geometry.MAX_VERTICES,"River uploads exceed mesh budget")
			_check(part.colors.size()==part.vertices.size() and part.styles.size()==part.vertices.size()*4,"River vertex attributes are incomplete")
	# Adjacent tiles must tessellate their common strip identically.
	var left := River.segments(feature,Rect2(0,0,.75,2),2000)
	var right := River.segments(feature,Rect2(.75,0,1.25,2),2000)
	var shared := 0
	for first in left:
		for second in right:
			if first.a==second.a and first.b==second.b:
				shared+=1
				_check(first==second,"Neighboring river tiles disagree on their common geometry")
	_check(shared>0,"River fixture must cross a tile boundary")
	# A bank can enter a tile whose bounds do not contain the centerline.
	var wide := {"identity":"wide","kind":"line","layer":"water","points":PackedVector2Array([Vector2(.9,.1),Vector2(.9,1.9)]),"meters":400.0,"slot":-2}
	var wide_source := Geometry.index_source({"bounds":rect,"epoch":1,"features":[wide]})
	_check(not Geometry.build(wide_source,Vector3i(2,2,1),"water").parts.is_empty(),"River bank was culled outside its centerline tile")
	var empty := {"points":PackedVector2Array([Vector2.ONE,Vector2.ONE]),"meters":20.0}
	River.prepare(empty)
	_check(River.segments(empty,rect,2000).is_empty(),"Degenerate river generated geometry")
	var long_path := PackedVector2Array()
	for i in range(5000): long_path.append(Vector2(i*.2,sin(i*.05)*.3))
	var long_feature := {"points":long_path,"meters":30.0}
	River.prepare(long_feature)
	var started := Time.get_ticks_usec()
	var local_segments := River.segments(long_feature,Rect2(499,-.5,1,1),8000)
	_check(not local_segments.is_empty() and local_segments.size()<200,"A small river tile tessellated distant portions of the river")
	print("Long-river tile: ",local_segments.size()," segments, ",(Time.get_ticks_usec()-started)/1000.0," ms")
	print("River geometry: ","PASS" if errors.is_empty() else errors,"; samples ",low.size()," -> ",high.size())
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(0 if errors.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message): errors.append(message)
