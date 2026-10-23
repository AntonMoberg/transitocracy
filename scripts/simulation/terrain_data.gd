extends RefCounted

# Generated once with the state. Queries are read-only so worker snapshots can
# safely share this object with the map and the simulation.
const GRID_KM = 2.0
const MAX_BUILDING_SLOPE = 0.25

var seed_value: int
var bounds: Rect2
var width: int
var height: int
var elevations: PackedFloat32Array = PackedFloat32Array()
var coastline: PackedVector2Array = PackedVector2Array()
var lakes: Array[Dictionary] = []
var lake_cells: Dictionary = {}
var rivers: Array[Dictionary] = []
var river_cells: Dictionary = {}
var detail_noise: FastNoiseLite
var visual_relief_noise: FastNoiseLite
var visual_detail_noise: FastNoiseLite
var visual_gully_noise: FastNoiseLite
var climate_noise: FastNoiseLite
var vegetation_noise: FastNoiseLite
var ground_noise: FastNoiseLite


func elevation_at(point: Vector2) -> float:
	if elevations.is_empty():
		return 0.0
	for lake in _near_lakes(point):
		var offset: Vector2 = point - lake["center"]
		var radius: Vector2 = lake["radius"] * 1.25
		if absf(offset.x) <= radius.x and absf(offset.y) <= radius.y and Geometry2D.is_point_in_polygon(point, lake["polygon"]):
			return lake["level_m"]
	var river_level: float = river_surface_at(point)
	if river_level < INF:
		return river_level
	var grid: Vector2 = (point - bounds.position) / GRID_KM
	var x: int = clampi(floori(grid.x), 0, width - 2)
	var y: int = clampi(floori(grid.y), 0, height - 2)
	var fx: float = clampf(grid.x - float(x), 0.0, 1.0)
	var fy: float = clampf(grid.y - float(y), 0.0, 1.0)
	var a: float = lerpf(elevations[y * width + x], elevations[y * width + x + 1], fx)
	var b: float = lerpf(elevations[(y + 1) * width + x], elevations[(y + 1) * width + x + 1], fx)
	var local: float = detail_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0) * 13.0 if detail_noise != null else 0.0
	return lerpf(a, b, fy) + local


# Interpolate the generated height samples for map shading. The simulation
# keeps its bilinear elevation_at() query for road grades and buildability.
func visual_elevation_at(point: Vector2) -> float:
	var grid: Vector2 = (point - bounds.position) / GRID_KM
	var x: int = floori(grid.x)
	var y: int = floori(grid.y)
	var fx: float = grid.x - float(x)
	var fy: float = grid.y - float(y)
	var x0: int = clampi(x - 1, 0, width - 1)
	var x1: int = clampi(x, 0, width - 1)
	var x2: int = clampi(x + 1, 0, width - 1)
	var x3: int = clampi(x + 2, 0, width - 1)
	var y0: int = clampi(y - 1, 0, height - 1) * width
	var y1: int = clampi(y, 0, height - 1) * width
	var y2: int = clampi(y + 1, 0, height - 1) * width
	var y3: int = clampi(y + 2, 0, height - 1) * width
	var base: float = _interpolate_height(
		_interpolate_height(elevations[y0 + x0], elevations[y0 + x1], elevations[y0 + x2], elevations[y0 + x3], fx),
		_interpolate_height(elevations[y1 + x0], elevations[y1 + x1], elevations[y1 + x2], elevations[y1 + x3], fx),
		_interpolate_height(elevations[y2 + x0], elevations[y2 + x1], elevations[y2 + x2], elevations[y2 + x3], fx),
		_interpolate_height(elevations[y3 + x0], elevations[y3 + x1], elevations[y3 + x2], elevations[y3 + x3], fx), fy
	)
	if visual_detail_noise == null:
		return base
	var dx: float = ((elevations[y1 + x2] - elevations[y1 + x1]) + (elevations[y2 + x2] - elevations[y2 + x1])) / (GRID_KM * 2000.0)
	var dy: float = ((elevations[y2 + x1] - elevations[y1 + x1]) + (elevations[y2 + x2] - elevations[y1 + x2])) / (GRID_KM * 2000.0)
	var hill_factor: float = smoothstep(0.03, 0.11, Vector2(dx, dy).length())
	if hill_factor <= 0.0:
		return base
	var alpine_factor: float = smoothstep(100.0, 650.0, base)
	var relief: float = visual_relief_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0) * 88.0 * alpine_factor * hill_factor if visual_relief_noise != null else 0.0
	var fine_relief: float = visual_detail_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0) * 44.0 * hill_factor
	var gullies := 0.0
	if visual_gully_noise != null:
		var gully_noise: float = visual_gully_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
		gullies = pow(maxf(0.0, 1.0 - absf(gully_noise) / 0.23), 2.0) * 62.0 * alpine_factor * hill_factor
	return base + relief + fine_relief - gullies


func land_cover_at(point: Vector2, elevation: float, gradient: Vector2) -> Vector3:
	if climate_noise == null or vegetation_noise == null:
		return Vector3.ZERO
	var climate: float = climate_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
	var patches: float = vegetation_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
	var slope: float = gradient.length()
	var moisture: float = 0.53 + climate * 0.22 + patches * 0.20 - maxf(0.0, elevation - 650.0) * 0.00010
	var woodland: float = smoothstep(0.50, 0.68, moisture) * (1.0 - smoothstep(1050.0, 1550.0, elevation))
	var dry_ground: float = (1.0 - smoothstep(0.32, 0.45, moisture)) * (1.0 - smoothstep(0.12, 0.22, slope))
	var exposed_rock: float = smoothstep(420.0, 1050.0, elevation) * smoothstep(0.055, 0.19, slope)
	return Vector3(woodland, dry_ground, exposed_rock)


func ground_detail_at(point: Vector2) -> float:
	return ground_noise.get_noise_2d(point.x * 1000.0, point.y * 1000.0) if ground_noise != null else 0.0


static func _interpolate_height(a: float, b: float, c: float, d: float, fraction: float) -> float:
	var t2: float = fraction * fraction
	var t3: float = t2 * fraction
	var value: float = 0.5 * (2.0 * b + (c - a) * fraction + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2 + (3.0 * b - a - 3.0 * c + d) * t3)
	return clampf(value, minf(b, c), maxf(b, c))


func gradient_at(point: Vector2) -> Vector2:
	var step := 0.12
	return Vector2((elevation_at(point + Vector2(step, 0.0)) - elevation_at(point - Vector2(step, 0.0))) / (step * 2000.0), (elevation_at(point + Vector2(0.0, step)) - elevation_at(point - Vector2(0.0, step))) / (step * 2000.0))


func slope_at(point: Vector2) -> float:
	return gradient_at(point).length()


func water_at(point: Vector2) -> bool:
	for lake in _near_lakes(point):
		var offset: Vector2 = point - lake["center"]
		var radius: Vector2 = lake["radius"] * 1.25
		if absf(offset.x) <= radius.x and absf(offset.y) <= radius.y and Geometry2D.is_point_in_polygon(point, lake["polygon"]):
			return true
	return river_surface_at(point) < INF


func river_surface_at(point: Vector2) -> float:
	if river_cells.is_empty():
		return INF
	var cell := Vector2i(floori(point.x / 2.0), floori(point.y / 2.0))
	var water_level := INF
	for river_id in river_cells.get(cell, []):
		var river: Dictionary = rivers[river_id]
		var line: PackedVector2Array = river["points"]
		var levels: PackedFloat32Array = river["levels"]
		var widths: PackedFloat32Array = river.get("widths_km", PackedFloat32Array())
		for i in range(1, line.size()):
			var radius: float = (widths[i - 1] + widths[i]) * 0.25 if widths.size() == line.size() else float(river["width_km"]) * 0.5
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, line[i - 1], line[i])
			if point.distance_to(closest) <= radius:
				var segment: Vector2 = line[i] - line[i - 1]
				var fraction: float = clampf((closest - line[i - 1]).dot(segment) / maxf(segment.length_squared(), 0.000001), 0.0, 1.0)
				water_level = minf(water_level, lerpf(levels[i - 1], levels[i], fraction))
	return water_level


func _near_lakes(point: Vector2) -> Array[Dictionary]:
	if lake_cells.is_empty():
		return lakes
	var cell := Vector2i(floori(point.x / 8.0), floori(point.y / 8.0))
	var result: Array[Dictionary] = []
	for lake_id in lake_cells.get(cell, []):
		result.append(lakes[lake_id])
	return result


func index_lakes() -> void:
	lake_cells.clear()
	for lake_id in range(lakes.size()):
		var lake: Dictionary = lakes[lake_id]
		var radius: Vector2 = lake["radius"] * 1.25
		var center: Vector2 = lake["center"]
		for y in range(floori((center.y - radius.y) / 8.0), floori((center.y + radius.y) / 8.0) + 1):
			for x in range(floori((center.x - radius.x) / 8.0), floori((center.x + radius.x) / 8.0) + 1):
				var cell := Vector2i(x, y)
				if not lake_cells.has(cell):
					lake_cells[cell] = []
				lake_cells[cell].append(lake_id)


func buildable_at(point: Vector2) -> bool:
	return not water_at(point) and slope_at(point) <= MAX_BUILDING_SLOPE


func footprint_buildable(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	var center := Vector2.ZERO
	for point in polygon:
		center += point
		if not buildable_at(point):
			return false
	center /= float(polygon.size())
	if not buildable_at(center):
		return false
	for i in range(polygon.size()):
		if not buildable_at((polygon[i] + polygon[(i + 1) % polygon.size()]) * 0.5):
			return false
	return true


func buildable_fraction(polygon: PackedVector2Array, resolution: int = 6) -> float:
	if polygon.size() < 3:
		return 0.0
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for vertex in polygon:
		low = low.min(vertex)
		high = high.max(vertex)
	var suitable := 0
	var sampled := 0
	for y in range(resolution):
		for x in range(resolution):
			var point: Vector2 = low + (high - low) * Vector2((float(x) + 0.5) / float(resolution), (float(y) + 0.5) / float(resolution))
			if Geometry2D.is_point_in_polygon(point, polygon):
				sampled += 1
				if buildable_at(point):
					suitable += 1
	return float(suitable) / float(maxi(1, sampled))


func index_rivers() -> void:
	river_cells.clear()
	for river_id in range(rivers.size()):
		var line: PackedVector2Array = rivers[river_id]["points"]
		var bounds_for_river := Rect2(line[0], Vector2.ZERO)
		for point in line:
			bounds_for_river = bounds_for_river.expand(point)
		var river: Dictionary = rivers[river_id]
		river["bounds"] = bounds_for_river.grow(float(river["width_km"]))
		rivers[river_id] = river
		for i in range(1, line.size()):
			var box := Rect2(line[i - 1].min(line[i]), (line[i] - line[i - 1]).abs()).grow(0.25)
			for y in range(floori(box.position.y / 2.0), floori(box.end.y / 2.0) + 1):
				for x in range(floori(box.position.x / 2.0), floori(box.end.x / 2.0) + 1):
					var key := Vector2i(x, y)
					if not river_cells.has(key):
						river_cells[key] = []
					if not river_cells[key].has(river_id):
						river_cells[key].append(river_id)
