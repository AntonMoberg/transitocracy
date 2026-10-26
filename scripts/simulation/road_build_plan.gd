extends RefCounted
## Detached, priced physical edits. Existing shared road is never built twice.
const Topology=preload("res://scripts/simulation/road_topology.gd")
const Snapshot=preload("res://scripts/simulation/region_snapshot.gd")
const Roads=preload("res://scripts/simulation/road_link_data.gd")
const Nodes=preload("res://scripts/simulation/road_node_data.gd")
const Land=preload("res://scripts/simulation/road_land.gd")
const Terrain=preload("res://scripts/simulation/road_terrain.gd")

static func fingerprint(link) -> int:
	return hash([link.points,link.from_node_id,link.to_node_id,link.road_class,link.lanes_per_direction,link.owner_jurisdiction_id])

static func reserved(region,link_id:int) -> bool:
	for project in region.road_projects:
		if project.build_plan.get("dependencies",{}).has(link_id): return true
	return false

static func endpoint(region,node_id:int,point:Vector2,road_class:String) -> Dictionary:
	if node_id>=0 and node_id<region.road_nodes.size():
		return {"node":node_id,"point":region.road_nodes[node_id].position_km}
	var best:Dictionary={}
	for link in region.road_links:
		if link.managed_neighborhood_id>=0: continue
		var near:=Topology.project(link.points,point)
		if near.distance>0.05 or Topology.structured(link,near.point): continue
		if best.is_empty() or near.distance<best.distance:
			best={"link":link,"point":near.point,"station":near.station,"distance":near.distance}
	if best.is_empty(): return {"node":-1,"point":point,"free":true}
	var link=best.link
	for id in [link.from_node_id,link.to_node_id]:
		if region.road_nodes[id].position_km.distance_to(best.point)<0.025:
			return {"node":id,"point":region.road_nodes[id].position_km}
	for junction in link.junctions:
		if absf(junction.station_km-best.station)<(0.2 if link.road_class==Roads.HIGHWAY else 0.025):
			return {"node":junction.node_id,"point":region.road_nodes[junction.node_id].position_km}
	return {"node":-1,"point":best.point,"link_id":link.id,"station":best.station,"interchange":link.road_class==Roads.HIGHWAY or road_class==Roads.HIGHWAY}

static func _prepare(region,description:Dictionary) -> int:
	var id:int=description.node
	if id<0:
		var node=Nodes.new()
		node.id=region.road_nodes.size()
		node.position_km=description.point
		node.city_id=region.city_id_at_point(node.position_km)
		region.road_nodes.append(node)
		id=node.id
	if description.has("link_id"):
		for link in region.road_links:
			if link.id==description.link_id:
				Topology.attach_exact(region,link,id)
	return id

static func _pack(link) -> Dictionary:
	var data:Dictionary={}
	for property in link.get_property_list():
		if int(property.usage)&PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value=link.get(property.name)
			data[property.name]=value.duplicate(true) if typeof(value) in [TYPE_ARRAY,TYPE_DICTIONARY] else value
	return data

static func preview(source,request:Dictionary,single:Callable,crossings_for_route:Callable) -> Dictionary:
	var region=Snapshot.copy_region(source)
	var road_class:String=request.road_class
	var first:Dictionary=endpoint(region,request.from,request.get("start_position",Vector2.INF),road_class)
	var last:Dictionary=endpoint(region,request.to,request.end_position,road_class)
	if request.from<0 and (not first.has("link_id") and first.get("free",false)):
		return {"ok":false,"reason":"Start on an existing road or junction."}
	if road_class==Roads.HIGHWAY and last.get("free",false):
		return {"ok":false,"reason":"Finish the highway on an existing road or interchange."}
	if request.draw_mode=="Auto" and last.get("free",false):
		return {"ok":false,"reason":"Choose two different road nodes."}
	var from:int=_prepare(region,first)
	var to:int=_prepare(region,last)
	for id in [from,to]:
		for project in source.road_projects:
			if id in [project.from_node_id,project.to_node_id] and Topology.node_approaches(source,id).is_empty():
				return {"ok":false,"reason":"Wait for this road to open before extending its endpoint."}
	if road_class==Roads.HIGHWAY:
		for id in [from,to]:
			if Topology.node_approaches(region,id).is_empty(): return {"ok":false,"reason":"Highways need a road connection at both ends."}
			region.road_nodes[id].is_interchange=true
	var raw:Dictionary=single.call(region,from,to,road_class,request.waypoints,request.day_key,request.draw_mode,last.point,request.crossing_choices)
	if not raw.get("ok",false): return raw
	var proposed=Roads.new()
	proposed.id=region.next_road_link_id
	region.next_road_link_id+=1
	proposed.corridor_id=proposed.id
	proposed.from_node_id=from
	proposed.to_node_id=to
	proposed.road_class=road_class
	proposed.lanes_per_direction=raw.lanes
	proposed.owner_jurisdiction_id=raw.owner_id
	proposed.points=raw.points
	proposed.terrain_spans.assign(raw.terrain_impact.spans)
	proposed.crossings.assign(raw.crossings)
	proposed.recalculate_length()
	region.road_links.append(proposed)
	region.street_spatial_cache={}
	var reuse:=Topology.shared_runs(region,proposed.points,road_class,proposed.id)
	var consolidated:=Topology.consolidate(region,proposed.id)
	if not reuse.is_empty() and consolidated.merged==0:
		return {"ok":false,"reason":"This route duplicates an existing corridor, but its branches cannot join safely. Adjust the guides."}
	var urban:=Topology.settlement_nodes(region)
	var arms:=Topology.approaches(region)
	for id in [from,to]:
		if urban.has(id) or arms[id].size()!=2: continue
		var highway:bool=arms[id][0].link.road_class==Roads.HIGHWAY or arms[id][1].link.road_class==Roads.HIGHWAY
		if Topology.join_error(arms[id])>(0.25 if highway else 1.0) and not Topology.repair_join(region,id,arms[id]):
			return {"ok":false,"reason":"This two-road connection needs a gentler approach. Adjust the route guides."}
	var originals:Dictionary={}
	for link in source.road_links: originals[link.id]=link
	var final_ids:Dictionary={}
	var parts:=[]
	var actions:=[]
	var dependencies:Dictionary={}
	for id in [from,to]:
		if id>=source.road_nodes.size(): continue
		for arm in Topology.node_approaches(source,id): dependencies[arm.link.id]=fingerprint(arm.link)
	var work:=[]
	var cost:=0
	var construction_cost:=0
	var structure_cost:=0
	var build_km:=0.0
	var surface_paths:Array[PackedVector2Array]=[]
	var land_summary:Dictionary={"cost":0,"land_ha":0.0,"land_cost":0,"home_cost":0,"job_cost":0,"site_cost":0,"street_cost":0,"local_bridge_cost":0,"neighborhoods":[],"surface_paths":[]}
	var terrain_summary:Dictionary={"ok":true,"cost":0,"bridge_km":0.0,"tunnel_km":0.0,"earthwork_km":0.0,"max_grade":0.0,"spans":[],"surface_paths":[]}
	var crossing_summary:=[]
	for link in region.road_links:
		final_ids[link.id]=true
		var old=originals.get(link.id)
		if old!=null and old.points==link.points and old.from_node_id==link.from_node_id and old.to_node_id==link.to_node_id:
			for junction in link.junctions:
				if Roads.junction_station(old.junctions,junction.node_id)<0:
					actions.append({"link_id":link.id,"node_id":junction.node_id,"station":junction.station_km})
					dependencies[link.id]=fingerprint(old)
			continue
		parts.append({"link_id":link.id if old!=null else -1,"token":link.id,"data":_pack(link)})
		parts[-1].data.owner_jurisdiction_id=source.road_owner_for_points(link.points,link.road_class)
		parts[-1].data.crossings=crossings_for_route.call(region,link.points,link.road_class,request.crossing_choices,link.id)
		var paths:Array[PackedVector2Array]=[]
		paths.assign([link.points] if old==null else changed_paths(old.points,link.points))
		if old!=null: dependencies[old.id]=fingerprint(old)
		for path in paths:
			if path.size()<2: continue
			var terrain:Dictionary=raw.terrain_impact if old==null and path==raw.points else Terrain.preview(source,path,link.road_class)
			if not terrain.ok: return terrain
			var land:Dictionary=raw.land_impact if old==null and path==raw.points else Land.preview(source,path,link.road_class,terrain.surface_paths)
			var crosses:Array=crossings_for_route.call(region,path,link.road_class,request.crossing_choices,link.id)
			var km:float=Topology.length(path)
			raw.owner_id=source.lowest_common_jurisdiction(raw.owner_id,source.road_owner_for_points(path,link.road_class))
			var construction:int=roundi(km*link.lanes_per_direction*Roads.construction_cost(link.road_class))
			var structures:=0
			for crossing in crosses: structures+=3000000 if crossing.above else 5000000
			cost+=construction+structures+int(land.cost)+int(terrain.cost)
			construction_cost+=construction
			structure_cost+=structures
			build_km+=km
			work.append({"points":path,"road_class":link.road_class,"terrain":terrain,"land":land,"crossings":crosses})
			surface_paths.append_array(terrain.surface_paths)
			for name in ["cost","bridge_km","tunnel_km","earthwork_km"]: terrain_summary[name]+=terrain.get(name,0)
			terrain_summary.max_grade=maxf(terrain_summary.max_grade,terrain.get("max_grade",0.0))
			terrain_summary.spans.append_array(terrain.spans)
			crossing_summary.append_array(crosses)
			for name in ["cost","land_ha","land_cost","home_cost","job_cost","site_cost","street_cost","local_bridge_cost"]:
				land_summary[name]+=land.get(name,0)
			land_summary.neighborhoods.append_array(land.get("neighborhoods",[]))
	var removed:=[]
	for id in originals:
		if not final_ids.has(id):
			removed.append(id)
			dependencies[id]=fingerprint(originals[id])
	var interchanges:Dictionary={}
	for part in parts:
		if part.data.road_class!=Roads.HIGHWAY: continue
		interchanges[part.data.from_node_id]=true
		interchanges[part.data.to_node_id]=true
		for junction in part.data.junctions:
			if arms[junction.node_id].size()>=3: interchanges[junction.node_id]=true
	for id in [from,to]:
		if id>=source.road_nodes.size(): continue
		for arm in Topology.node_approaches(source,id):
			if arm.link.road_class==Roads.HIGHWAY: interchanges[id]=true
	for action in actions:
		for link in source.road_links:
			if link.id==action.link_id and link.road_class==Roads.HIGHWAY: interchanges[action.node_id]=true
	if road_class==Roads.HIGHWAY:
		interchanges[from]=true
		interchanges[to]=true
	for id in interchanges.keys():
		if id<source.road_nodes.size() and source.road_nodes[id].is_interchange: interchanges.erase(id)
	cost+=interchanges.size()*10000000
	structure_cost+=interchanges.size()*10000000
	var nodes:=[]
	var node_moves:=[]
	for id in range(source.road_nodes.size()):
		var before:Vector2=source.road_nodes[id].position_km
		var after:Vector2=region.road_nodes[id].position_km
		if before!=after:
			node_moves.append({"id":id,"before":before,"after":after,"arms":Topology.node_approaches(source,id).size()})
	for id in range(source.road_nodes.size(),region.road_nodes.size()):
		nodes.append({"id":id,"point":region.road_nodes[id].position_km})
	var reused:=[]
	for run in reuse:
		reused.append({"link_id":run.link.id,"from_station":run.entry,"to_station":run.exit,"points":Topology.slice(run.link.points,run.entry,run.exit)})
		if originals.has(run.link.id): dependencies[run.link.id]=fingerprint(originals[run.link.id])
	for id in dependencies:
		if reserved(source,id): return {"ok":false,"reason":"Finish construction on the shared road before changing this connection."}
	if cost==0: return {"ok":false,"reason":"This road connection already exists."}
	land_summary.surface_paths=surface_paths
	terrain_summary.surface_paths=surface_paths
	var days:int=maxi(int(raw.days),5 if not interchanges.is_empty() else 0)
	raw.merge({"from":request.from,"to":request.to,"end_position":last.point,"length_km":build_km,"cost":cost,"construction_cost":construction_cost,"structure_cost":structure_cost,"land_impact":land_summary,"days":days,"open_day_key":request.day_key+days},true)
	raw.terrain_impact=terrain_summary
	raw.crossings=crossing_summary
	raw["build_plan"]={"revision":source.road_geometry_revision,"from":from,"to":to,"nodes":nodes,"parts":parts,"remove_ids":removed,"junction_actions":actions,"interchanges":interchanges.keys(),"reused_intervals":reused,"dependencies":dependencies,"work":work,"request":request.duplicate(true)}
	raw.build_plan["node_moves"]=node_moves
	return raw

static func changed_paths(original:PackedVector2Array,path:PackedVector2Array) -> Array[PackedVector2Array]:
	var result:Array[PackedVector2Array]=[]
	var current:=PackedVector2Array()
	for i in range(1,path.size()):
		var a:Vector2=path[i-1]
		var b:Vector2=path[i]
		var changed:bool=Topology.project(original,a).distance>Topology.EPS or Topology.project(original,b).distance>Topology.EPS or Topology.project(original,(a+b)*.5).distance>Topology.EPS
		if changed:
			if current.is_empty(): current.append(a)
			current.append(b)
		elif not current.is_empty():
			result.append(current)
			current=PackedVector2Array()
	if not current.is_empty(): result.append(current)
	return result

static func remap(plan:Dictionary,node_map:Dictionary) -> void:
	for part in plan.parts:
		for key in ["from_node_id","to_node_id"]: part.data[key]=node_map.get(part.data[key],part.data[key])
		for junction in part.data.junctions: junction.node_id=node_map.get(junction.node_id,junction.node_id)
	for action in plan.junction_actions: action.node_id=node_map.get(action.node_id,action.node_id)
	for i in range(plan.interchanges.size()): plan.interchanges[i]=node_map.get(plan.interchanges[i],plan.interchanges[i])

static func valid_dependencies(region,plan:Dictionary) -> bool:
	var preserved_nodes:Dictionary={}
	for part in plan.parts:
		preserved_nodes[part.data.from_node_id]=true
		preserved_nodes[part.data.to_node_id]=true
		for junction in part.data.junctions: preserved_nodes[junction.node_id]=true
	for action in plan.junction_actions: preserved_nodes[action.node_id]=true
	for move in plan.get("node_moves",[]):
		if move.id>=region.road_nodes.size() or region.road_nodes[move.id].position_km!=move.before: return false
		if Topology.node_approaches(region,move.id).size()!=move.arms: return false
	var links:Dictionary={}
	for link in region.road_links: links[link.id]=link
	for id in plan.dependencies:
		if not links.has(id) or fingerprint(links[id])!=plan.dependencies[id]: return false
	for id in plan.remove_ids:
		for junction in links[id].junctions:
			if not preserved_nodes.has(junction.node_id): return false
	for part in plan.parts:
		if part.link_id<0: continue
		var link=links.get(part.link_id)
		if link==null: return false
		for junction in link.junctions:
			if not preserved_nodes.has(junction.node_id) and Topology.project(part.data.points,region.road_nodes[junction.node_id].position_km).distance>Topology.EPS: return false
	return true

static func open(region,project) -> bool:
	var plan:Dictionary=project.build_plan
	if not valid_dependencies(region,plan):
		if not region.dev_mode: region.jurisdictions[project.owner_jurisdiction_id].treasury+=project.cost
		region.road_project_notice="Road project cancelled and refunded: a connecting road changed. Preview the route again."
		Land.release_project(region,project.id)
		return false
	var replacements:=[]
	var ids:Dictionary={}
	for part in plan.parts:
		var link=Roads.new()
		for name in part.data: link.set(name,part.data[name])
		# A junction added during construction may still fit the replacement.
		# Keep it, with its station recomputed on the final alignment.
		if part.link_id>=0:
			for existing in region.road_links:
				if existing.id!=part.link_id: continue
				link.toll_forward=existing.toll_forward
				link.toll_reverse=existing.toll_reverse
				for junction in existing.junctions:
					if Roads.junction_station(link.junctions,junction.node_id)>=0: continue
					var near:=Topology.project(link.points,region.road_nodes[junction.node_id].position_km)
					if near.distance>Topology.EPS: continue # Preserved by another branch or attachment.
					link.junctions.append({"node_id":junction.node_id,"station_km":near.station})
				link.junctions.sort_custom(func(a,b):return a.station_km<b.station_km)
		if part.link_id<0:
			link.id=region.next_road_link_id
			region.next_road_link_id+=1
			link.corridor_id=link.id
		ids[part.token]=link.id
		replacements.append(link)
	# All validation precedes mutation; existing routes stay open until now.
	for move in plan.get("node_moves",[]):
		region.road_nodes[move.id].position_km=move.after
	for part in plan.parts:
		if part.link_id>=0: Land.release_link(region,part.link_id)
	for id in plan.remove_ids: Land.release_link(region,id)
	var remove:Dictionary={}
	for id in plan.remove_ids: remove[id]=true
	for part in plan.parts:
		if part.link_id>=0: remove[part.link_id]=true
	for i in range(region.road_links.size()-1,-1,-1):
		if remove.has(region.road_links[i].id): region.road_links.remove_at(i)
	region.road_links.append_array(replacements)
	for link in replacements:
		for crossing in link.crossings: crossing.link_id=ids.get(crossing.link_id,crossing.link_id)
	plan["opened_corridors"]=[]
	for link in replacements:
		if link.road_class!=Roads.HIGHWAY and not plan.opened_corridors.has(link.corridor_id): plan.opened_corridors.append(link.corridor_id)
	for action in plan.junction_actions:
		for link in region.road_links:
			if link.id==ids.get(action.link_id,action.link_id): Topology.attach_exact(region,link,action.node_id)
	for id in plan.interchanges:
		region.road_nodes[id].is_interchange=true
		region.road_nodes[id].interchange_owner_jurisdiction_id=project.owner_jurisdiction_id
	Land.release_project(region,project.id)
	for link in replacements:
		var paths:Array[PackedVector2Array]=[]
		paths.assign(Terrain.surface_paths(region,link.points,link.road_class) if region.terrain!=null else [link.points])
		region.road_reservations.append(Land._reservation(link.points,link.road_class,link.id,-1,paths))
	for neighborhood in region.neighborhoods: Land._recalculate_neighborhood(region,neighborhood)
	for item in plan.work:
		var rebuild=project.get_script().new()
		rebuild.road_class=item.road_class
		rebuild.points=item.points
		rebuild.open_day_key=project.open_day_key
		rebuild.terrain_surface_paths.assign(item.terrain.surface_paths)
		rebuild.redevelopment_impact.assign(item.land.get("neighborhoods",[]))
		Land.rebuild_project(region,rebuild)
	region.street_spatial_cache={}
	return true
