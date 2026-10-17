extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for city_count in [32, 256, 768]:
		for seed_value in [1729, 42, 1730, 1, 2, 7]:
			var region = RegionGenerator.generate_region(seed_value) if city_count == 32 else RegionGenerator.generate_large_region(seed_value, city_count)
			var displaced := 0
			var worst_shape := 0.0
			for city in region.cities:
				var boundary = region.jurisdictions[city["jurisdiction_id"]]
				var settlement: Vector2 = city["center_km"]
				_check(boundary.contains_point(settlement), "city settlements must stay inside their borders")
				if settlement.distance_to(boundary.center_km) > 0.5:
					displaced += 1
				worst_shape = maxf(worst_shape, _elongation(boundary.polygon_km))
			_check(displaced > city_count * 0.8, "settlements should vary within city borders")
			_check(worst_shape < 8.0, "city split produced a long, thin outlier: %.2f at %d cities, seed %d" % [worst_shape, city_count, seed_value])
			var irregular := 0
			for neighborhood in region.neighborhoods:
				var polygon: PackedVector2Array = region.jurisdictions[neighborhood.jurisdiction_id].polygon_km
				_check(StateGeography.polygon_area(polygon) <= 4.001, "neighborhood area exceeds roughly 2 by 2 km")
				if polygon.size() > 4:
					irregular += 1
			_check(irregular > region.neighborhoods.size() * 0.8, "neighborhood cells should have irregular outlines")
	var first: PackedVector2Array = StateGeography._cell_outline(1729, Vector2i(100, 100))
	var neighbor: PackedVector2Array = StateGeography._cell_outline(1729, Vector2i(101, 100))
	var shared_midpoint: Vector2 = (StateGeography.cell_site(1729, Vector2i(100, 100)) + StateGeography.cell_site(1729, Vector2i(101, 100))) * 0.5
	var shared_normal: Vector2 = StateGeography.cell_site(1729, Vector2i(101, 100)) - StateGeography.cell_site(1729, Vector2i(100, 100))
	var first_shared: Array[Vector2] = []
	var neighbor_shared: Array[Vector2] = []
	for vertex in first:
		if absf((vertex - shared_midpoint).dot(shared_normal)) < 0.001:
			first_shared.append(vertex)
	for vertex in neighbor:
		if absf((vertex - shared_midpoint).dot(shared_normal)) < 0.001:
			neighbor_shared.append(vertex)
	_check(first_shared.size() >= 2 and neighbor_shared.size() >= 2, "adjacent polygonal cells should share an edge")
	for vertex in first_shared:
		var matched := false
		for other in neighbor_shared:
			if vertex.distance_to(other) < 0.001:
				matched = true
		_check(matched, "adjacent cells must agree on shared edge vertices")
	var side_counts: Dictionary = {}
	var maximum_cell_area := 0.0
	for grid_y in range(100, 115):
		for grid_x in range(100, 115):
			var polygon: PackedVector2Array = StateGeography._cell_outline(1729, Vector2i(grid_x, grid_y))
			side_counts[polygon.size()] = true
			maximum_cell_area = maxf(maximum_cell_area, StateGeography.polygon_area(polygon))
	_check(side_counts.size() >= 3, "neighborhoods should vary in their number of straight sides")
	var sample_rng := RandomNumberGenerator.new()
	sample_rng.seed = 918273
	for sample in range(250):
		var point := Vector2(sample_rng.randf_range(160.0, 190.0), sample_rng.randf_range(160.0, 190.0))
		var grid: Vector2i = StateGeography.cell_grid_at_point(1729, point)
		var closest_distance: float = point.distance_squared_to(StateGeography.cell_site(1729, grid))
		for offset_y in range(-3, 4):
			for offset_x in range(-3, 4):
				var other_grid := grid + Vector2i(offset_x, offset_y)
				var other_distance: float = point.distance_squared_to(StateGeography.cell_site(1729, other_grid))
				_check(closest_distance <= other_distance + 0.0001, "point lookup must find the nearest polygon site")
		_check(JurisdictionData.polygon_contains_point(point, StateGeography._cell_outline(1729, grid)), "nearest polygon must cover its lookup point")
	print("Neighborhood polygon side counts: %s, maximum area %.2f km²" % [side_counts.keys(), maximum_cell_area])
	_check(StateGeography.polygon_area(first) <= 4.001, "a complete cell should fit within the neighborhood area limit")
	if failures == 0:
		print("Compact cities, offset settlements, and contiguous irregular neighborhood cells passed.")
	quit(1 if failures > 0 else 0)


func _elongation(polygon: PackedVector2Array) -> float:
	var longest := 0.0
	for axis in [Vector2.RIGHT, Vector2.UP, Vector2(0.7071068, 0.7071068), Vector2(0.7071068, -0.7071068)]:
		var low := INF
		var high := -INF
		for vertex in polygon:
			var projection: float = vertex.dot(axis)
			low = minf(low, projection)
			high = maxf(high, projection)
		longest = maxf(longest, high - low)
	return longest * longest / StateGeography.polygon_area(polygon)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
