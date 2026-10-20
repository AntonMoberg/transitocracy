extends SceneTree

const GrowthAreas = preload("res://scripts/simulation/growth_area_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(8752568)
	RoadNetworkGenerator.generate(region)
	RoadLand.initialize(region)
	DevelopmentPlanner.refresh_candidates(region)
	var boundary_street_found := false
	for neighborhood in region.neighborhoods:
		var layout = neighborhood.street_layout
		if layout == null:
			continue
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] not in [Roads.LOCAL, Roads.COLLECTOR] or layout.closed_edges.has(edge_id):
				continue
			var edge: Vector2 = layout.edges[edge_id]
			for node_id in [int(edge.x), int(edge.y)]:
				var endpoint: Vector2 = layout.nodes[node_id]
				if GrowthAreas._point_outline_distance(endpoint, layout.polygon) > 0.01:
					continue
				var snapped: Dictionary = GrowthAreas.snap_anchor(region, neighborhood.city_id, endpoint + Vector2(0.02, 0.02), 0.08)
				if snapped.get("street_class", "") == layout.classes[edge_id] and snapped["point"].distance_to(endpoint) < 0.02:
					boundary_street_found = true
					break
			if boundary_street_found:
				break
		if boundary_street_found:
			break
	if not boundary_street_found:
		push_error("Generated local and collector streets did not provide boundary snap points.")
		quit(1)
		return
	var attempted := 0
	var accepted := 0
	var paint_point := Vector2.ZERO
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or int(candidate["frontage_link_id"]) < 0:
			continue
		var route: PackedVector2Array = candidate["layout_input"]["route"]
		var nearest: Vector2 = route[0]
		var nearest_distance := INF
		for index in range(1, route.size()):
			var projected: Vector2 = Geometry2D.get_closest_point_to_segment(candidate["center_km"], route[index - 1], route[index])
			if projected.distance_to(candidate["center_km"]) < nearest_distance:
				nearest = projected
				nearest_distance = projected.distance_to(candidate["center_km"])
		for distance in [0.35, 0.50, 0.70]:
			var point: Vector2 = nearest.lerp(candidate["center_km"], minf(1.0, float(distance) / maxf(nearest_distance, 0.01)))
			var brush: PackedVector2Array = GrowthAreas.clip_to_city(region, int(candidate["city_id"]), GrowthAreas.painted_polygon(PackedVector2Array([point])))
			if Geography.polygon_area(brush) < GrowthAreas.MIN_AREA_KM2:
				continue
			attempted += 1
			if not GrowthAreas.plan(region, int(candidate["city_id"]), brush, "paint-probe:%d" % attempted).is_empty():
				accepted += 1
				if distance == 0.70 and paint_point == Vector2.ZERO:
					paint_point = point
		if attempted >= 40:
			break
	print("Generated-city ordinary paint: %d/%d" % [accepted, attempted])
	if attempted < 10 or accepted < ceili(float(attempted) * 0.90):
		push_error("Most ordinary strokes beside generated arterial frontage must create a preview.")
		quit(1)
		return
	var painted: Dictionary = DevelopmentPlanner.paint_growth_area(region, PackedVector2Array([paint_point]))
	if not painted["ok"] or not region.development_candidate_keys.has(painted.get("key", "")):
		push_error("Painted growth did not become a selectable generated-city preview: %s" % painted.get("reason", "missing"))
		quit(1)
		return
	quit(0)
