extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(1729)
	var main_planner = Planner.new(region)
	var sites: Array[Dictionary] = RoadNetworkGenerator._sites(region)
	var highways: Dictionary = RoadNetworkGenerator._build_highways(region, main_planner, sites)
	var costs: PackedFloat32Array = highways["avoid_costs"]
	var filled := 0
	var peak := 0.0
	for value in costs:
		if value > 0.0:
			filled += 1
			peak = maxf(peak, value)
	print("grid: %d cells, %d filled, peak %.2f" % [costs.size(), filled, peak])
	var trunk = null
	for link in region.road_links:
		if link.road_class == RoadLinkData.HIGHWAY:
			trunk = link
			break
	var middle: Vector2 = trunk.points[trunk.points.size() / 2]
	var normal: Vector2 = (trunk.points[trunk.points.size() / 2 + 1] - trunk.points[trunk.points.size() / 2 - 1]).normalized().orthogonal()
	var a: Vector2 = middle + normal * 25.0
	var b: Vector2 = middle - normal * 25.0
	var plain = Planner.new(region)
	var avoiding = Planner.new(region)
	avoiding.set_avoidance(highways["avoid_costs"], highways["avoid_origin"], highways["avoid_step"], highways["avoid_size"])
	var first: Dictionary = plain.route(a, b, RoadLinkData.COLLECTOR, Vector2.ZERO, Vector2.ZERO, false)
	var second: Dictionary = avoiding.route(a, b, RoadLinkData.COLLECTOR, Vector2.ZERO, Vector2.ZERO, false)
	print("plain: %.1f km, avoiding: %.1f km" % [float(first.get("length_km", -1)), float(second.get("length_km", -1))])
	for result in [first, second]:
		var overlap := 0.0
		for index in range(1, result["points"].size()):
			var point: Vector2 = result["points"][index]
			if RoadPlanner_closest(trunk.points, point).distance_to(point) < 3.5:
				overlap += result["points"][index - 1].distance_to(point)
		print("  overlap within 3.5 km of trunk: %.1f km" % overlap)
	quit(0)


func RoadPlanner_closest(points: PackedVector2Array, point: Vector2) -> Vector2:
	var best := points[0]
	var best_distance := INF
	for index in range(1, points.size()):
		var candidate: Vector2 = Geometry2D.get_closest_point_to_segment(point, points[index - 1], points[index])
		var distance := candidate.distance_squared_to(point)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best
