extends RefCounted

const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const STATE_LAND_AREA_KM2 = 400000.0


static func generate(region, rng: RandomNumberGenerator) -> void:
	var state = region.jurisdictions[0]
	state.polygon_km = _generate_outline(region.generation_seed)
	_update_bounds(state)
	_partition(region, state, rng)
	for city in region.cities:
		var area = region.jurisdictions[city["jurisdiction_id"]]
		var center: Vector2 = area.center_km
		city["center_km"] = center
		var neighborhood_ids: Array = city["neighborhood_ids"]
		_divide_children(region, area.child_ids, area.polygon_km, rng)
		var parcels: Array = []
		for neighborhood_id in neighborhood_ids:
			var district = region.jurisdictions[region.neighborhoods[neighborhood_id].jurisdiction_id]
			parcels.append({"polygon": district.polygon_km, "center": district.center_km})
		parcels.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return first["center"].distance_squared_to(center) < second["center"].distance_squared_to(center))
		for local_id in range(neighborhood_ids.size()):
			var neighborhood = region.neighborhoods[neighborhood_ids[local_id]]
			var district = region.jurisdictions[neighborhood.jurisdiction_id]
			district.polygon_km = parcels[local_id]["polygon"]
			_update_bounds(district)
			neighborhood.position_km = district.center_km
			neighborhood.land_area_ha = _area(district.polygon_km) * 100.0
			neighborhood.developable_area_ha = minf(neighborhood.developable_area_ha, neighborhood.land_area_ha)
	region.starting_city_ids.append(0)
	while region.starting_city_ids.size() < mini(4, region.cities.size()):
		var best_id := -1
		var best_distance := -1.0
		for city in region.cities:
			if region.starting_city_ids.has(city["id"]):
				continue
			var distance := INF
			for starting_id in region.starting_city_ids:
				distance = minf(distance, city["center_km"].distance_squared_to(region.cities[starting_id]["center_km"]))
			if distance > best_distance:
				best_distance = distance
				best_id = city["id"]
		region.starting_city_ids.append(best_id)


static func initialize_development(region) -> void:
	for neighborhood in region.neighborhoods:
		neighborhood.development_jobs_by_skill = neighborhood.jobs_by_skill.duplicate()
		neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
		neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
		neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
		var local_id: int = region.cities[neighborhood.city_id]["neighborhood_ids"].find(neighborhood.id)
		neighborhood.initially_developed = region.starting_city_ids.has(neighborhood.city_id) and local_id < 3
		neighborhood.development_state = "Established" if neighborhood.initially_developed else "Dormant"
		if not neighborhood.initially_developed:
			neighborhood.households = 0
			neighborhood.population = 0
			neighborhood.jobs = 0
			neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
			neighborhood.shopping_attraction = 0.0
			neighborhood.monthly_rent = 0


static func _generate_outline(seed_value: int) -> PackedVector2Array:
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
	var sample_count: int = rng.randi_range(120, 160)
	var phase: float = rng.randf_range(0.0, TAU)
	var amplitude: float = rng.randf_range(0.025, 0.07)
	for sample_index in range(sample_count, -1, -1):
		var position: float = 0.94 * float(sample_index) / float(sample_count)
		var coastline: float = 0.87 + sin(phase + position * 7.0) * amplitude
		coastline += sin(phase * 1.7 + position * 63.0) * 0.014 + sin(phase * 2.3 + position * 137.0) * 0.007 + rng.randf_range(-0.004, 0.004)
		for bay in bays:
			coastline -= bay.z * exp(-0.5 * pow((position - bay.x) / bay.y, 2.0))
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
	return outline


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
	var first_count: int = child_ids.size() / 2
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
	for attempt in range(12):
		var axis: int = preferred_axis if attempt < 8 else 1 - preferred_axis
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
		var score: float = absf(area_fraction - target)
		if score < best_score:
			best_score = score
			best_split = [first_parts[0], second_parts[0]]
		if score < 0.08:
			break
	if best_split.is_empty():
		best_split = _straight_split(polygon, bounds, preferred_axis, target)
	assert(not best_split.is_empty(), "State geography needs a connected administrative split.")
	_divide_children(region, child_ids.slice(0, first_count), best_split[0], rng)
	_divide_children(region, child_ids.slice(first_count), best_split[1], rng)


static func _straight_split(polygon: PackedVector2Array, bounds: Rect2, preferred_axis: int, target: float) -> Array:
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
			var score: float = absf(area_fraction - target) + (0.15 if axis != preferred_axis else 0.0)
			if score < best_score:
				best_score = score
				best_split = [first_parts[0], second_parts[0]]
	return best_split


static func _rectangle(bounds: Rect2) -> PackedVector2Array:
	return PackedVector2Array([bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)])


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


