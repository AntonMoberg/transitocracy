extends SceneTree

const Streamlines = preload("res://scripts/simulation/street_streamline_tracer.gd")
const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const Setup = preload("res://scripts/simulation/region_setup.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Region = preload("res://scripts/simulation/region_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var source: Dictionary = {}
	for row in range(9):
		for column in range(12):
			source[Vector2i(column, row)] = Vector2(10.0 + column * 0.17, 20.0 + row * 0.11)
	var traced: Dictionary = Streamlines.trace_grid(source, 11, 8, 1729, 3, Vector2.RIGHT, false, Vector2(10.0, 20.0), 0.04)
	var repeated: Dictionary = Streamlines.trace_grid(source, 11, 8, 1729, 3, Vector2.RIGHT, false, Vector2(10.0, 20.0), 0.04)
	var displacement := 0.0
	for row in range(9):
		for column in range(12):
			var address := Vector2i(column, row)
			_check(traced[address] == repeated[address], "Street tracing must be deterministic")
			if row == 0 or row == 8 or column == 0 or column == 11:
				_check(traced[address] == source[address], "Street tracing must preserve shared district boundaries")
			else:
				displacement = maxf(displacement, traced[address].distance_to(source[address]))
	_check(displacement > 0.001, "Street junctions must come from field traces, not unchanged lattice points")
	var organic: Dictionary = Streamlines.trace_grid(source, 11, 8, 1729, 3, Vector2.RIGHT, true, Vector2(10.0, 20.0), 0.075)
	var organic_displacement := 0.0
	for row in range(8):
		for column in range(11):
			var polygon := PackedVector2Array([traced[Vector2i(column, row)], traced[Vector2i(column + 1, row)], traced[Vector2i(column + 1, row + 1)], traced[Vector2i(column, row + 1)]])
			_check(Geometry2D.triangulate_polygon(polygon).size() == 6, "Traced street families must bound usable blocks")
			var organic_polygon := PackedVector2Array([organic[Vector2i(column, row)], organic[Vector2i(column + 1, row)], organic[Vector2i(column + 1, row + 1)], organic[Vector2i(column, row + 1)]])
			_check(Geometry2D.triangulate_polygon(organic_polygon).size() == 6, "Organic traces must retain usable block faces")
			organic_displacement = maxf(organic_displacement, organic[Vector2i(column, row)].distance_to(source[Vector2i(column, row)]))
	_check(organic_displacement > displacement, "Organic streets should turn more than grid streets")
	var field_region = Region.new()
	field_region.generation_seed = 1729
	field_region.cities.append({"street_axis": Vector2.RIGHT})
	var field_bounds := Rect2(Vector2(9.5, 19.8), Vector2(1.0, 1.0))
	var original_context: Dictionary = DirectionField.city_context(field_region, 0, field_bounds)
	for point in [Vector2(9.4, 20.0), Vector2(10.6, 20.6)]:
		var node = RoadNode.new()
		node.id = field_region.road_nodes.size()
		node.position_km = point
		field_region.road_nodes.append(node)
	var arterial = Roads.new()
	arterial.id = 0
	arterial.from_node_id = 0
	arterial.to_node_id = 1
	arterial.road_class = Roads.ARTERIAL
	arterial.points = PackedVector2Array([field_region.road_nodes[0].position_km, field_region.road_nodes[1].position_km])
	field_region.road_links.append(arterial)
	var changed_context: Dictionary = DirectionField.city_context(field_region, 0, field_bounds)
	var near_point := Vector2(10.0, 20.3)
	var far_point := Vector2(13.0, 23.0)
	var near_before: Vector2 = DirectionField.axis(1729, 0, near_point, Vector2.RIGHT, Vector2.ZERO, true, Vector2.INF, original_context)
	var near_after: Vector2 = DirectionField.axis(1729, 0, near_point, Vector2.RIGHT, Vector2.ZERO, true, Vector2.INF, changed_context)
	var far_before: Vector2 = DirectionField.axis(1729, 0, far_point, Vector2.RIGHT, Vector2.ZERO, true, Vector2.INF, original_context)
	var far_after: Vector2 = DirectionField.axis(1729, 0, far_point, Vector2.RIGHT, Vector2.ZERO, true, Vector2.INF, changed_context)
	_check(absf(near_before.angle_to(near_after)) > 0.025, "A completed arterial must turn the local field used by future districts")
	_check(absf(far_before.angle_to(far_after)) < 0.0001, "Road influence must fade before reaching unrelated districts")
	var changed_streets: Dictionary = Streamlines.trace_grid(source, 11, 8, 1729, 0, Vector2.RIGHT, true, Vector2.INF, 0.085, -1, changed_context)
	var original_streets: Dictionary = Streamlines.trace_grid(source, 11, 8, 1729, 0, Vector2.RIGHT, true, Vector2.INF, 0.085, -1, original_context)
	var changed_junctions := 0
	for row in range(1, 8):
		for column in range(1, 11):
			if changed_streets[Vector2i(column, row)].distance_to(original_streets[Vector2i(column, row)]) > 0.002:
				changed_junctions += 1
	_check(changed_junctions > 0, "Neighbourhood tracing must sample the arterial-shaped city field")
	var highway: PackedVector2Array = DirectionField.trace_regional(Vector2(20, 40), Vector2(70, 43), Vector2.RIGHT, Vector2.RIGHT, 1729, 0)
	_check(highway[0] == Vector2(20, 40) and highway[-1] == Vector2(70, 43), "Regional traces must meet interchange sites")
	var deviation := 0.0
	for point in highway:
		deviation = maxf(deviation, point.distance_to(Geometry2D.get_closest_point_to_segment(point, highway[0], highway[-1])))
	_check(deviation > 0.05 and RoadRouteBuilder.minimum_curve_radius(highway) >= RoadRouteBuilder.MIN_HIGHWAY_RADIUS_KM, "Regional field tracing must make a smooth, non-straight highway")
	var region = Setup.build(42, 32, 0.1)["region"]
	var highway_links := 0
	var traced_links := 0
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY:
			continue
		highway_links += 1
		if link.points.size() < 4:
			continue
		var expected_lead: float = minf(1.0, region.road_nodes[link.from_node_id].position_km.distance_to(region.road_nodes[link.to_node_id].position_km) * 0.12)
		if absf(link.points[0].distance_to(link.points[1]) - expected_lead) < 0.003 and absf(link.points[-2].distance_to(link.points[-1]) - expected_lead) < 0.003:
			traced_links += 1
	_check(traced_links > highway_links / 2, "Most generated highway legs must use the regional trace instead of the fallback route")
	if failures == 0:
		print("Street families intersect into usable blocks (%.3f km maximum movement); %d/%d highway legs use smooth regional traces." % [displacement, traced_links, highway_links])
	quit(1 if failures > 0 else 0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
