extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(42, 32, 0.1)["region"]
	var candidate_id := -1
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and candidate["layout_input"].get("edge_frontage", false) and Geography.polygon_area(candidate["polygon"]) > 0.55:
			candidate_id = candidate["id"]
			break
	if candidate_id < 0:
		push_error("Expected a buildable new district")
		quit(1)
		return
	var grid = region.development_candidates[candidate_id]["layout"]
	var grid_bend: float = _mean_bend(grid)
	if not Planner.set_candidate_style(region, candidate_id, "Organic"):
		push_error("Could not choose Organic for a new district")
		quit(1)
		return
	var organic = region.development_candidates[candidate_id]["layout"]
	var organic_bend: float = _mean_bend(organic)
	var bowed_edges := 0
	var max_bow := 0.0
	for path in organic.edge_paths.values():
		var bow := 0.0
		for point in path:
			bow = maxf(bow, point.distance_to(Geometry2D.get_closest_point_to_segment(point, path[0], path[-1])))
		if bow > 0.001:
			bowed_edges += 1
		max_bow = maxf(max_bow, bow)
	var covered := 0.0
	for block in organic.blocks:
		covered += Geography.polygon_area(block["polygon"])
	var coverage: float = covered / Geography.polygon_area(organic.polygon)
	if organic_bend < grid_bend * 1.35 or bowed_edges < 10 or max_bow < 0.002:
		push_error("Organic needs curving streets: grid %.3f, organic %.3f radians, %d bowed edges, %.3f km maximum bow" % [grid_bend, organic_bend, bowed_edges, max_bow])
		quit(1)
		return
	if coverage < 0.90:
		push_error("Organic curves must still cover the district with blocks: %.2f" % coverage)
		quit(1)
		return
	print("Organic district follows the city field: mean junction bend %.3f vs grid %.3f radians; %d/%d bowed edges (%.3f km maximum), block coverage %.2f." % [organic_bend, grid_bend, bowed_edges, organic.edges.size(), max_bow, coverage])
	quit(0)


func _mean_bend(layout) -> float:
	var directions: Array = []
	directions.resize(layout.nodes.size())
	for node_id in range(directions.size()):
		directions[node_id] = []
	for edge in layout.edges:
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		var direction: Vector2 = (layout.nodes[last] - layout.nodes[first]).normalized()
		directions[first].append(direction)
		directions[last].append(-direction)
	var sum := 0.0
	var count := 0
	for spokes in directions:
		if spokes.size() != 4:
			continue
		var opposite := 1
		var smallest_dot := 1.0
		for index in range(1, 4):
			var dot: float = spokes[0].dot(spokes[index])
			if dot < smallest_dot:
				smallest_dot = dot
				opposite = index
		sum += PI - acos(clampf(smallest_dot, -1.0, 1.0))
		count += 1
	return sum / maxf(1.0, float(count))
