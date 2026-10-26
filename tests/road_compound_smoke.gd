extends SceneTree

const Region=preload("res://scripts/simulation/region_data.gd")
const Area=preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNode=preload("res://scripts/simulation/road_node_data.gd")
const Link=preload("res://scripts/simulation/road_link_data.gd")
const Planner=preload("res://scripts/simulation/road_planner.gd")
const Topology=preload("res://scripts/simulation/road_topology.gd")
const Snapshot=preload("res://scripts/simulation/region_snapshot.gd")
const Land=preload("res://scripts/simulation/road_land.gd")
var errors:Array[String]=[]

func _initialize() -> void:
	var region=_region()
	var trunk=_link(region,[Vector2(-30,0),Vector2(30,0)],Link.HIGHWAY)
	Land.initialize(region)
	var before:PackedVector2Array=trunk.points.duplicate()
	var preview:=Planner.link_preview(region,-1,-1,Link.ARTERIAL,PackedVector2Array(),0,"Straight",Vector2(0,10),{},Vector2.ZERO)
	_check(preview.get("ok",false),"road-interior endpoint must create a compound preview: %s" % preview.get("reason",""))
	if preview.get("ok",false):
		_check(preview.cost==preview.construction_cost+preview.structure_cost+preview.terrain_impact.cost+preview.land_impact.cost,"preview must price only its actual construction and connections")
		_check(region.road_nodes.size()==2 and trunk.junctions.is_empty(),"preview must not mutate the source graph")
		_check(preview.build_plan.interchanges.size()==1 and preview.structure_cost>=10000000,"highway connection must be priced as an interchange")
		var funded:=Planner.commit(region,preview,0)
		_check(funded.ok,"compound project must fund")
		if funded.ok:
			_check(trunk.junctions.is_empty() and region.road_links.size()==1,"existing highway stays unchanged during construction")
			_check(not Planner.demolish_preview(region,trunk.id).ok,"shared road must be protected during construction")
			var detached=Snapshot.copy_region(region)
			detached.road_projects[0].build_plan.parts.clear()
			_check(not region.road_projects[0].build_plan.parts.is_empty(),"worker plan must be detached")
			Planner.advance_day(region,funded.project.open_day_key)
			_check(trunk.points==before and trunk.junctions.size()==1,"opening must attach without moving or rebuilding the highway")
			_check(Topology.audit(region).attachments.is_empty(),"compound opening must align graph and geometry")
			_check(region.road_nodes[trunk.junctions[0].node_id].is_interchange,"priced interchange must become active at opening")
			var extension:=Planner.link_preview(region,funded.project.to_node_id,-1,Link.ARTERIAL,PackedVector2Array(),100,"Straight",Vector2(0,20))
			_check(extension.get("ok",false),"opened construction stub must extend smoothly")
			if extension.get("ok",false):
				region.road_geometry_revision+=1
				_check(not Planner.commit(region,extension,100).ok,"stale preview must not be funded")
	var shared=_region()
	var highway=_link(shared,[Vector2(-30,0),Vector2(30,0)],Link.HIGHWAY)
	_link(shared,[Vector2(-20,.5),Vector2(15,.5),Vector2(25,10)],Link.COLLECTOR)
	var merged:=Topology.consolidate(shared)
	_check(merged.merged==1 and merged.shared_km>=20,"parallel rural corridor must reuse the highway")
	_check(highway.points==PackedVector2Array([Vector2(-30,0),Vector2(30,0)]),"higher road hierarchy must keep its alignment")
	_check(highway.junctions.size()==2,"divergences must attach to the common corridor")
	_check(Topology.audit(shared).attachments.is_empty(),"consolidated branches must attach exactly")
	var separated=_region()
	var bridge=_link(separated,[Vector2(-30,0),Vector2(30,0)],Link.HIGHWAY)
	bridge.terrain_spans.append({"kind":"Bridge","from":Vector2(-30,0),"to":Vector2(30,0)})
	_link(separated,[Vector2(-20,.5),Vector2(15,.5)],Link.COLLECTOR)
	_check(Topology.consolidate(separated).merged==0,"grade-separated parallel alignments must not merge")
	var surface=_region()
	_link(surface,[Vector2(-20,0),Vector2(20,0)],Link.ARTERIAL)
	var crossing_road=_link(surface,[Vector2(-20,10),Vector2(20,10)],Link.ARTERIAL)
	Land.initialize(surface)
	var cross_preview:=Planner.link_preview(surface,-1,-1,Link.ARTERIAL,PackedVector2Array(),0,"Straight",Vector2(0,20),{},Vector2.ZERO)
	_check(cross_preview.get("ok",false),"surface crossing must preview")
	if cross_preview.get("ok",false):
		var funding:=Planner.commit(surface,cross_preview,0)
		_check(funding.ok,"surface crossing must fund")
		if funding.ok:
			Planner.advance_day(surface,funding.project.open_day_key)
			_check(crossing_road.junctions.size()==1,"opening must connect an interior surface crossing")
			if not crossing_road.junctions.is_empty():
				_check(Topology.approaches(surface)[crossing_road.junctions[0].node_id].size()==4,"surface crossing must have four traversable approaches")
			_check(Topology.audit(surface).attachments.is_empty(),"surface connection coordinates must agree")
	var upgrade=_region()
	var rural=_link(upgrade,[Vector2(-20,.5),Vector2(20,.5)],Link.COLLECTOR)
	var feeder=_link(upgrade,[Vector2(0,.5),Vector2(0,10)],Link.ARTERIAL)
	Topology.attach_exact(upgrade,rural,feeder.from_node_id)
	var west=_link(upgrade,[Vector2(-30,-5),Vector2(-30,0)],Link.ARTERIAL)
	var east=_link(upgrade,[Vector2(30,0),Vector2(30,-5)],Link.ARTERIAL)
	upgrade.road_nodes[west.to_node_id].is_urban_street=true
	upgrade.road_nodes[east.from_node_id].is_urban_street=true
	Land.initialize(upgrade)
	var upgrade_preview:=Planner.link_preview(upgrade,west.to_node_id,east.from_node_id,Link.HIGHWAY,PackedVector2Array(),0,"Straight")
	_check(upgrade_preview.get("ok",false),"highway replacing a rural corridor must preview: %s" % upgrade_preview.get("reason",""))
	if upgrade_preview.get("ok",false):
		_check(upgrade_preview.build_plan.interchanges.size()>=3,"shared corridor must price interior interchanges as well as endpoints")
		var funding:=Planner.commit(upgrade,upgrade_preview,0)
		_check(funding.ok,"replacement with an existing side road must fund")
		if funding.ok:
			Planner.advance_day(upgrade,funding.project.open_day_key)
			_check(Topology.audit(upgrade).attachments.is_empty(),"replacement branches must retain exact connections")
			_check(Topology.node_approaches(upgrade,feeder.from_node_id).size()>=2,"existing side road must remain connected after replacement")
			var interior_interchanges:=0
			for road in upgrade.road_links:
				if road.road_class!=Link.HIGHWAY: continue
				for junction in road.junctions:
					if upgrade.road_nodes[junction.node_id].is_interchange: interior_interchanges+=1
			_check(interior_interchanges>0,"replacement highway must open its interior interchanges")
	print("Compound road fixtures: ","PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)

func _region():
	var region=Region.new()
	var state=Area.new()
	state.id=0
	state.kind="State"
	state.bounds_km=Rect2(-50,-50,100,100)
	state.polygon_km=PackedVector2Array([Vector2(-50,-50),Vector2(50,-50),Vector2(50,50),Vector2(-50,50)])
	state.treasury=10000000000.0
	region.jurisdictions.append(state)
	return region

func _link(region,points:Array,road_class:String):
	var link=Link.new()
	for point in [points[0],points[-1]]:
		var node=RoadNode.new()
		node.id=region.road_nodes.size()
		node.position_km=point
		region.road_nodes.append(node)
	link.from_node_id=region.road_nodes.size()-2
	link.to_node_id=region.road_nodes.size()-1
	link.id=region.next_road_link_id
	region.next_road_link_id+=1
	link.corridor_id=link.id
	link.road_class=road_class
	link.owner_jurisdiction_id=0
	link.points=PackedVector2Array(points)
	link.recalculate_length()
	region.road_links.append(link)
	return link

func _check(ok:bool,message:String) -> void:
	if not ok: errors.append(message)
