extends SceneTree
const Terrain=preload("res://scripts/simulation/terrain_data.gd")

func exhaustive(terrain,point:Vector2) -> float:
	var level:=INF
	for river in terrain.rivers:
		var line:PackedVector2Array=river.points
		var widths:PackedFloat32Array=river.get("widths_km",PackedFloat32Array())
		for i in range(1,line.size()):
			var radius:float=(widths[i-1]+widths[i])*.25 if widths.size()==line.size() else float(river.width_km)*.5
			var closest:=Geometry2D.get_closest_point_to_segment(point,line[i-1],line[i])
			if point.distance_to(closest)<=radius:
				var delta:Vector2=line[i]-line[i-1]
				var fraction:=clampf((closest-line[i-1]).dot(delta)/maxf(delta.length_squared(),.000001),0,1)
				level=minf(level,lerpf(river.levels[i-1],river.levels[i],fraction))
	return level

func _initialize() -> void:
	var terrain=Terrain.new()
	var points:=PackedVector2Array()
	var levels:=PackedFloat32Array()
	var widths:=PackedFloat32Array()
	var queries:=PackedVector2Array()
	for i in range(300):
		var p:=Vector2(i-150,sin(i*.13)*3.0)
		points.append(p); levels.append(400-i); widths.append(.10+(i%4)*.12)
		queries.append(p)
		queries.append(p+Vector2(.3,.1))
		queries.append(p+Vector2(0,.8))
	terrain.rivers.append({"points":points,"levels":levels,"widths_km":widths,"width_km":.2})
	terrain.rivers.append({"points":PackedVector2Array([Vector2(-2,-2),Vector2(2,2),Vector2(2,2)]),"levels":PackedFloat32Array([10,5,5]),"width_km":1.2})
	queries.append_array(PackedVector2Array([Vector2(0,0),Vector2(2.6,2),Vector2(-1.9,0),Vector2(400,400)]))
	terrain.index_rivers()
	var expected:=PackedFloat64Array()
	var started:=Time.get_ticks_usec()
	for point in queries: expected.append(exhaustive(terrain,point))
	var full_us:=Time.get_ticks_usec()-started
	started=Time.get_ticks_usec()
	var errors:=PackedStringArray()
	for i in range(queries.size()):
		var actual:float=terrain.river_surface_at(queries[i])
		if actual!=expected[i] and (is_inf(actual) or is_inf(expected[i]) or absf(actual-expected[i])>.00001):
			errors.append("Indexed water query differs at %s"%queries[i])
	print("River queries: exhaustive %.2f ms, indexed %.2f ms"%[full_us/1000.0,(Time.get_ticks_usec()-started)/1000.0])
	# Reindexing must replace old entries and retain dry terrain behavior.
	terrain.rivers.clear()
	terrain.index_rivers()
	if not is_inf(terrain.river_surface_at(Vector2.ZERO)): errors.append("Stale river index")
	if not errors.is_empty(): push_error("; ".join(errors))
	else: print("Segment index matches exhaustive queries across bends, widths, boundaries and confluences.")
	quit(1 if not errors.is_empty() else 0)
