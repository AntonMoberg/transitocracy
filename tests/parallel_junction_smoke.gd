extends SceneTree
const Topology=preload("res://scripts/simulation/road_topology.gd")
func fixture():
	var region=preload("res://scripts/simulation/region_data.gd").new()
	var state=preload("res://scripts/simulation/jurisdiction_data.gd").new()
	state.polygon_km=PackedVector2Array([Vector2(-10,-10),Vector2(100,-10),Vector2(100,100),Vector2(-10,100)])
	state.bounds_km=Rect2(-10,-10,110,110)
	region.jurisdictions.append(state)
	# A chain makes adjacent repairs share links, exercising stale-plan fallback.
	for i in range(10):
		var node=preload("res://scripts/simulation/road_node_data.gd").new()
		node.id=i
		node.position_km=Vector2(i*5,(i%2)*4)
		node.is_urban_street=i==0 or i==9
		region.road_nodes.append(node)
		if i==0: continue
		var link=preload("res://scripts/simulation/road_link_data.gd").new()
		link.id=i-1
		link.from_node_id=i-1
		link.to_node_id=i
		link.points=PackedVector2Array([region.road_nodes[i-1].position_km,node.position_km])
		link.recalculate_length()
		region.road_links.append(link)
	return region
func _initialize() -> void:
	var serial=fixture()
	var parallel=fixture()
	var repeat=fixture()
	var report:Dictionary=Topology.cleanup(serial,0,false)
	var threaded:Dictionary=Topology.cleanup(parallel)
	Topology.cleanup(repeat)
	var errors:=PackedStringArray()
	if report!=threaded: errors.append("Parallel cleanup changed repair/audit results")
	for i in range(serial.road_links.size()):
		if serial.road_links[i].points!=parallel.road_links[i].points or parallel.road_links[i].points!=repeat.road_links[i].points:
			errors.append("Parallel geometry differs from sequential or repeated execution")
	if not threaded.audit.kinks.is_empty() or not threaded.audit.attachments.is_empty(): errors.append("Invalid repaired junction")
	if not errors.is_empty(): push_error(str(errors))
	print("Parallel junctions: ","PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
