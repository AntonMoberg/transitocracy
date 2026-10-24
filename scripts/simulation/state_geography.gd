extends RefCounted

const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const TerrainGenerator = preload("res://scripts/simulation/terrain_generator.gd")
const STATE_LAND_AREA_KM2 = 400000.0
const CELL_SIZE_KM = 1.6
const TRIANGLE_ROW_HEIGHT = 0.8660254


static func generate(region, rng: RandomNumberGenerator) -> void:
	var state = region.jurisdictions[0]
	var shape: Dictionary = _generate_outline(region.generation_seed)
	state.polygon_km = shape["polygon"]
	_update_bounds(state)
	region.terrain = TerrainGenerator.generate(region.generation_seed, state.polygon_km, state.bounds_km, shape["coastline"])
	_partition(region, state, rng)
	for city in region.cities:
		var area = region.jurisdictions[city["jurisdiction_id"]]
		var center: Vector2 = _settlement_point(area, rng, region.terrain)
		city["center_km"] = center
		for neighborhood_id in city["neighborhood_ids"]:
			var neighborhood = region.neighborhoods[neighborhood_id]
			var district = region.jurisdictions[neighborhood.jurisdiction_id]
			var grid: Vector2i = cell_grid_at_point(region.generation_seed, center)
			var seed_polygon: PackedVector2Array = cell_polygon(region, city["id"], grid)
			if polygon_area(seed_polygon) < 0.4 or not area.contains_point(cell_site(region.generation_seed, grid)):
				for radius in range(1, 12):
					for offset_y in range(-radius, radius + 1):
						for offset_x in range(-radius, radius + 1):
							if maxi(absi(offset_x), absi(offset_y)) != radius:
								continue
							var trial_grid := grid + Vector2i(offset_x, offset_y)
							var trial_center: Vector2 = cell_site(region.generation_seed, trial_grid)
							if not area.contains_point(trial_center):
								continue
							var trial_polygon: PackedVector2Array = cell_polygon(region, city["id"], trial_grid)
							if polygon_area(trial_polygon) >= 0.4:
								seed_polygon = trial_polygon
								grid = trial_grid
								break
						if polygon_area(seed_polygon) >= 0.4:
							break
					if polygon_area(seed_polygon) >= 0.4:
						break
			district.polygon_km = seed_polygon
			_update_bounds(district)
			neighborhood.position_km = district.center_km
			neighborhood.cell_grid = grid
			neighborhood.land_area_ha = _area(district.polygon_km) * 100.0
			neighborhood.developable_area_ha = minf(neighborhood.developable_area_ha, neighborhood.land_area_ha)
			if region.terrain != null:
				neighborhood.developable_area_ha *= region.terrain.buildable_fraction(seed_polygon)
	region.starting_city_ids.append(0)
	while region.starting_city_ids.size() < mini(10, region.cities.size()):
		var best_id := -1
		var best_distance := -1.0
		for city in region.cities:
			if region.starting_city_ids.has(city["id"]):
				continue
			if region.terrain != null and not _good_starter_site(region.terrain, city["center_km"]):
				continue
			var distance := INF
			for starting_id in region.starting_city_ids:
				distance = minf(distance, city["center_km"].distance_squared_to(region.cities[starting_id]["center_km"]))
			if distance > best_distance:
				best_distance = distance
				best_id = city["id"]
		if best_id < 0:
			for city in region.cities:
				if not region.starting_city_ids.has(city["id"]):
					best_id = city["id"]
					break
		if best_id < 0:
			break
		region.starting_city_ids.append(best_id)


static func _good_starter_site(terrain, center: Vector2) -> bool:
	if terrain.elevation_at(center) > 650.0:
		return false
	for offset in [Vector2.ZERO, Vector2(-2.0, 0.0), Vector2(2.0, 0.0), Vector2(0.0, -2.0), Vector2(0.0, 2.0), Vector2(-2.0, -2.0), Vector2(2.0, 2.0)]:
		var point: Vector2 = center + offset
		if terrain.water_at(point) or terrain.slope_at(point) > 0.17:
			return false
	return true


static func initialize_development(region) -> void:
	for neighborhood in region.neighborhoods:
		neighborhood.development_jobs_by_skill = neighborhood.jobs_by_skill.duplicate()
		neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
		neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
		neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
		var local_id: int = region.cities[neighborhood.city_id]["neighborhood_ids"].find(neighborhood.id)
		neighborhood.initially_developed = region.starting_city_ids.has(neighborhood.city_id) and local_id < int(region.cities[neighborhood.city_id].get("initial_neighborhood_count", 4))
		neighborhood.development_approved = neighborhood.initially_developed
		neighborhood.development_state = "Established" if neighborhood.initially_developed else "Dormant"
		if not neighborhood.initially_developed:
			neighborhood.households = 0
			neighborhood.population = 0
			neighborhood.jobs = 0
			neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
			neighborhood.shopping_attraction = 0.0
			neighborhood.monthly_rent = 0


static func _generate_outline(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 104729
	var outline := PackedVector2Array()
	var north_y: float = rng.randf_range(0.06, 0.14)
	outline.append(Vector2(0, north_y))
	var steps: int = rng.randi_range(2, 4)
	for step in range(steps):
		var position: float = 0.88 * (float(step) + rng.randf_range(0.7, 1.1)) / float(steps + 1)
		outline.append(Vector2(position, north_y))
		north_y = clampf(north_y + rng.randf_range(-0.04, 0.04), 0.04, 0.18)
		outline.append(Vector2(position, north_y))
	outline.append(Vector2(0.90, north_y))
	_append_shore(outline, Vector2(rng.randf_range(0.96, 0.99), north_y + rng.randf_range(0.06, 0.12)), rng)
	_append_shore(outline, Vector2(1.0, rng.randf_range(0.35, 0.55)), rng)
	_append_shore(outline, Vector2(rng.randf_range(0.97, 0.99), rng.randf_range(0.72, 0.85)), rng)
	var bays: Array[Vector3] = []
	var bay_count: int = rng.randi_range(2, 4)
	for bay_index in range(bay_count):
		var center: float = 0.08 + 0.80 * (float(bay_index) + rng.randf_range(0.3, 0.7)) / float(bay_count)
		bays.append(Vector3(center, rng.randf_range(0.035, 0.075), rng.randf_range(0.24, 0.39)))
	var coves: Array[Vector3] = []
	for cove_index in range(rng.randi_range(6, 10)):
		coves.append(Vector3(rng.randf_range(0.04, 0.90), rng.randf_range(0.008, 0.022), rng.randf_range(-0.014, 0.022)))
	var sample_count: int = rng.randi_range(190, 230)
	var phase: float = rng.randf_range(0.0, TAU)
	var amplitude: float = rng.randf_range(0.025, 0.07)
	var shore_noise := FastNoiseLite.new()
	shore_noise.seed = seed_value + 4381
	shore_noise.frequency = 0.018
	shore_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	shore_noise.fractal_octaves = 3
	var coast_start: int = outline.size() - 1
	for sample_index in range(sample_count, -1, -1):
		var position: float = 0.94 * float(sample_index) / float(sample_count)
		var coastline: float = 0.87 + sin(phase + position * 7.0) * amplitude
		coastline += sin(phase * 1.7 + position * 63.0) * 0.010 + shore_noise.get_noise_1d(position * 1000.0) * 0.014
		for bay in bays:
			coastline -= bay.z * exp(-0.5 * pow((position - bay.x) / bay.y, 2.0))
		for cove in coves:
			coastline += cove.z * exp(-0.5 * pow((position - cove.x) / cove.y, 2.0))
		outline.append(Vector2(position, clampf(coastline, 0.40, 0.97)))
	var reflect_vertical: bool = rng.randf() < 0.5
	var reflect_horizontal: bool = rng.randf() < 0.5
	for vertex in range(outline.size()):
		if reflect_vertical:
			outline[vertex].y = 1.0 - outline[vertex].y
		if reflect_horizontal:
			outline[vertex].x = 1.0 - outline[vertex].x
	var bounds: Rect2 = _bounds(outline)
	var area: float = _area(outline)
	var minimum_length: float = sqrt(STATE_LAND_AREA_KM2 * 2.8 * bounds.size.x * bounds.size.y / area)
	var length_km: float = maxf(rng.randf_range(1250.0, 1450.0), minimum_length)
	var horizontal_scale: float = length_km / bounds.size.x
	var vertical_scale: float = STATE_LAND_AREA_KM2 / (area * horizontal_scale)
	for vertex in range(outline.size()):
		outline[vertex] = (outline[vertex] - bounds.position) * Vector2(horizontal_scale, vertical_scale)
	var coastline := PackedVector2Array()
	for index in range(coast_start, outline.size()):
		coastline.append(outline[index])
	return {"polygon": outline, "coastline": coastline}


static func _append_shore(outline: PackedVector2Array, endpoint: Vector2, rng: RandomNumberGenerator) -> void:
	var first: Vector2 = outline[-1]
	var normal: Vector2 = (endpoint - first).normalized().orthogonal()
	var steps: int = maxi(1, ceili(first.distance_to(endpoint) / 0.012))
	for step in range(1, steps):
		outline.append(first.lerp(endpoint, float(step) / float(steps)) + normal * rng.randf_range(-0.002, 0.002))
	outline.append(endpoint)


static func _partition(region, parent, rng: RandomNumberGenerator) -> void:
	if parent.kind in ["City", "Neighborhood"]:
		return
	_divide_children(region, parent.child_ids, parent.polygon_km, rng)


static func _divide_children(region, child_ids: Array[int], polygon: PackedVector2Array, rng: RandomNumberGenerator) -> void:
	if child_ids.is_empty():
		return
	if child_ids.size() == 1:
		var child = region.jurisdictions[child_ids[0]]
		child.polygon_km = polygon
		_update_bounds(child)
		_partition(region, child, rng)
		return
	var first_count: int = floori(float(child_ids.size()) / 2.0)
	var bounds: Rect2 = _bounds(polygon)
	var preferred_axis: int = 0 if bounds.size.x >= bounds.size.y else 1
	if maxf(bounds.size.x, bounds.size.y) < minf(bounds.size.x, bounds.size.y) * 1.8 and rng.randf() < 0.25:
		preferred_axis = 1 - preferred_axis
	var first_weight := 0.0
	var total_weight := 0.0
	for child_index in range(child_ids.size()):
		var weight: float = region.jurisdictions[child_ids[child_index]].generation_weight
		total_weight += weight
		if child_index < first_count:
			first_weight += weight
	var target: float = clampf(first_weight / total_weight, 0.12, 0.88)
	var total_area: float = _area(polygon)
	var best_split: Array = []
	var best_score := INF
	var child_kind: String = region.jurisdictions[child_ids[0]].kind
	var shape_weight: float = 0.06 if child_kind == "City" else (0.02 if child_kind == "County" else 0.005)
	for attempt in range(18):
		var axis: int = preferred_axis if attempt < 12 else 1 - preferred_axis
		var angle: float = float(axis) * PI * 0.5 + rng.randf_range(-0.65, 0.65)
		var normal := Vector2.from_angle(angle)
		var tangent := Vector2(-normal.y, normal.x)
		var origin: Vector2 = bounds.get_center()
		var projected := PackedVector2Array()
		for point in polygon:
			var local: Vector2 = point - origin
			projected.append(Vector2(local.dot(normal), local.dot(tangent)))
		var extent: Rect2 = _bounds(projected)
		var padding: float = extent.size.length() + 1.0
		var cut: float = extent.position.x + extent.size.x * target
		var amplitude: float = minf(extent.size.x, extent.size.y) * rng.randf_range(0.08, 0.22)
		var bends: int = rng.randi_range(3, 6)
		var border := PackedVector2Array([origin + normal * cut + tangent * (extent.position.y - padding)])
		var phase: float = rng.randf_range(0.0, TAU)
		for bend in range(bends):
			var fraction: float = (float(bend) + rng.randf_range(0.15, 0.85)) / float(bends)
			var displacement: float = amplitude * (sin(phase + fraction * TAU * 0.8) + rng.randf_range(-0.35, 0.35))
			border.append(origin + normal * (cut + displacement) + tangent * (extent.position.y + extent.size.y * fraction))
		border.append(origin + normal * cut + tangent * (extent.end.y + padding))
		var first_mask := PackedVector2Array(border)
		first_mask.append(origin + normal * (extent.position.x - padding) + tangent * (extent.end.y + padding))
		first_mask.append(origin + normal * (extent.position.x - padding) + tangent * (extent.position.y - padding))
		var second_mask := PackedVector2Array(border)
		second_mask.reverse()
		second_mask.append(origin + normal * (extent.end.x + padding) + tangent * (extent.position.y - padding))
		second_mask.append(origin + normal * (extent.end.x + padding) + tangent * (extent.end.y + padding))
		var first_parts: Array = Geometry2D.intersect_polygons(polygon, first_mask)
		var second_parts: Array = Geometry2D.intersect_polygons(polygon, second_mask)
		if first_parts.size() != 1 or second_parts.size() != 1:
			continue
		var area_fraction: float = _area(first_parts[0]) / total_area
		if area_fraction < 0.06 or area_fraction > 0.94:
			continue
		var score: float = absf(area_fraction - target) + shape_weight * (_shape_penalty(first_parts[0]) + _shape_penalty(second_parts[0]))
		if score < best_score:
			best_score = score
			best_split = [first_parts[0], second_parts[0]]
	var straight_split: Array = _straight_split(polygon, bounds, preferred_axis, target, shape_weight)
	if not straight_split.is_empty():
		var straight_score: float = absf(_area(straight_split[0]) / total_area - target) + shape_weight * (_shape_penalty(straight_split[0]) + _shape_penalty(straight_split[1]))
		if straight_score < best_score:
			best_split = straight_split
	assert(not best_split.is_empty(), "State geography needs a connected administrative split.")
	_divide_children(region, child_ids.slice(0, first_count), best_split[0], rng)
	_divide_children(region, child_ids.slice(first_count), best_split[1], rng)


static func _straight_split(polygon: PackedVector2Array, bounds: Rect2, preferred_axis: int, target: float, shape_weight: float) -> Array:
	var total_area: float = _area(polygon)
	var best_split: Array = []
	var best_score := INF
	for axis in [preferred_axis, 1 - preferred_axis]:
		for offset in [0.0, -0.06, 0.06, -0.12, 0.12, -0.20, 0.20, -0.30, 0.30, -0.40, 0.40]:
			var fraction: float = clampf(target + offset, 0.06, 0.94)
			var cut: float = bounds.position[axis] + bounds.size[axis] * fraction
			var first_bounds: Rect2 = bounds.grow(1.0)
			var second_bounds: Rect2 = first_bounds
			first_bounds.size[axis] = cut - first_bounds.position[axis]
			second_bounds.position[axis] = cut
			second_bounds.size[axis] = bounds.end[axis] + 1.0 - cut
			var first_parts: Array = Geometry2D.intersect_polygons(polygon, _rectangle(first_bounds))
			var second_parts: Array = Geometry2D.intersect_polygons(polygon, _rectangle(second_bounds))
			if first_parts.size() != 1 or second_parts.size() != 1:
				continue
			var area_fraction: float = _area(first_parts[0]) / total_area
			if area_fraction < 0.08 or area_fraction > 0.92:
				continue
			var score: float = absf(area_fraction - target) + (0.15 if axis != preferred_axis else 0.0) + shape_weight * (_shape_penalty(first_parts[0]) + _shape_penalty(second_parts[0]))
			if score < best_score:
				best_score = score
				best_split = [first_parts[0], second_parts[0]]
	return best_split


static func _shape_penalty(polygon: PackedVector2Array) -> float:
	var area: float = _area(polygon)
	if area <= 0.0:
		return 1000.0
	var longest := 0.0
	for axis in [Vector2.RIGHT, Vector2.UP, Vector2(0.7071068, 0.7071068), Vector2(0.7071068, -0.7071068)]:
		var low := INF
		var high := -INF
		for vertex in polygon:
			var projection: float = vertex.dot(axis)
			low = minf(low, projection)
			high = maxf(high, projection)
		longest = maxf(longest, high - low)
	var excess: float = maxf(0.0, longest * longest / area - 4.0)
	return excess * excess


static func _rectangle(bounds: Rect2) -> PackedVector2Array:
	return PackedVector2Array([bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)])


static func cell_polygon(region, city_id: int, grid: Vector2i) -> PackedVector2Array:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var cell: PackedVector2Array = _cell_outline(region.generation_seed, grid)
	var parts: Array[PackedVector2Array] = Geometry2D.intersect_polygons(city.polygon_km, cell)
	var cell_center: Vector2 = cell_site(region.generation_seed, grid)
	var best := PackedVector2Array()
	var largest := 0.0
	for part in parts:
		if JurisdictionData.polygon_contains_point(cell_center, part):
			return part
		var area: float = _area(part)
		if area > largest:
			best = part
			largest = area
	return best


static func _cell_outline(seed_value: int, grid: Vector2i) -> PackedVector2Array:
	var site: Vector2 = cell_site(seed_value, grid)
	var reach: float = CELL_SIZE_KM * 2.0
	var polygon := _rectangle(Rect2(site - Vector2.ONE * reach, Vector2.ONE * reach * 2.0))
	for offset_y in range(-2, 3):
		for offset_x in range(-2, 3):
			if offset_x == 0 and offset_y == 0:
				continue
			var neighbor: Vector2 = cell_site(seed_value, grid + Vector2i(offset_x, offset_y))
			polygon = _clip_cell_to_bisector(polygon, site, neighbor)
			if polygon.is_empty():
				return polygon
	return polygon


static func cell_site(seed_value: int, grid: Vector2i) -> Vector2:
	var base := Vector2(float(grid.x) + float(grid.y) * 0.5, float(grid.y) * TRIANGLE_ROW_HEIGHT) * CELL_SIZE_KM
	var jitter := Vector2(_cell_random(seed_value, grid.x, grid.y, 0) - 0.5, _cell_random(seed_value, grid.x, grid.y, 1) - 0.5) * CELL_SIZE_KM * 0.75
	return base + jitter


static func cell_grid_at_point(seed_value: int, point: Vector2) -> Vector2i:
	var row: float = point.y / (CELL_SIZE_KM * TRIANGLE_ROW_HEIGHT)
	var column: float = point.x / CELL_SIZE_KM - row * 0.5
	var approximate := Vector2i(roundi(column), roundi(row))
	var best: Vector2i = approximate
	var best_distance := INF
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			var grid := approximate + Vector2i(offset_x, offset_y)
			var distance: float = point.distance_squared_to(cell_site(seed_value, grid))
			if distance < best_distance:
				best_distance = distance
				best = grid
	return best


static func cell_axial_coordinates(point: Vector2) -> Vector2:
	var row: float = point.y / (CELL_SIZE_KM * TRIANGLE_ROW_HEIGHT)
	return Vector2(point.x / CELL_SIZE_KM - row * 0.5, row)


static func _clip_cell_to_bisector(polygon: PackedVector2Array, site: Vector2, neighbor: Vector2) -> PackedVector2Array:
	if polygon.is_empty():
		return polygon
	var midpoint: Vector2 = (site + neighbor) * 0.5
	var normal: Vector2 = neighbor - site
	var clipped := PackedVector2Array()
	var previous: Vector2 = polygon[-1]
	var previous_distance: float = (previous - midpoint).dot(normal)
	for current in polygon:
		var current_distance: float = (current - midpoint).dot(normal)
		var previous_inside: bool = previous_distance <= 0.0
		var current_inside: bool = current_distance <= 0.0
		if previous_inside != current_inside:
			clipped.append(previous.lerp(current, previous_distance / (previous_distance - current_distance)))
		if current_inside:
			clipped.append(current)
		previous = current
		previous_distance = current_distance
	return clipped


static func _cell_random(seed_value: int, x: int, y: int, salt: int) -> float:
	var value: int = posmod(seed_value * 1000003 + x * 73856093 + y * 19349663 + salt * 83492791, 2147483647)
	value = (((value >> 16) ^ value) * 0x45d9f3b) & 0x7fffffff
	value = (((value >> 16) ^ value) * 0x45d9f3b) & 0x7fffffff
	value = (value >> 16) ^ value
	return float(value) / 2147483647.0


static func polygon_area(polygon: PackedVector2Array) -> float:
	return _area(polygon) if polygon.size() >= 3 else 0.0


static func update_bounds(area) -> void:
	_update_bounds(area)


static func _bounds(polygon: PackedVector2Array) -> Rect2:
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		bounds = bounds.expand(point)
	return bounds


static func _update_bounds(area) -> void:
	area.bounds_km = _bounds(area.polygon_km)
	var origin: Vector2 = area.polygon_km[0]
	var center := Vector2.ZERO
	var signed_area := 0.0
	for vertex in range(area.polygon_km.size()):
		var first: Vector2 = area.polygon_km[vertex] - origin
		var second: Vector2 = area.polygon_km[(vertex + 1) % area.polygon_km.size()] - origin
		var weight: float = first.cross(second)
		center += (first + second) * weight
		signed_area += weight
	center = origin + center / (3.0 * signed_area)
	var safe_center: bool = JurisdictionData.polygon_contains_point(center, area.polygon_km)
	if safe_center:
		for vertex in range(area.polygon_km.size()):
			var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(center, area.polygon_km[vertex], area.polygon_km[(vertex + 1) % area.polygon_km.size()])
			if center.distance_to(nearest) < JurisdictionData.BOUNDARY_TOLERANCE_KM * 4.0:
				safe_center = false
				break
	if not safe_center:
		var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(area.polygon_km)
		var largest_area := -1.0
		for triangle_index in range(0, triangles.size(), 3):
			var first: Vector2 = area.polygon_km[triangles[triangle_index]]
			var second: Vector2 = area.polygon_km[triangles[triangle_index + 1]]
			var third: Vector2 = area.polygon_km[triangles[triangle_index + 2]]
			var triangle_area: float = absf((second - first).cross(third - first))
			if triangle_area > largest_area:
				largest_area = triangle_area
				center = (first + second + third) / 3.0
	area.center_km = center


static func _settlement_point(area, rng: RandomNumberGenerator, terrain = null) -> Vector2:
	var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(area.polygon_km)
	if triangles.is_empty():
		return area.center_km
	var cumulative := PackedFloat32Array()
	var total_area := 0.0
	for triangle_index in range(0, triangles.size(), 3):
		var first: Vector2 = area.polygon_km[triangles[triangle_index]]
		var second: Vector2 = area.polygon_km[triangles[triangle_index + 1]]
		var third: Vector2 = area.polygon_km[triangles[triangle_index + 2]]
		total_area += absf((second - first).cross(third - first)) * 0.5
		cumulative.append(total_area)
	if total_area <= 0.0:
		return area.center_km
	var minimum_clearance: float = minf(2.0, sqrt(total_area) * 0.08)
	var minimum_offset: float = minf(3.0, sqrt(total_area) * 0.12)
	var best_point: Vector2 = area.center_km
	var best_clearance := -1.0
	var best_score := -INF
	for attempt in range(32):
		var pick: float = rng.randf() * total_area
		var triangle_slot := 0
		while triangle_slot < cumulative.size() - 1 and pick > cumulative[triangle_slot]:
			triangle_slot += 1
		var offset: int = triangle_slot * 3
		var first: Vector2 = area.polygon_km[triangles[offset]]
		var second: Vector2 = area.polygon_km[triangles[offset + 1]]
		var third: Vector2 = area.polygon_km[triangles[offset + 2]]
		var spread: float = sqrt(rng.randf())
		var along: float = rng.randf()
		var point: Vector2 = first * (1.0 - spread) + second * (spread * (1.0 - along)) + third * (spread * along)
		var clearance := INF
		for vertex in range(area.polygon_km.size()):
			clearance = minf(clearance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, area.polygon_km[vertex], area.polygon_km[(vertex + 1) % area.polygon_km.size()])))
		var terrain_score: float = 0.0
		if terrain != null:
			terrain_score = -300.0 if terrain.water_at(point) else -terrain.slope_at(point) * 65.0 - maxf(0.0, terrain.elevation_at(point) - 500.0) * 0.006
			if clearance < minimum_clearance or point.distance_to(area.center_km) < minimum_offset * 0.4:
				terrain_score -= 100.0
		var score: float = minf(clearance, 5.0) + terrain_score
		if point.distance_to(area.center_km) >= minimum_offset * 0.4 and score > best_score:
			best_score = score
			best_clearance = clearance
			best_point = point
		if terrain == null and clearance >= minimum_clearance and point.distance_to(area.center_km) >= minimum_offset:
			return point
	return best_point


static func segment_on_land(polygon: PackedVector2Array, first: Vector2, second: Vector2) -> bool:
	var direction: Vector2 = second - first
	if direction.length_squared() < 0.000001:
		return JurisdictionData.polygon_contains_point(first, polygon)
	var crossings: Array[float] = [0.0, 1.0]
	for vertex in range(polygon.size()):
		var intersection = Geometry2D.segment_intersects_segment(first, second, polygon[vertex], polygon[(vertex + 1) % polygon.size()])
		if intersection != null:
			crossings.append(clampf((intersection - first).dot(direction) / direction.length_squared(), 0.0, 1.0))
	crossings.sort()
	for interval in range(1, crossings.size()):
		if crossings[interval] - crossings[interval - 1] < 0.000001:
			continue
		var midpoint: Vector2 = first + direction * (crossings[interval] + crossings[interval - 1]) * 0.5
		if not JurisdictionData.polygon_contains_point(midpoint, polygon):
			return false
	return true


static func land_route(polygon: PackedVector2Array, first: Vector2, second: Vector2) -> PackedVector2Array:
	if segment_on_land(polygon, first, second):
		return PackedVector2Array([first, second])
	var points := PackedVector2Array([first, second])
	points.append_array(polygon)
	var distances := PackedFloat64Array()
	distances.resize(points.size())
	distances.fill(INF)
	distances[0] = 0.0
	var previous := PackedInt32Array()
	previous.resize(points.size())
	previous.fill(-1)
	var visited := PackedByteArray()
	visited.resize(points.size())
	for step in range(points.size()):
		var nearest := -1
		var best_distance := INF
		for point_id in range(points.size()):
			if visited[point_id] == 0 and distances[point_id] < best_distance:
				nearest = point_id
				best_distance = distances[point_id]
		if nearest < 0 or nearest == 1:
			break
		visited[nearest] = 1
		for point_id in range(points.size()):
			if visited[point_id] != 0:
				continue
			var distance: float = best_distance + points[nearest].distance_to(points[point_id])
			if distance < distances[point_id] and segment_on_land(polygon, points[nearest], points[point_id]):
				distances[point_id] = distance
				previous[point_id] = nearest
	assert(previous[1] >= 0, "Starting roads need a route around the coast.")
	var route := PackedVector2Array([second])
	var cursor := 1
	while cursor != 0:
		cursor = previous[cursor]
		route.append(points[cursor])
	route.reverse()
	return route


static func _area(polygon: PackedVector2Array) -> float:
	var result := 0.0
	var origin: Vector2 = polygon[0]
	for vertex in range(polygon.size()):
		var first: Vector2 = polygon[vertex]
		var second: Vector2 = polygon[(vertex + 1) % polygon.size()]
		var first_x: float = float(first.x) - float(origin.x)
		var first_y: float = float(first.y) - float(origin.y)
		var second_x: float = float(second.x) - float(origin.x)
		var second_y: float = float(second.y) - float(origin.y)
		result += first_x * second_y - first_y * second_x
	return absf(result) * 0.5


