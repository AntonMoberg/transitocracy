extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = Setup.build(1729, 256, 0.1)
	var region = result["region"]
	for road_class in ["Collector", "Highway"]:
		var original = null
		for link in region.road_links:
			if link.road_class == road_class:
				original = link
				break
		_check(original != null, "junction fixtures need collector and highway roads")
		if original == null:
			continue
		var segment: int = original.points.size() / 2
		var center: Vector2 = original.points[segment - 1].lerp(original.points[segment], 0.5)
		var normal: Vector2 = (original.points[segment] - original.points[segment - 1]).normalized().orthogonal() * 0.08
		var old_points: PackedVector2Array = original.points.duplicate()
		var old_length: float = original.length_km
		var node_ids: Array[int] = []
		for point in [center - normal, center + normal]:
			var node = RoadNode.new()
			node.id = region.road_nodes.size()
			node.position_km = point
			node.city_id = region.city_id_at_point(point)
			region.road_nodes.append(node)
			node_ids.append(node.id)
		RoadPlanner._append_link(region, node_ids[0], node_ids[1], "Arterial", 1, PackedVector2Array([center - normal, center + normal]), original.owner_jurisdiction_id)
		var corridor_id: int = region.road_links[-1].corridor_id
		RoadPlanner._connect_surface_crossings(region, corridor_id)
		var view: Dictionary = RoadGraph.adjacency(region)
		var neighbors: Array = view["neighbors"]
		var connected := false
		for node in region.road_nodes:
			if node.position_km.distance_to(center) > 0.002:
				continue
			var types: Dictionary = {}
			for edge in neighbors[node.id]:
				types[region.road_links[view["edge_link"][edge.x]].road_class] = true
			connected = connected or (types.has("Arterial") and types.has(road_class))
		if road_class == "Collector":
			_check(connected and original.points == old_points and original.length_km == old_length and not original.junctions.is_empty(), "a new surface arterial must share an actual junction with the crossed collector without splitting it")
		else:
			_check(not connected and original.points == old_points, "crossing a highway must not create a free interchange")
		for link in region.road_links:
			_check(link.length_km > 0.0001 and link.from_node_id != link.to_node_id, "intersection handling must not create zero-length links")
		Spatial.cache(region)
		for link_index in range(region.road_links.size()):
			var link = region.road_links[link_index]
			_check(RoadGraph.link_index(region, link.id) == link_index, "split-road ID lookups must remain valid")
	if failures == 0:
		print("Surface collector intersections, highway grade separation, split geometry, and road-ID indexing passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
