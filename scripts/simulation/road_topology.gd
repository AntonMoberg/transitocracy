extends RefCounted
## Physical road approaches, independent of link splitting and map LOD.
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Nodes = preload("res://scripts/simulation/road_node_data.gd")
const Route = preload("res://scripts/simulation/road_route_builder.gd")
const Terrain = preload("res://scripts/simulation/road_terrain.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const EPS = 0.002
const SHARED_NEAR_KM = 1.0
const SHARED_MIN_KM = 5.0
const SAMPLE_KM = 0.25

static func rank(road_class: String) -> int:
	return {Roads.HIGHWAY: 3, Roads.ARTERIAL: 2, Roads.COLLECTOR: 1}.get(road_class, 0)

static func minimum_radius(road_class: String) -> float:
	return 2.0 if road_class == Roads.HIGHWAY else (0.4 if road_class == Roads.ARTERIAL else 0.15)

static func length(points: PackedVector2Array) -> float:
	var result := 0.0
	for i in range(1, points.size()): result += points[i-1].distance_to(points[i])
	return result

static func sample(points: PackedVector2Array, station: float) -> Dictionary:
	var travelled := 0.0
	for i in range(1, points.size()):
		var distance: float = points[i-1].distance_to(points[i])
		if distance < 0.0000001: continue
		if travelled + distance >= station or i == points.size()-1:
			return {"point": points[i-1].lerp(points[i], clampf((station-travelled)/distance,0,1)), "direction": (points[i]-points[i-1])/distance}
		travelled += distance
	return {"point": points[0] if not points.is_empty() else Vector2.ZERO, "direction": Vector2.ZERO}

static func project(points: PackedVector2Array, point: Vector2) -> Dictionary:
	var result := {"point": Vector2.ZERO, "station": 0.0, "distance": INF, "direction": Vector2.ZERO}
	var travelled := 0.0
	for i in range(1, points.size()):
		var delta: Vector2 = points[i]-points[i-1]
		var distance: float = delta.length()
		if distance < 0.0000001: continue
		var near: Vector2 = Geometry2D.get_closest_point_to_segment(point, points[i-1], points[i])
		var gap: float = near.distance_to(point)
		if gap < result.distance:
			result = {"point": near, "station": travelled+near.distance_to(points[i-1]), "distance": gap, "direction": delta/distance}
		travelled += distance
	return result

static func slice(points: PackedVector2Array, first: float, last: float) -> PackedVector2Array:
	if last < first:
		var reverse := slice(points,last,first)
		reverse.reverse()
		return reverse
	var result := PackedVector2Array([sample(points,first).point])
	var travelled := 0.0
	for i in range(1, points.size()):
		travelled += points[i-1].distance_to(points[i])
		if travelled > first+0.000001 and travelled < last-0.000001: result.append(points[i])
	var end: Vector2 = sample(points,last).point
	if result[-1].distance_to(end)>0.000001: result.append(end)
	return result

static func approaches(region, excluded_id: int = -1) -> Array:
	var result: Array = []
	result.resize(region.road_nodes.size())
	for i in range(result.size()): result[i] = []
	for link in region.road_links:
		if link.id == excluded_id or link.points.size()<2: continue
		var chain := [{"node_id":link.from_node_id,"station_km":0.0}]
		chain.append_array(link.junctions)
		chain.append({"node_id":link.to_node_id,"station_km":link.length_km})
		for i in range(1,chain.size()):
			var a: int = chain[i-1].node_id
			var b: int = chain[i].node_id
			var low: float = chain[i-1].station_km
			var high: float = chain[i].station_km
			if a==b or high-low<0.000001: continue
			result[a].append({"link":link,"station":low,"other_station":high,"other":b,"direction":sample(link.points,low+0.00001).direction})
			result[b].append({"link":link,"station":high,"other_station":low,"other":a,"direction":-sample(link.points,high-0.00001).direction})
	return result

static func settlement_nodes(region) -> Dictionary:
	# Administrative city polygons cover countryside too. Protect only actual
	# urban streets/gates, not an arbitrary positive city_id on a rural node.
	var result := {}
	for node in region.road_nodes:
		if node.is_urban_street: result[node.id]=true
	for link in region.road_links:
		if link.managed_neighborhood_id>=0:
			result[link.from_node_id]=true
			result[link.to_node_id]=true
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout==null: continue
		for node in region.road_nodes:
			if neighborhood.street_layout.bounds.has_point(node.position_km) and Geometry2D.is_point_in_polygon(node.position_km,neighborhood.street_layout.polygon):
				result[node.id]=true
	return result

static func continuation(region, node_id: int, excluded_id: int = -1) -> Vector2:
	if node_id<0: return Vector2.ZERO
	if region.road_nodes[node_id].is_urban_street: return Vector2.ZERO
	var point: Vector2=region.road_nodes[node_id].position_km
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout!=null and neighborhood.street_layout.bounds.has_point(point) and Geometry2D.is_point_in_polygon(point,neighborhood.street_layout.polygon): return Vector2.ZERO
	var arms:=node_approaches(region,node_id,excluded_id)
	return -arms[0].direction if arms.size()==1 else Vector2.ZERO

static func node_approaches(region,node_id:int,excluded_id:int=-1) -> Array:
	var result:=[]
	for link in region.road_links:
		if link.id==excluded_id or link.points.size()<2: continue
		if link.from_node_id==node_id: result.append({"link":link,"direction":sample(link.points,0).direction})
		elif link.to_node_id==node_id: result.append({"link":link,"direction":-sample(link.points,link.length_km).direction})
		else:
			for junction in link.junctions:
				if junction.node_id==node_id:
					result.append({"link":link,"direction":sample(link.points,junction.station_km+0.00001).direction})
					result.append({"link":link,"direction":-sample(link.points,junction.station_km-0.00001).direction})
	return result

static func preferred(first,second) -> bool:
	if rank(first.road_class)!=rank(second.road_class): return rank(first.road_class)>rank(second.road_class)
	if (first.trunk_route_id>=0)!=(second.trunk_route_id>=0): return first.trunk_route_id>=0
	if first.lanes_per_direction!=second.lanes_per_direction: return first.lanes_per_direction>second.lanes_per_direction
	if not is_equal_approx(first.length_km,second.length_km): return first.length_km>second.length_km
	return first.id<second.id

static func structured(link,point:Vector2) -> bool:
	for span in link.terrain_spans:
		if span.kind not in ["Bridge","Tunnel"]: continue
		var path:PackedVector2Array=span.get("points",PackedVector2Array([span.from,span.to]))
		if project(path,point).distance<0.02: return true
	return false

static func shared_runs(region,points:PackedVector2Array,road_class:String,excluded_id:int=-1) -> Array:
	var source=Spatial.cache(region)
	var owner=null
	for link in region.road_links:
		if link.id==excluded_id: owner=link; break
	var runs:=[]
	var current:Dictionary={}
	var total:float=length(points)
	var count:int=ceili(total/SAMPLE_KM)
	var stations_by_link:Dictionary={}
	var travelled:=0.0
	var segment:=1
	for i in range(count+1):
		var station:float=minf(i*SAMPLE_KM,total)
		while segment<points.size()-1 and travelled+points[segment-1].distance_to(points[segment])<station:
			travelled+=points[segment-1].distance_to(points[segment]); segment+=1
		var direction:Vector2=(points[segment]-points[segment-1]).normalized()
		var point:Vector2=points[segment-1]+direction*(station-travelled)
		var cell:=Vector2i(point.floor())
		var seen:Dictionary={}
		var best:Dictionary={}
		for y in range(cell.y-1,cell.y+2):
			for x in range(cell.x-1,cell.x+2):
				var entries:PackedInt32Array=source.segments.get(Vector2i(x,y),PackedInt32Array())
				for e in range(0,entries.size(),2):
					var key:=Vector2i(entries[e],entries[e+1])
					if seen.has(key): continue
					seen[key]=true
					var link=region.road_links[key.x]
					if link.id==excluded_id or link.managed_neighborhood_id>=0 or rank(link.road_class)<rank(road_class): continue
					if owner!=null and not preferred(link,owner): continue
					var a:Vector2=link.points[key.y-1]
					var b:Vector2=link.points[key.y]
					var along:Vector2=(b-a).normalized()
					if absf(along.dot(direction))<cos(deg_to_rad(20.0)): continue
					var near:Vector2=Geometry2D.get_closest_point_to_segment(point,a,b)
					var gap:float=near.distance_to(point)
					if gap>SHARED_NEAR_KM or structured(link,near): continue
					if owner!=null and structured(owner,point): continue
					if best.is_empty() or preferred(link,best.link) or link==best.link and gap<best.distance:
						best={"link":link,"point":near,"distance":gap,"segment":key.y}
		if best.is_empty() or (not current.is_empty() and current.link!=best.link):
			_finish_run(runs,current)
			current={}
		if best.is_empty(): continue
		if not stations_by_link.has(best.link.id):
			var stations:=PackedFloat32Array([0.0])
			for j in range(1,best.link.points.size()): stations.append(stations[-1]+best.link.points[j-1].distance_to(best.link.points[j]))
			stations_by_link[best.link.id]=stations
		var near:Dictionary={"station":stations_by_link[best.link.id][best.segment-1]+best.point.distance_to(best.link.points[best.segment-1])}
		if current.is_empty():
			current={"link":best.link,"first":station,"last":station,"entry":near.station,"exit":near.station}
		else:
			if absf(near.station-current.exit)>SAMPLE_KM*4:
				_finish_run(runs,current)
				current={"link":best.link,"first":station,"last":station,"entry":near.station,"exit":near.station}
			else:
				current.last=station
				current.exit=near.station
	_finish_run(runs,current)
	return runs

static func _finish_run(runs:Array,run:Dictionary) -> void:
	if not run.is_empty() and run.last-run.first>=SHARED_MIN_KM and absf(run.exit-run.entry)>=SHARED_MIN_KM*0.7:
		runs.append(run)

static func rounded(region,points:PackedVector2Array,road_class:String) -> PackedVector2Array:
	var path:=PackedVector2Array()
	for point in points:
		if path.is_empty() or point.distance_to(path[-1])>0.000001: path.append(point)
	if path.size()<3: return path
	var result:=PackedVector2Array([path[0]])
	for i in range(1,path.size()-1):
		var incoming:Vector2=(path[i]-path[i-1]).normalized()
		var outgoing:Vector2=(path[i+1]-path[i]).normalized()
		var turn:float=absf(incoming.angle_to(outgoing))
		if turn<deg_to_rad(8): result.append(path[i]); continue
		if turn>deg_to_rad(170): return PackedVector2Array()
		var radius:float=minimum_radius(road_class)*1.08
		var trim:float=radius*tan(turn*.5)
		if trim>minf(path[i-1].distance_to(path[i]),path[i+1].distance_to(path[i]))*.48: return PackedVector2Array()
		var a:Vector2=path[i]-incoming*trim
		var b:Vector2=path[i]+outgoing*trim
		var handle:float=radius*4.0/3.0*tan(turn*.25)
		result.append(a)
		if not Route._sample_player_curve(region.jurisdictions[0].polygon_km,result,a,a+incoming*handle,b-outgoing*handle,b,0): return PackedVector2Array()
	result.append(path[-1])
	return result

static func fragment(region,link,first:float,last:float,start:Vector2,end:Vector2) -> Dictionary:
	if start.distance_to(end)<EPS and last-first<EPS:
		return {"points":PackedVector2Array(),"elevations_m":PackedFloat32Array(),"terrain_spans":[],"junctions":[],"length_km":0.0}
	var joins: Array[Dictionary]=[]
	for junction in link.junctions:
		if junction.station_km>first+EPS and junction.station_km<last-EPS: joins.append(junction)
	for inset in [0.0,1.0,2.0,4.0,8.0]:
		var a:float=first
		var b:float=last
		if sample(link.points,first).point.distance_to(start)>EPS: a=minf(first+inset,last)
		if sample(link.points,last).point.distance_to(end)>EPS: b=maxf(last-inset,a)
		if not joins.is_empty():
			a=minf(a,joins[0].station_km)
			b=maxf(b,joins[-1].station_km)
		var path:=PackedVector2Array([start])
		if b>a+EPS: path.append_array(slice(link.points,a,b))
		path.append(end)
		path=rounded(region,path,link.road_class)
		if path.size()<2: continue
		var packet:=alignment(region,path,link.road_class,Route.significant_curve_radius(link.points),link.terrain_spans.filter(func(span):return span.kind=="Tunnel"))
		if packet.is_empty(): continue
		var attachments: Array[Dictionary]=[]
		var valid:=true
		for junction in joins:
			var near:=project(path,region.road_nodes[junction.node_id].position_km)
			if near.distance>EPS: valid=false; break
			attachments.append({"node_id":junction.node_id,"station_km":near.station})
		if not valid: continue
		packet["junctions"]=attachments
		return packet
	return {}

static func attach_exact(region,link,node_id:int) -> bool:
	var near:=project(link.points,region.road_nodes[node_id].position_km)
	if near.distance>EPS: return false
	if node_id in [link.from_node_id,link.to_node_id]: return true
	for junction in link.junctions:
		if junction.node_id==node_id: return true
	link.junctions.append({"node_id":node_id,"station_km":near.station})
	link.junctions.sort_custom(func(a,b):return a.station_km<b.station_km)
	return true

static func existing_attachment(link,station:float) -> int:
	if station<EPS: return link.from_node_id
	if station>link.length_km-EPS: return link.to_node_id
	for junction in link.junctions:
		if absf(junction.station_km-station)<0.025: return junction.node_id
	return -1

static func attachment_node(region,link,station:float) -> int:
	var existing:=existing_attachment(link,station)
	if existing>=0: return existing
	var node=Nodes.new()
	node.id=region.road_nodes.size()
	node.position_km=sample(link.points,station).point
	node.city_id=region.city_id_at_point(node.position_km)
	region.road_nodes.append(node)
	attach_exact(region,link,node.id)
	return node.id

static func clone_link(region,original,first:int,last:int,packet:Dictionary,retain_id:bool=false):
	var link=Roads.new()
	for property in original.get_property_list():
		if int(property.usage)&PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value=original.get(property.name)
			link.set(property.name,value.duplicate(true) if typeof(value) in [TYPE_ARRAY,TYPE_DICTIONARY] else value)
	if not retain_id:
		link.id=region.next_road_link_id
		region.next_road_link_id+=1
	link.from_node_id=first
	link.to_node_id=last
	apply_geometry(link,packet)
	var crossings: Array[Dictionary]=[]
	for crossing in original.crossings:
		if project(link.points,crossing.point).distance<EPS: crossings.append(crossing.duplicate(true))
	link.crossings=crossings
	return link

static func consolidate_approaches(region,focus_id:int=-1) -> int:
	# A short shared approach is not an independent parallel corridor. Walk
	# outward from its real connection and move the branch to the divergence.
	# Keep the broad 5 km corridor rule for roads that are not already joined.
	var merged:=0
	var urban:=settlement_nodes(region)
	var checked:Dictionary={}
	for _pass in range(region.road_links.size()):
		var changed:=false
		var all_arms:=approaches(region)
		for node_id in range(all_arms.size()):
			var arms:Array=all_arms[node_id]
			if arms.size()<3: continue
			var edited:=false
			for branch in arms:
				var link=branch.link
				if link.managed_neighborhood_id>=0: continue
				if branch.station>EPS and branch.station<link.length_km-EPS: continue
				for trunk in arms:
					if trunk.link==link or not preferred(trunk.link,link): continue
					if focus_id>=0 and link.id!=focus_id and trunk.link.id!=focus_id: continue
					var key:=Vector3i(node_id,link.id,trunk.link.id)
					if checked.has(key): continue
					checked[key]=true
					if branch.direction.dot(trunk.direction)<cos(deg_to_rad(20)): continue
					var limit:float=minf(absf(branch.other_station-branch.station)-.05,absf(trunk.other_station-trunk.station)-.05)
					var distance:=0.0
					var target_station:float=trunk.station
					for step in range(1,ceili(limit/.025)+1):
						var along:float=minf(step*.025,limit)
						var position:=sample(link.points,branch.station+signf(branch.other_station-branch.station)*along)
						var near:=project(trunk.link.points,position.point)
						if near.distance>.025 or structured(link,position.point) or structured(trunk.link,near.point): break
						if (near.station-trunk.station)*signf(trunk.other_station-trunk.station)<0: break
						if absf(near.station-trunk.station)>absf(trunk.other_station-trunk.station)-.025: break
						distance=along
						target_station=near.station
					if distance<.1: continue
					var target:Vector2=sample(trunk.link.points,target_station).point
					var existing:=existing_attachment(trunk.link,target_station)
					if existing>=0: target=region.road_nodes[existing].position_km
					var packet:Dictionary
					if branch.station<EPS:
						packet=fragment(region,link,distance,link.length_km,target,link.points[-1])
					else:
						packet=fragment(region,link,0,link.length_km-distance,link.points[0],target)
					if packet.is_empty(): continue
					var old_packet:Dictionary={"points":link.points,"elevations_m":link.elevation_profile_m,"terrain_spans":link.terrain_spans.duplicate(true),"junctions":link.junctions.duplicate(true)}
					var old_from:int=link.from_node_id
					var old_to:int=link.to_node_id
					var old_junctions:Array=trunk.link.junctions.duplicate(true)
					var old_node_count:int=region.road_nodes.size()
					var attachment:=attachment_node(region,trunk.link,target_station)
					apply_geometry(link,packet)
					if branch.station<EPS: link.from_node_id=attachment
					else: link.to_node_id=attachment
					var remaining:Array=approaches(region)[node_id]
					var tolerance:float=.25 if remaining.any(func(arm):return arm.link.road_class==Roads.HIGHWAY) else 1.0
					if not urban.has(node_id) and remaining.size()==2 and join_error(remaining)>tolerance and not repair_join(region,node_id,remaining):
						# Moving a fork must not strand an impossible bend behind it.
						apply_geometry(link,old_packet)
						link.from_node_id=old_from
						link.to_node_id=old_to
						trunk.link.junctions.assign(old_junctions)
						region.road_nodes.resize(old_node_count)
						continue
					merged+=1
					changed=true
					edited=true
					break
				if edited: break
			if edited:
				# This pass's arms contain old stations; rebuild before another edit.
				break
		if not changed: break
	if merged>0:
		region.road_geometry_revision+=1
		region.street_spatial_cache={}
	return merged

static func smooth_corners(region,focus_id:int=-1) -> int:
	var smoothed:=0
	var arms:=approaches(region)
	for link in region.road_links:
		if link.managed_neighborhood_id>=0 or (focus_id>=0 and link.id!=focus_id): continue
		var path:=PackedVector2Array([link.points[0]])
		var changed:=false
		for i in range(1,link.points.size()-1):
			var point:Vector2=link.points[i]
			var incoming:Vector2=(point-link.points[i-1]).normalized()
			var outgoing:Vector2=(link.points[i+1]-point).normalized()
			var turn:float=absf(incoming.angle_to(outgoing))
			var protected:=structured(link,point)
			for junction in link.junctions:
				if arms[junction.node_id].size()>=3 and region.road_nodes[junction.node_id].position_km.distance_to(point)<.025: protected=true
			for neighborhood in region.neighborhoods:
				if neighborhood.street_layout!=null and neighborhood.street_layout.bounds.has_point(point) and Geometry2D.is_point_in_polygon(point,neighborhood.street_layout.polygon): protected=true; break
			var radius:float=minimum_radius(link.road_class)*1.08
			var trim:float=radius*tan(turn*.5)
			if protected or turn<deg_to_rad(12) or turn>deg_to_rad(160) or trim>minf(point.distance_to(link.points[i-1]),point.distance_to(link.points[i+1]))*.48:
				path.append(point)
				continue
			var a:Vector2=point-incoming*trim
			var b:Vector2=point+outgoing*trim
			var handle:float=radius*4.0/3.0*tan(turn*.25)
			var curve:=PackedVector2Array([a])
			if not Route._sample_player_curve(region.jurisdictions[0].polygon_km,curve,a,a+incoming*handle,b-outgoing*handle,b,0):
				path.append(point)
				continue
			path.append_array(curve)
			changed=true
		path.append(link.points[-1])
		if not changed: continue
		var packet:=geometry_packet(region,link,path)
		if packet.is_empty(): continue
		apply_geometry(link,packet)
		smoothed+=1
	if smoothed>0:
		region.road_geometry_revision+=1
		region.street_spatial_cache={}
	return smoothed

static func consolidate(region,focus_id:int=-1) -> Dictionary:
	var jobs:=[]
	var roads:Array=region.road_links.duplicate()
	if focus_id>=0:
		# A player preview only needs roads near the requested corridor.
		var candidates:Dictionary={focus_id:true}
		var index:=Spatial.cache(region)
		for focus in roads:
			if focus.id!=focus_id: continue
			for segment in range(1,focus.points.size()):
				var a:Vector2=focus.points[segment-1]
				var b:Vector2=focus.points[segment]
				var count:int=maxi(1,ceili(a.distance_to(b)))
				for sample_index in range(count+1):
					var cell:=Vector2i(a.lerp(b,float(sample_index)/count).floor())
					for y in range(cell.y-1,cell.y+2):
						for x in range(cell.x-1,cell.x+2):
							var entries:PackedInt32Array=index.segments.get(Vector2i(x,y),PackedInt32Array())
							for entry in range(0,entries.size(),2): candidates[region.road_links[entries[entry]].id]=true
		roads=roads.filter(func(link):return candidates.has(link.id))
	roads.sort_custom(preferred)
	for link in roads:
		if link.managed_neighborhood_id>=0 or link.length_km<SHARED_MIN_KM: continue
		var runs:=shared_runs(region,link.points,link.road_class,link.id)
		for run in runs:
			if focus_id>=0 and link.id!=focus_id and run.link.id!=focus_id: continue
			jobs.append({"link":link,"run":run,"target_hash":hash(run.link.points)})
			break
	var merged:=0
	var removed_km:=0.0
	for job in jobs:
		var link=job.link
		var run:Dictionary=job.run
		if not region.road_links.has(run.link) or hash(run.link.points)!=job.target_hash: continue
		var start:Vector2=sample(run.link.points,run.entry).point
		var end:Vector2=sample(run.link.points,run.exit).point
		var entry_node:=existing_attachment(run.link,run.entry)
		var exit_node:=existing_attachment(run.link,run.exit)
		if entry_node>=0: start=region.road_nodes[entry_node].position_km
		if exit_node>=0: end=region.road_nodes[exit_node].position_km
		var prefix:=fragment(region,link,0,run.first,link.points[0],start)
		var suffix:=fragment(region,link,run.last,link.length_km,end,link.points[-1])
		var transfers:=[]
		var valid:=true
		for junction in link.junctions:
			if junction.station_km<run.first-EPS or junction.station_km>run.last+EPS: continue
			var point:Vector2=region.road_nodes[junction.node_id].position_km
			var near:=project(run.link.points,point)
			var packet:=alignment(region,PackedVector2Array([point,near.point]),link.road_class) if near.distance>EPS else {}
			if near.distance>EPS and packet.is_empty(): valid=false; break
			transfers.append({"node":junction.node_id,"station":near.station,"packet":packet})
		if not valid or prefix.is_empty() or suffix.is_empty(): continue
		var first:int=attachment_node(region,run.link,run.entry)
		var last:int=attachment_node(region,run.link,run.exit)
		var replacements:=[]
		if prefix.length_km>EPS: replacements.append(clone_link(region,link,link.from_node_id,first,prefix,true))
		if suffix.length_km>EPS: replacements.append(clone_link(region,link,last,link.to_node_id,suffix,replacements.is_empty()))
		for transfer in transfers:
			if transfer.packet.is_empty(): attach_exact(region,run.link,transfer.node)
			else:
				var target:int=attachment_node(region,run.link,transfer.station)
				replacements.append(clone_link(region,link,transfer.node,target,transfer.packet,false))
		region.road_links.erase(link)
		region.road_links.append_array(replacements)
		removed_km+=run.last-run.first
		merged+=1
	region.road_geometry_revision+=1
	region.street_spatial_cache={}
	if focus_id>=0: merged+=consolidate_approaches(region,focus_id)
	return {"merged":merged,"shared_km":removed_km}

static func join_error(arms: Array) -> float:
	if arms.size()!=2: return 0.0
	# Two samples of one continuous curve are not separate road approaches.
	# Its curvature is checked on the alignment, not the polyline chord angle.
	if arms[0].link==arms[1].link: return 0.0
	return absf(180.0-absf(rad_to_deg(arms[0].direction.angle_to(arms[1].direction))))

static func audit(region, generated: bool = false) -> Dictionary:
	var arms := approaches(region)
	var urban := settlement_nodes(region)
	var ends: Array[int] = []
	var kinks: Array[int] = []
	var attachments: Array[int] = []
	for node in region.road_nodes:
		if urban.has(node.id): continue
		if generated and arms[node.id].size()==1: ends.append(node.id)
		if arms[node.id].size()==2:
			var highway: bool = arms[node.id][0].link.road_class==Roads.HIGHWAY or arms[node.id][1].link.road_class==Roads.HIGHWAY
			if join_error(arms[node.id])>(0.25 if highway else 1.0): kinks.append(node.id)
	for link in region.road_links:
		if link.points.size()<2: continue
		if link.points[0].distance_to(region.road_nodes[link.from_node_id].position_km)>EPS or link.points[-1].distance_to(region.road_nodes[link.to_node_id].position_km)>EPS:
			attachments.append(link.id)
		for junction in link.junctions:
			if sample(link.points,junction.station_km).point.distance_to(region.road_nodes[junction.node_id].position_km)>EPS:
				attachments.append(link.id)
	return {"dead_ends":ends,"kinks":kinks,"attachments":attachments}

static func alignment(region, points: PackedVector2Array, road_class: String, existing_radius:float=INF, tunnels:Array=[]) -> Dictionary:
	if points.size()<2: return {}
	if Route.significant_curve_radius(points)<minf(minimum_radius(road_class),existing_radius)-0.005: return {}
	for i in range(1,points.size()):
		if not Geography.segment_on_land(region.jurisdictions[0].polygon_km,points[i-1],points[i]): return {}
	if region.terrain==null:
		return {"points":points,"elevations_m":PackedFloat32Array(),"terrain_spans":[],"length_km":length(points)}
	return Planner.new(region,1.0)._profile(points,road_class,tunnels)

static func geometry_packet(region, link, points: PackedVector2Array) -> Dictionary:
	# Preserve established terrain-following curves elsewhere on the link.
	# The replacement join itself is checked against the full class radius.
	var packet := alignment(region,points,link.road_class,Route.significant_curve_radius(link.points),link.terrain_spans.filter(func(span):return span.kind=="Tunnel"))
	if packet.is_empty(): return {}
	var junctions: Array[Dictionary] = []
	for junction in link.junctions:
		var near := project(points,region.road_nodes[junction.node_id].position_km)
		if near.distance>EPS: return {}
		junctions.append({"node_id":junction.node_id,"station_km":near.station})
	junctions.sort_custom(func(a,b):return a.station_km<b.station_km)
	packet["junctions"]=junctions
	return packet

static func apply_geometry(link, packet: Dictionary) -> void:
	link.points=packet.points
	link.elevation_profile_m=packet.elevations_m
	link.terrain_spans.assign(packet.terrain_spans)
	link.junctions.assign(packet.get("junctions",[]))
	link.recalculate_length()

static func repair_join(region, node_id: int, arms: Array) -> bool:
	if arms.size()!=2 or arms[0].link==arms[1].link: return false
	var a: Dictionary=arms[0]
	var b: Dictionary=arms[1]
	# Only true endpoint pairs can move together. Interior joins on a single
	# road already have a common tangent; a third arm is a real intersection.
	if a.station>EPS and a.station<a.link.length_km-EPS: return false
	if b.station>EPS and b.station<b.link.length_km-EPS: return false
	var road_class: String=a.link.road_class if rank(a.link.road_class)>=rank(b.link.road_class) else b.link.road_class
	var minimum: float=minimum_radius(road_class)
	var bridge_minimum:float=minf(minimum_radius(a.link.road_class),minimum_radius(b.link.road_class))
	var available_a: float=maxf(0,absf(a.station-a.other_station)-0.005)*0.98
	var available_b: float=maxf(0,absf(b.station-b.other_station)-0.005)*0.98
	var reaches:Array[float]=[minimum*2,minf(available_a,available_b),minimum*4,minimum*8,minimum*16,minimum*32,minimum*64,minimum*128,minimum*256]
	reaches.sort()
	for reach in reaches:
		var cut_a: float=minf(reach,available_a)
		var cut_b: float=minf(reach,available_b)
		if minf(cut_a,cut_b)<EPS: continue
		var sa: float=a.station+signf(a.other_station-a.station)*cut_a
		var sb: float=b.station+signf(b.other_station-b.station)*cut_b
		var start:=sample(a.link.points,sa)
		var finish:=sample(b.link.points,sb)
		var incoming: Vector2=start.direction*signf(a.station-sa)
		var outgoing: Vector2=finish.direction*signf(sb-b.station)
		var joint: Vector2=region.road_nodes[node_id].position_km
		var bridge: PackedVector2Array=Route.build_player(region,start.point,finish.point,road_class,PackedVector2Array([joint]),Route.CURVED,incoming,outgoing)
		if bridge.size()<2 or Route.significant_curve_radius(bridge)<bridge_minimum-0.005:
			# Unequal approaches need unequal handles; a long handle on the
			# short arm can otherwise fold the curve back on itself.
			var best_radius:=0.0
			for factor in [.55,.75,1.0,.35,.3,.32,.4]:
				var trial:=PackedVector2Array([start.point])
				var handle_a:float=minf(start.point.distance_to(joint)*factor,start.point.distance_to(finish.point)*2.0)
				var handle_b:float=minf(finish.point.distance_to(joint)*factor,start.point.distance_to(finish.point)*2.0)
				if not Route._sample_player_curve(region.jurisdictions[0].polygon_km,trial,start.point,start.point+incoming*handle_a,finish.point-outgoing*handle_b,finish.point,0): continue
				var radius:float=Route.significant_curve_radius(trial)
				if radius>best_radius:
					best_radius=radius
					bridge=trial
		if bridge.size()<2 or Route.significant_curve_radius(bridge)<bridge_minimum-0.005: continue
		# Split inside a sampled segment so both stored approach tangents are
		# identical, even when the closest point lies on a curve vertex.
		var middle: float=0.0
		var traveled:=0.0
		var best:=INF
		var middle_index:=1
		var split_target:=joint
		# End the faster road before the lower-speed bend. Otherwise a valid
		# arterial turn can accidentally become part of the highway alignment.
		if a.link.road_class==Roads.HIGHWAY and b.link.road_class!=Roads.HIGHWAY:
			split_target=start.point+incoming*minf(.05,length(bridge)*.1)
		elif b.link.road_class==Roads.HIGHWAY and a.link.road_class!=Roads.HIGHWAY:
			split_target=finish.point-outgoing*minf(.05,length(bridge)*.1)
		for i in range(1,bridge.size()):
			var distance:float=bridge[i-1].distance_to(bridge[i])
			var gap:float=((bridge[i-1]+bridge[i])*.5).distance_squared_to(split_target)
			if distance>=0.002 and gap<best:
				best=gap
				middle=traveled+distance*.5
				middle_index=i
			traveled+=distance
		var joint_point:Vector2=(bridge[middle_index-1]+bridge[middle_index])*.5
		# At state-sized coordinates float32 rounding can put a midpoint
		# off its chord. Symmetric endpoints retain an identical stored tangent.
		var half:Vector2=(bridge[middle_index]-bridge[middle_index-1])*.5
		bridge[middle_index-1]=joint_point-half
		bridge[middle_index]=joint_point+half
		middle=0.0
		for i in range(1,middle_index): middle+=bridge[i-1].distance_to(bridge[i])
		middle+=bridge[middle_index-1].distance_to(joint_point)
		var paths: Array[PackedVector2Array]=[]
		var legal_curves:=true
		for data in [[a,sa,slice(bridge,0,middle)],[b,sb,slice(bridge,middle,length(bridge))]]:
			var arm: Dictionary=data[0]
			var curve: PackedVector2Array=data[2]
			if arm==a: curve.reverse()
			curve[0]=joint_point
			if Route.significant_curve_radius(curve)<minimum_radius(arm.link.road_class)-0.005:
				legal_curves=false
				break
			# curve points away from the new joint towards the untouched road.
			var path: PackedVector2Array=curve
			var rest:=slice(arm.link.points,data[1],arm.link.length_km if arm.station<EPS else 0.0)
			path.append_array(rest.slice(1))
			if arm.station>EPS: path.reverse()
			paths.append(path)
		if not legal_curves: continue
		var first_direction:Vector2=(paths[0][1]-paths[0][0]) if a.station<EPS else (paths[0][-2]-paths[0][-1])
		var second_direction:Vector2=(paths[1][1]-paths[1][0]) if b.station<EPS else (paths[1][-2]-paths[1][-1])
		var error:float=absf(180.0-absf(rad_to_deg(first_direction.angle_to(second_direction))))
		if error>(0.25 if road_class==Roads.HIGHWAY else 1.0): continue
		var first:=geometry_packet(region,a.link,paths[0])
		var second:=geometry_packet(region,b.link,paths[1])
		if first.is_empty() or second.is_empty(): continue
		apply_geometry(a.link,first)
		apply_geometry(b.link,second)
		region.road_nodes[node_id].position_km=joint_point
		region.street_spatial_cache={}
		return true
	return false

static func _trim_leaf(region, arm: Dictionary) -> void:
	var link=arm.link
	if absf(arm.station-arm.other_station)>=link.length_km-EPS:
		region.road_links.erase(link)
		return
	var first: float=arm.other_station if arm.station<EPS else 0.0
	var last: float=arm.other_station if arm.station>EPS else link.length_km
	var path:=slice(link.points,first,last)
	path[0]=region.road_nodes[arm.other if arm.station<EPS else link.from_node_id].position_km
	path[-1]=region.road_nodes[arm.other if arm.station>EPS else link.to_node_id].position_km
	var profile:=Terrain.slice_profile(link.points,link.elevation_profile_m,path)
	link.terrain_spans=Terrain.clip_spans(link.terrain_spans,path,profile)
	link.points=path
	link.elevation_profile_m=profile
	if arm.station<EPS: link.from_node_id=arm.other
	else: link.to_node_id=arm.other
	var kept: Array[Dictionary]=[]
	for junction in link.junctions:
		if junction.node_id==arm.other: continue
		kept.append({"node_id":junction.node_id,"station_km":project(path,region.road_nodes[junction.node_id].position_km).station})
	link.junctions=kept
	link.recalculate_length()

static func _remove_redundant_detour(region,arms:Array) -> bool:
	if arms.size()!=2 or arms[0].link==arms[1].link: return false
	for arm in arms:
		if arm.link.road_class==Roads.HIGHWAY or arm.link.managed_neighborhood_id>=0: return false
	var budget:float=(absf(arms[0].other_station-arms[0].station)+absf(arms[1].other_station-arms[1].station))*1.85
	var graph:=approaches(region)
	var target:int=arms[1].other
	var costs:Dictionary={arms[0].other:0.0}
	var queue:Array=[arms[0].other]
	var cursor:=0
	while cursor<queue.size():
		var id:int=queue[cursor]
		cursor+=1
		if id==target:
			_trim_leaf(region,arms[0])
			_trim_leaf(region,arms[1])
			return true
		for edge in graph[id]:
			if edge.link in [arms[0].link,arms[1].link]: continue
			var cost:float=costs[id]+absf(edge.other_station-edge.station)
			if cost>budget or cost>=costs.get(edge.other,INF): continue
			costs[edge.other]=cost
			queue.append(edge.other)
	return false

static func cleanup(region,depth:int=0) -> Dictionary:
	var corners:=smooth_corners(region)
	var urban:=settlement_nodes(region)
	var pruned:=0
	var repaired:=0
	var removed_detour:=false
	# Unused rural sampling sites must not become arbitrary destinations.
	for _pass in range(region.road_links.size()+1):
		var arms:=approaches(region)
		var changed:=false
		for node_id in range(arms.size()):
			if urban.has(node_id): continue
			# Removing one duplicate can expose another interval of the braid.
			var pair:Array=arms[node_id]
			if pair.size()==2 and pair[0].link!=pair[1].link and pair[0].other==pair[1].other and pair[0].link.road_class!=Roads.HIGHWAY and pair[1].link.road_class!=Roads.HIGHWAY:
				var path:=slice(pair[0].link.points,pair[0].station,pair[0].other_station)
				var other:=slice(pair[1].link.points,pair[1].station,pair[1].other_station)
				var coincident:=true
				for point in path:
					if project(other,point).distance>EPS: coincident=false; break
				if coincident:
					_trim_leaf(region,pair[1])
					changed=true
					break
			if pair.size()!=1: continue
			var arm: Dictionary=arms[node_id][0]
			# A trunk may retain its useful through stretch, but not an unused
			# tail beyond its final interchange.
			if arm.link.road_class==Roads.HIGHWAY and arm.link.junctions.is_empty(): continue
			_trim_leaf(region,arm)
			pruned+=1
			changed=true
			break
		if not changed: break
	for _pass in range(3):
		var arms:=approaches(region)
		var changed:=false
		for node_id in range(arms.size()):
			if urban.has(node_id) or arms[node_id].size()!=2: continue
			var highway: bool=arms[node_id][0].link.road_class==Roads.HIGHWAY or arms[node_id][1].link.road_class==Roads.HIGHWAY
			if join_error(arms[node_id])<=(0.25 if highway else 1.0): continue
			# Earlier repairs may have changed the other end of these links.
			var current:Array=approaches(region)[node_id]
			if repair_join(region,node_id,current):
				repaired+=1
				changed=true
			elif _remove_redundant_detour(region,current):
				removed_detour=true
				pruned+=2
				changed=true
		if not changed: break
	region.road_geometry_revision+=1
	region.street_spatial_cache={}
	if removed_detour and depth<4:
		var next:=cleanup(region,depth+1)
		next.pruned+=pruned
		next.repaired+=repaired
		return next
	var report:=audit(region,true)
	var arms:=approaches(region)
	for node_id in report.kinks.slice(0,8):
		print("Unrepaired join ",node_id,": ",arms[node_id].map(func(a):return [a.link.id,a.link.road_class,a.station,a.other_station,a.other,a.link.from_node_id,a.link.to_node_id,Route.significant_curve_radius(a.link.points)]))
	return {"pruned":pruned,"repaired":repaired,"corners":corners,"audit":report}
