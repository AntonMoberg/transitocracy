extends RefCounted
const Section=preload("res://scripts/simulation/street_cross_section.gd")
const Topology=preload("res://scripts/simulation/road_topology.gd")

static func node_key(point:Vector2) -> Vector2i:
	return Vector2i((point*1000.0).round())

static func offset_path(path:PackedVector2Array,offset:float) -> PackedVector2Array:
	var result:=PackedVector2Array()
	for i in range(path.size()):
		var direction:Vector2=(path[mini(i+1,path.size()-1)]-path[maxi(0,i-1)]).normalized()
		result.append(path[i]+direction.orthogonal()*offset)
	return result

static func separated_at(feature:Dictionary,point:Vector2) -> bool:
	for span in feature.get("terrain_spans",[]):
		if span.kind not in ["Bridge","Tunnel"]: continue
		var path:PackedVector2Array=span.get("points",PackedVector2Array([span.from,span.to]))
		for i in range(1,path.size()):
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point,path[i-1],path[i]))<.001: return true
	return false

static func prepare(source:Dictionary) -> void:
	var roads:Array=[]
	var nodes:Dictionary={}
	var additions:Array=[]
	var label_grid:Dictionary={}
	for f in source.features:
		if f.layer!="roads" or f.kind!="line" or f.get("highway",false) or f.get("separated",false): continue
		roads.append(f)
		var half:float=Section.carriageway("Local" if f.get("local",false) else "Arterial",f.get("lanes",1))*.0005
		# Managed collector paths can contain through-junction vertices rather
		# than separate links. Register their arms alongside endpoint arms.
		for index in range(1,f.points.size()-1):
			var point:Vector2=f.points[index]
			if separated_at(f,point): continue
			var key:=node_key(point)
			if not nodes.has(key): nodes[key]={"point":point,"arms":[],"urban":false,"half":half}
			var node:Dictionary=nodes[key]
			node.urban=node.urban or f.get("urban",false) or f.get("local",false)
			node.half=maxf(node.half,half)
			for direction in [(f.points[index-1]-point).normalized(),(f.points[index+1]-point).normalized()]:
				if not node.arms.any(func(arm):return arm.direction.dot(direction)>.995): node.arms.append({"direction":direction,"half":half})
		for junction in f.get("junctions",[]):
			var station:float=junction.station_km
			var sample:=Topology.sample(f.points,station)
			if separated_at(f,sample.point): continue
			var key:=node_key(sample.point)
			if not nodes.has(key): nodes[key]={"point":sample.point,"arms":[],"urban":false,"half":half}
			nodes[key].urban=nodes[key].urban or f.get("urban",false) or f.get("local",false)
			nodes[key].half=maxf(nodes[key].half,half)
			for direction in [sample.direction,-Topology.sample(f.points,maxf(0,station-.00001)).direction]:
				if not nodes[key].arms.any(func(arm):return arm.direction.dot(direction)>.995): nodes[key].arms.append({"direction":direction,"half":half})
		for index in [0,f.points.size()-1]:
			var point:Vector2=f.points[index]
			if separated_at(f,point): continue
			var direction:Vector2=(f.points[1]-point).normalized() if index==0 else (f.points[index-1]-point).normalized()
			var key:=node_key(point)
			if not nodes.has(key): nodes[key]={"point":point,"arms":[],"urban":false,"half":half}
			var node:Dictionary=nodes[key]
			if not node.arms.any(func(arm):return arm.direction.dot(direction)>.995): node.arms.append({"direction":direction,"half":half})
			node.urban=node.urban or f.get("local",false) or f.get("urban",false)
			node.half=maxf(node.half,half)
		if f.get("urban",false) or f.get("local",false):
			additions.append({"identity":f.identity+":walk","kind":"line","layer":"sidewalks","points":f.points,"meters":half*2000.0+4.0,"slot":-8,"min_ppk":500.0})
		var name:String=f.get("street_name","")
		if name.is_empty(): continue
		for segment in range(1,f.points.size()):
			var a:Vector2=f.points[segment-1]
			var b:Vector2=f.points[segment]
			var distance:float=a.distance_to(b)
			if distance<.025: continue
			var steps:int=maxi(1,ceili(distance/.25))
			for step in range(steps):
				var point:Vector2=a.lerp(b,(step+.5)/steps)
				var cell:=Vector2i((point/.25).floor())
				if not label_grid.has(cell): label_grid[cell]=[]
				label_grid[cell].append({"point":point,"direction":(b-a).normalized(),"length":distance/steps,"name":name,"local":f.get("local",false),"identity":f.identity})
	for f in roads:
		if not f.get("urban",false) and not f.get("local",false): continue
		var points:PackedVector2Array=f.points
		var length:=Topology.length(points)
		var start:Dictionary=nodes.get(node_key(points[0]),{})
		var end:Dictionary=nodes.get(node_key(points[-1]),{})
		var low:float=start.half+.006 if start.get("arms",[]).size()>=3 else 0.0
		var high:float=length-(end.half+.006 if end.get("arms",[]).size()>=3 else 0.0)
		if high<=low: continue
		var gaps:Array=[]
		var station:=0.0
		for index in range(1,points.size()-1):
			station+=points[index-1].distance_to(points[index])
			var node:Dictionary=nodes.get(node_key(points[index]),{})
			if node.get("arms",[]).size()>=3: gaps.append(Vector2(station-node.half-.006,station+node.half+.006))
		for junction in f.get("junctions",[]):
			var node:Dictionary=nodes.get(node_key(Topology.sample(points,junction.station_km).point),{})
			if node.get("arms",[]).size()>=3: gaps.append(Vector2(junction.station_km-node.half-.006,junction.station_km+node.half+.006))
		gaps.sort_custom(func(a,b):return a.x<b.x)
		gaps.append(Vector2(high,high))
		for gap in gaps:
			if gap.x>low:
				var path:=Topology.slice(points,low,minf(high,gap.x))
				additions.append({"identity":f.identity+":center:%s" % low,"kind":"line","layer":"street_details","points":path,"meters":.12,"slot":-6,"min_ppk":2000.0})
				for side in [-1.0,1.0]:
					for lane in range(1,f.get("lanes",1)):
						var lane_path:=offset_path(path,side*(lane*3.25+.35)*.001)
						additions.append({"identity":f.identity+":lane:%s:%s:%d" % [low,side,lane],"kind":"line","layer":"street_details","points":lane_path,"meters":.12,"slot":-7,"min_ppk":2000.0})
			low=maxf(low,gap.y)
	for key in nodes:
		var node:Dictionary=nodes[key]
		if not node.urban or node.arms.size()<3: continue
		var circle:=PackedVector2Array()
		for i in range(24): circle.append(node.point+Vector2.from_angle(i*TAU/24.0)*(node.half+.0005))
		additions.append({"identity":"junction:%s" % key,"kind":"block","layer":"junctions","points":circle,"color":Color("aebdcd"),"min_ppk":500.0})
		var arms:Array=node.arms.duplicate()
		arms.sort_custom(func(a,b):return a.direction.angle()<b.direction.angle())
		for i in range(arms.size()):
			var a:Dictionary=arms[i]
			var b:Dictionary=arms[(i+1)%arms.size()]
			if absf(a.direction.dot(b.direction))>.3 or a.direction.cross(b.direction)<=0: continue
			var corner:Vector2=node.point+a.direction*b.half+b.direction*a.half
			var radius:float=minf(.002,minf(a.half,b.half)*.75)
			var patch:=PackedVector2Array([corner])
			for step in range(9):
				var t:float=step/8.0
				patch.append(corner+a.direction*radius*(1-t)*(1-t)+b.direction*radius*t*t)
			additions.append({"identity":"curb:%s:%d" % [key,i],"kind":"block","layer":"junctions","points":patch,"color":Color("aebdcd"),"min_ppk":500.0})
		for arm_id in range(node.arms.size()):
			var arm:Dictionary=node.arms[arm_id]
			var direction:Vector2=arm.direction
			var normal:=direction.orthogonal()
			var center:Vector2=node.point+direction*(node.half+.003)
			var stripes:int=floori(arm.half*2.0/.0009)
			for stripe in range(stripes):
				var p:Vector2=center+normal*((stripe+.5)*.0009-arm.half)
				var polygon:=PackedVector2Array([p-direction*.0015-normal*.000225,p+direction*.0015-normal*.000225,p+direction*.0015+normal*.000225,p-direction*.0015+normal*.000225])
				additions.append({"identity":"crosswalk:%s:%d:%d" % [key,arm_id,stripe],"kind":"block","layer":"street_details","points":polygon,"color":Color("f5f5f2"),"min_ppk":2000.0})
	source.features.append_array(additions)
	source["label_grid"]=label_grid
