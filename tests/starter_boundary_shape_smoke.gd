extends SceneTree

const Generator = preload("res://scripts/simulation/region_generator.gd")
const RoadGenerator = preload("res://scripts/simulation/road_network_generator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Generator.generate_region(42)
	RoadGenerator.generate(region)
	var shaped := 0
	var total := 0
	var straight_collectors := 0
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed or neighborhood.street_layout == null:
			continue
		total += 1
		var polygon: PackedVector2Array = neighborhood.street_layout.polygon
		var long_straights := 0
		var high_turns := 0
		var perimeter := 0.0
		for index in range(polygon.size()):
			var incoming: Vector2 = polygon[index] - polygon[posmod(index - 1, polygon.size())]
			var outgoing: Vector2 = polygon[(index + 1) % polygon.size()] - polygon[index]
			perimeter += outgoing.length()
			if outgoing.length() >= 0.35:
				long_straights += 1
			var turn: float = absf(rad_to_deg(incoming.angle_to(outgoing)))
			if turn >= 65.0 and turn <= 115.0:
				high_turns += 1
		if long_straights >= 2 and high_turns >= 2:
			shaped += 1
		if polygon.size() > 5:
			push_error("Starter district %d has too many short border jogs." % neighborhood.id)
			quit(1)
			return
		var roaded_perimeter := 0.0
		var layout = neighborhood.street_layout
		for edge_id in range(layout.edges.size()):
			var edge: Vector2 = layout.edges[edge_id]
			var midpoint: Vector2 = (layout.nodes[int(edge.x)] + layout.nodes[int(edge.y)]) * 0.5
			for segment in range(polygon.size()):
				if midpoint.distance_to(Geometry2D.get_closest_point_to_segment(midpoint, polygon[segment], polygon[(segment + 1) % polygon.size()])) < 0.001:
					roaded_perimeter += layout.lengths[edge_id]
					break
		if roaded_perimeter < perimeter * 0.98:
			push_error("Starter district %d has gaps in its boundary streets." % neighborhood.id)
			quit(1)
			return
		for path in layout.core_paths:
			var points: PackedVector2Array = path["points"]
			if points.size() < 3 or points[0].distance_to(points[-1]) < 0.25:
				continue
			straight_collectors += 1
			for point in points:
				if point.distance_to(Geometry2D.get_closest_point_to_segment(point, points[0], points[-1])) > 0.01:
					push_error("Starter district %d has a bent collector path." % neighborhood.id)
					quit(1)
					return
	if total < 40 or shaped < 32 or straight_collectors < 40:
		push_error("Starter districts need long borders and straight collectors: %d shaped, %d collectors, %d total." % [shaped, straight_collectors, total])
		quit(1)
		return
	print("Starter districts: %d of %d have simple borders, roaded edges, and %d straight collector paths." % [shaped, total, straight_collectors])
	quit(0)
