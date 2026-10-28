extends Control
var reporter
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO,size),Color("182d39"))
	if reporter==null: return
	var state:Dictionary=reporter.status()
	var packet:Dictionary=state.preview
	if not packet.is_empty():
		var bounds:Rect2=packet.bounds
		var scale:float=minf(size.x/maxf(1,bounds.size.x),size.y/maxf(1,bounds.size.y))*.9
		var offset:Vector2=(size-bounds.size*scale)*.5-bounds.position*scale
		var outline:=PackedVector2Array()
		for point in packet.outline: outline.append(point*scale+offset)
		if outline.size()>2: draw_colored_polygon(outline,Color("548572"))
		var water_lines:=PackedVector2Array()
		for river in packet.get("water",[]):
			_append_lines(water_lines,river,scale,offset)
		if not water_lines.is_empty(): draw_multiline(water_lines,Color("72bacb"),1.0)
		for city in packet.get("cities",[]): draw_circle(city*scale+offset,2.0,Color("e8e3ce"))
		var road_lines:=PackedVector2Array()
		for road in packet.roads: _append_lines(road_lines,road,scale,offset)
		if not road_lines.is_empty(): draw_multiline(road_lines,Color("8ea8bb"),1.0)
	draw_rect(Rect2(Vector2.ZERO,size),Color(0.02,.06,.1,.55))

func _append_lines(lines:PackedVector2Array,path:PackedVector2Array,scale:float,offset:Vector2) -> void:
	if path.size()<2: return
	var previous:Vector2=path[0]*scale+offset
	for i in range(1,path.size()):
		var next:Vector2=path[i]*scale+offset
		if i<path.size()-1 and previous.distance_squared_to(next)<1.0: continue
		lines.append(previous)
		lines.append(next)
		previous=next
