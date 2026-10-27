extends RefCounted
var placements:Array=[]
var stamp:=""
var center:=Vector2.INF
func draw(map,pen) -> void:
	var ppk:float=map._map_scale()*map.zoom
	if ppk<500 or map.map_mode=="Trips": return
	var renderer=map.chunk_renderer
	var source:Dictionary=renderer.source
	if source.is_empty(): return
	var camera:Vector2=map._screen_to_world(map.size*.5)
	var next_stamp:="%d:%d" % [source.epoch,roundi(log(ppk)/log(1.08))]
	var font:Font=map.get_theme_default_font()
	if next_stamp!=stamp or camera.distance_to(center)*ppk>32:
		stamp=next_stamp; center=camera
		placements.clear()
		var view:Rect2=renderer.visible_world
		var candidates:Array=[]
		var grid:Dictionary=source.get("label_grid",{})
		var first:=Vector2i((view.position/.25).floor())
		var last:=Vector2i((view.end/.25).floor())
		for y in range(first.y,last.y+1):
			for x in range(first.x,last.x+1): candidates.append_array(grid.get(Vector2i(x,y),[]))
		candidates.sort_custom(func(a,b):return int(a.local)<int(b.local) if a.local!=b.local else a.identity<b.identity)
		var boxes:Array[Rect2]=[]
		var names:Dictionary={}
		for candidate in candidates:
			if placements.size()>=120: break
			if candidate.local and ppk<1000: continue
			var width:float=font.get_string_size(candidate.name,HORIZONTAL_ALIGNMENT_LEFT,-1,13).x
			if candidate.length*ppk<width+20: continue
			var point:Vector2=map._world_to_screen(candidate.point)
			if not Rect2(Vector2(15,45),map.size-Vector2(30,90)).has_point(point): continue
			if names.has(candidate.name) and point.distance_to(names[candidate.name])<350: continue
			var direction:Vector2=candidate.direction
			var size:Vector2=Vector2(absf(direction.x)*width+absf(direction.y)*18,absf(direction.y)*width+absf(direction.x)*18)+Vector2(12,12)
			var box:=Rect2(point-size*.5,size)
			if boxes.any(func(other):return other.intersects(box)): continue
			boxes.append(box); names[candidate.name]=point
			var placed:Dictionary=candidate.duplicate()
			placed["width"]=width
			placements.append(placed)
	for item in placements:
		var angle:float=item.direction.angle()
		if angle>PI*.5: angle-=PI
		if angle<-PI*.5: angle+=PI
		pen.draw_set_transform(map._world_to_screen(item.point),angle)
		pen.draw_string_outline(font,Vector2(-item.width*.5,4),item.name,HORIZONTAL_ALIGNMENT_LEFT,-1,13,2,Color("f9f9f7"))
		pen.draw_string(font,Vector2(-item.width*.5,4),item.name,HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color("56636d"))
	pen.draw_set_transform(Vector2.ZERO)
