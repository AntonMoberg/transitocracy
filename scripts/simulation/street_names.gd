extends RefCounted
const NAMES=["Oak","Cedar","Willow","Maple","Elm","Ash","Birch","Pine","Laurel","Walnut","Chestnut","Juniper","Magnolia","Sycamore","Linden","Acacia","Meadow","Garden","Park","Hill","River","Lake","Valley","Forest","Sunset","Spring","North","South","East","West","Central","Market"]

static func local_key(city_id:int,path:PackedVector2Array) -> String:
	var direction:Vector2=(path[-1]-path[0]).normalized()
	if direction.x<-.00001 or absf(direction.x)<.00001 and direction.y<0: direction=-direction
	var angle:int=roundi(direction.angle()*180.0/PI)
	var normal:Vector2=Vector2.from_angle(deg_to_rad(angle)).orthogonal()
	return "city:%d:line:%d:%d" % [city_id,angle,roundi(path[0].dot(normal)*500.0)]

static func label(seed_value:int,key:String,avenue:bool=false) -> String:
	var value:int=posmod(hash("%d:%s" % [seed_value,key]),1048576)
	return "%s%s %s" % [["","Upper ","Lower ","North ","South ","East ","West ","Old "][(value/NAMES.size())%8],NAMES[value%NAMES.size()],"Avenue" if avenue else "Street"]

static func assign(region) -> void:
	for road in region.road_links:
		if not road.street_id.is_empty(): continue
		if road.managed_neighborhood_id>=0:
			road.street_id=local_key(region.neighborhoods[road.managed_neighborhood_id].city_id,road.points)
		else:
			road.street_id="corridor:%d" % (road.corridor_id if road.corridor_id>=0 else road.id)
		road.street_name=label(region.generation_seed,road.street_id,road.road_class=="Arterial" and road.managed_neighborhood_id<0)
	for n in region.neighborhoods:
		if n.street_layout!=null: assign_layout(region.generation_seed,n.street_layout)

static func assign_layout(seed_value:int,layout) -> void:
	for edge_id in range(layout.edges.size()):
		var edge:Vector2=layout.edges[edge_id]
		var path:PackedVector2Array=layout.edge_paths.get(edge_id,PackedVector2Array([layout.nodes[int(edge.x)],layout.nodes[int(edge.y)]]))
		var key:=local_key(layout.city_id,path)
		if not layout.street_names.has(key): layout.street_names[key]=label(seed_value,key)
