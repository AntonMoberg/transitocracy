extends SceneTree
const Topology=preload("res://scripts/simulation/road_topology.gd")
const Region=preload("res://scripts/simulation/region_data.gd")
const Jurisdiction=preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNode=preload("res://scripts/simulation/road_node_data.gd")
const Link=preload("res://scripts/simulation/road_link_data.gd")
const Generator=preload("res://scripts/simulation/road_network_generator.gd")
var errors: Array[String]=[]
func _initialize() -> void:
	var query_path:=PackedVector2Array([Vector2(1400,500),Vector2(1400,500),Vector2(1401,502),Vector2(1406,501),Vector2(1410,507)])
	var query:=Topology.PathQuery.new(query_path)
	for i in range(101):
		var station:float=Topology.length(query_path)*i/100.0
		var expected:Dictionary=Topology.sample(query_path,station)
		var actual:Dictionary=query.sample_at(station)
		_check(expected.point.distance_to(actual.point)<.00001 and expected.direction.distance_to(actual.direction)<.00001,"cached path sampling must match reference")
		var point:=Vector2(1398+i*.15,504)
		expected=Topology.project(query_path,point)
		actual=query.project_at(point)
		_check(expected.point.distance_to(actual.point)<.00001 and absf(expected.station-actual.station)<.00001,"cached path projection must match reference")
	var region=Region.new()
	var state=Jurisdiction.new()
	state.id=0
	state.polygon_km=PackedVector2Array([Vector2(-50,-50),Vector2(50,-50),Vector2(50,50),Vector2(-50,50)])
	state.bounds_km=Rect2(-50,-50,100,100)
	region.jurisdictions.append(state)
	for point in [Vector2(-10,0),Vector2.ZERO,Vector2(0,10),Vector2(10,0)]:
		var node=RoadNode.new()
		node.id=region.road_nodes.size()
		node.position_km=point
		region.road_nodes.append(node)
	_add(region,0,1)
	_add(region,1,2)
	var arms:=Topology.approaches(region)
	_check(arms[1].size()==2 and Topology.join_error(arms[1])>89,"two links must be a sharp continuation, not a junction")
	_check(Topology.repair_join(region,1,arms[1]),"a rural elbow must become a smooth connection")
	Topology.refresh_approaches(region,arms,region.road_links.duplicate())
	_check(arms==Topology.approaches(region),"incremental connections must match a full rebuild after geometry repair")
	var result:=Topology.audit(region)
	_check(result.kinks.is_empty() and result.attachments.is_empty(),"repair must keep geometry and graph aligned")
	_add(region,1,3)
	_check(Topology.approaches(region)[1].size()==3,"a real third arm permits an intersection")
	# A junction inside one unsplit link contributes two distinct approaches.
	var trunk=region.road_links[0]
	var middle=RoadNode.new()
	middle.id=region.road_nodes.size()
	middle.position_km=Topology.sample(trunk.points,trunk.length_km*.5).point
	region.road_nodes.append(middle)
	trunk.junctions.append({"node_id":middle.id,"station_km":trunk.length_km*.5})
	Topology.refresh_approaches(region,arms,region.road_links.duplicate())
	_check(arms==Topology.approaches(region),"incremental connections must match new links and interior junctions")
	var saved_points:PackedVector2Array=trunk.points.duplicate()
	trunk.points=PackedVector2Array([trunk.points[0],trunk.points[-1]])
	trunk.recalculate_length()
	Topology.refresh_approaches(region,arms,[trunk])
	_check(arms==Topology.approaches(region),"incremental connections must match edited geometry")
	trunk.points=saved_points
	trunk.recalculate_length()
	Topology.refresh_approaches(region,arms,[trunk])
	_check(arms==Topology.approaches(region),"incremental connections must match rolled-back geometry")
	_check(Topology.approaches(region)[middle.id].size()==2,"interior stations must count both through approaches")
	_check(Topology.join_error(Topology.approaches(region)[middle.id])<.01,"an unsplit through road must be continuous")
	# Float32 world coordinates must not turn a shared sampled chord into a kink.
	var distant=Region.new()
	var distant_state=Jurisdiction.new()
	distant_state.id=0
	distant_state.polygon_km=PackedVector2Array([Vector2(1400,400),Vector2(1600,400),Vector2(1600,600),Vector2(1400,600)])
	distant_state.bounds_km=Rect2(1400,400,200,200)
	distant.jurisdictions.append(distant_state)
	for point in [Vector2(1490,500),Vector2(1500,500),Vector2(1501,510)]:
		var node=RoadNode.new()
		node.id=distant.road_nodes.size()
		node.position_km=point
		distant.road_nodes.append(node)
	_add(distant,0,1)
	_add(distant,1,2)
	_check(Topology.repair_join(distant,1,Topology.approaches(distant)[1]),"large-coordinate bend must repair")
	_check(Topology.audit(distant).kinks.is_empty() and Topology.audit(distant).attachments.is_empty(),"large-coordinate joins must remain continuous")
	# A long approach turning into a short arm needs balanced cut distances
	# and a handle longer than a fixed fraction of the endpoint chord.
	distant_state.polygon_km=PackedVector2Array([Vector2.ZERO,Vector2(2000,0),Vector2(2000,1000),Vector2(0,1000)])
	var joint:=Vector2(967.2219,313.7845)
	var first_id:int=distant.road_nodes.size()
	for point in [joint-Vector2(-.133312,.991074)*10.0,joint,joint+Vector2(-.486633,-.873607)*.4814]:
		var node=RoadNode.new()
		node.id=distant.road_nodes.size()
		node.position_km=point
		distant.road_nodes.append(node)
	_add(distant,first_id,first_id+1)
	_add(distant,first_id+1,first_id+2)
	distant.road_links[-1].road_class=Link.COLLECTOR
	distant.road_links[-2].road_class=Link.COLLECTOR
	_check(Topology.repair_join(distant,first_id+1,Topology.approaches(distant)[first_id+1]),"asymmetric hairpin must preserve a legal rural radius")
	_check(Topology.join_error(Topology.approaches(distant)[first_id+1])<=1.0,"repaired hairpin must share one approach tangent")
	var transition_id:int=distant.road_nodes.size()
	for point in [Vector2(1000,390),Vector2(1000,400),Vector2(1001,398)]:
		var node=RoadNode.new()
		node.id=distant.road_nodes.size()
		node.position_km=point
		distant.road_nodes.append(node)
	_add(distant,transition_id,transition_id+1)
	distant.road_links[-1].road_class=Link.HIGHWAY
	_add(distant,transition_id+1,transition_id+2)
	_check(Topology.repair_join(distant,transition_id+1,Topology.approaches(distant)[transition_id+1]),"highway must transition smoothly before a lower-speed arterial bend")
	_check(Topology.Route.significant_curve_radius(distant.road_links[-2].points)>=1.995,"transition must retain highway curvature limits")
	_check(Topology.join_error(Topology.approaches(distant)[transition_id+1])<=.25,"mixed-class transition must have a common tangent")
	var corner=Region.new()
	corner.jurisdictions.append(state)
	for point in [Vector2(-5,0),Vector2(0,5),Vector2(5,0)]:
		var node=RoadNode.new()
		node.id=corner.road_nodes.size()
		node.position_km=point
		corner.road_nodes.append(node)
	_add(corner,0,1)
	corner.road_links[0].points=PackedVector2Array([Vector2(-5,0),Vector2.ZERO,Vector2(0,5)])
	corner.road_links[0].recalculate_length()
	_check(Topology.smooth_corners(corner)==1,"a sharp vertex inside one road must be rounded")
	_check(Topology.Route.significant_curve_radius(corner.road_links[0].points)>=.395,"internal corner must respect arterial radius")
	_check(Topology.audit(corner).attachments.is_empty(),"internal smoothing must preserve endpoints")
	# Two outgoing roads share only 700 m, below the broad corridor threshold.
	corner.road_links.clear()
	corner.road_nodes[0].position_km=Vector2.ZERO
	corner.road_nodes[1].position_km=Vector2(5,0)
	corner.road_nodes[2].position_km=Vector2(2,3)
	_add(corner,0,1)
	_add(corner,0,2)
	corner.road_links[1].road_class=Link.COLLECTOR
	corner.road_links[1].points=PackedVector2Array([Vector2.ZERO,Vector2(.7,0),Vector2(2,3)])
	corner.road_links[1].recalculate_length()
	# A third arm makes the original attachment a real intersection.
	var approach=RoadNode.new()
	approach.id=corner.road_nodes.size()
	approach.position_km=Vector2(-5,0)
	corner.road_nodes.append(approach)
	_add(corner,3,0)
	_check(Topology.consolidate_approaches(corner)==1,"short coincident approaches must branch at divergence")
	_check(corner.road_links[1].from_node_id!=0,"branch must leave the old upstream junction")
	_check(corner.road_links[1].points[0].x>.65,"connection must move to the actual divergence")
	_check(Topology.audit(corner).attachments.is_empty(),"short overlap consolidation must preserve exact attachments")
	var gates:Array[Dictionary]=[
		{"point":Vector2(0,0),"city":0,"tangent":Vector2.LEFT},
		{"point":Vector2(0,1),"city":0,"tangent":Vector2.RIGHT},
		{"point":Vector2(10,0),"city":-1,"tangent":Vector2.ZERO}]
	_check(Generator._facing_city_site(gates,0,Vector2(10,0))==1,"incoming road must choose a facing city gate instead of looping around the nearest backward gate")
	_check(Generator._facing_city_site(gates,2,Vector2.ZERO)==2,"rural sites must retain their original attachment")
	print("Road topology fixtures: ","PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _add(region,a:int,b:int) -> void:
	var link=Link.new()
	link.id=region.next_road_link_id
	region.next_road_link_id+=1
	link.from_node_id=a
	link.to_node_id=b
	link.points=PackedVector2Array([region.road_nodes[a].position_km,region.road_nodes[b].position_km])
	link.recalculate_length()
	region.road_links.append(link)
func _check(ok:bool,message:String) -> void:
	if not ok: errors.append(message)
