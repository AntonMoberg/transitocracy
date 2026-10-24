extends RefCounted

const TerrainData = preload("res://scripts/simulation/terrain_data.gd")
const RIVER_CATCHMENT_CELLS = 32.0


static func generate(seed_value: int, outline: PackedVector2Array, bounds: Rect2, coastline: PackedVector2Array):
	var terrain = TerrainData.new()
	terrain.seed_value = seed_value
	terrain.coastline = coastline
	terrain.bounds = bounds.grow(TerrainData.GRID_KM)
	terrain.width = ceili(terrain.bounds.size.x / TerrainData.GRID_KM) + 1
	terrain.height = ceili(terrain.bounds.size.y / TerrainData.GRID_KM) + 1
	var broad := _noise(seed_value + 71, 0.000018, 3)
	var hills := _noise(seed_value + 179, 0.00009, 3)
	var ridges := _noise(seed_value + 307, 0.00020, 3)
	var ridge_warp := _noise(seed_value + 389, 0.000025, 2)
	var ranges: Array[Dictionary] = _mountain_ranges(seed_value, bounds)
	terrain.detail_noise = _noise(seed_value + 541, 0.00075, 2)
	terrain.visual_relief_noise = _noise(seed_value + 613, 0.00045, 3)
	terrain.visual_detail_noise = _noise(seed_value + 719, 0.0010, 3)
	terrain.visual_gully_noise = _noise(seed_value + 761, 0.00085, 3)
	terrain.climate_noise = _noise(seed_value + 823, 0.000035, 2)
	terrain.vegetation_noise = _noise(seed_value + 947, 0.000075, 2)
	terrain.ground_noise = _noise(seed_value + 991, 0.00055, 3)
	var count: int = terrain.width * terrain.height
	terrain.elevations.resize(count)
	var coast_distances := PackedFloat32Array()
	coast_distances.resize(count)
	for y in range(terrain.height):
		for x in range(terrain.width):
			var point: Vector2 = terrain.bounds.position + Vector2(x, y) * TerrainData.GRID_KM
			var id: int = y * terrain.width + x
			var coast_distance: float = point.distance_to(_closest_coast_point(point, coastline))
			coast_distances[id] = coast_distance
			var bx: float = broad.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
			var hx: float = hills.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
			var rx: float = ridges.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
			var warp: float = ridge_warp.get_noise_2d(point.x * 1000.0, point.y * 1000.0)
			var uplift := 0.0
			for range_data in ranges:
				var relative: Vector2 = point - range_data["center"]
				var along: float = relative.dot(range_data["axis"])
				var length_km: float = range_data["length"]
				var envelope: float = smoothstep(-length_km * 0.55, -length_km * 0.36, along) * (1.0 - smoothstep(length_km * 0.36, length_km * 0.55, along))
				if envelope <= 0.0:
					continue
				var width_km: float = range_data["width"]
				var bend: float = sin(along / range_data["bend_scale"] + range_data["phase"]) * width_km * 0.28 + warp * width_km * 0.8
				var across: float = absf(relative.dot(range_data["normal"]) - bend)
				var shoulder: float = exp(-0.5 * pow(across / width_km, 2.0))
				var crest: float = exp(-0.5 * pow(across / (width_km * 0.35), 2.0))
				var gully: float = pow(maxf(0.0, 1.0 - absf(rx) / 0.20), 2.0)
				var spur: float = 1.0 + rx * 0.30 + hx * 0.15 - gully * 0.55
				uplift = maxf(uplift, range_data["height"] * envelope * (shoulder * 0.70 + crest * 0.30) * maxf(0.35, spur))
			var inland_elevation: float = maxf(2.0, 75.0 + bx * 65.0 + hx * 45.0 + uplift)
			terrain.elevations[id] = lerpf(2.0, inland_elevation, smoothstep(0.0, 18.0, coast_distance))
	_smooth_elevations(terrain)
	_make_lakes(terrain, outline)
	terrain.index_lakes()
	_carve_lake_basins(terrain)
	_make_drainage(terrain, outline, coast_distances)
	_make_delta_branches(terrain, outline)
	terrain.index_rivers()
	return terrain


static func _mountain_ranges(seed_value: int, bounds: Rect2) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 811 + 5237
	var result: Array[Dictionary] = []
	var count: int = rng.randi_range(2, 3)
	for index in range(count):
		var axis: Vector2 = Vector2(1.0, rng.randf_range(-0.24, 0.24)).normalized()
		var center := bounds.position + bounds.size * Vector2(rng.randf_range(0.40, 0.62), (float(index) + 0.7) / (float(count) + 0.4))
		center += Vector2(rng.randf_range(-bounds.size.x * 0.08, bounds.size.x * 0.08), rng.randf_range(-12.0, 12.0))
		result.append({
			"center": center,
			"axis": axis,
			"normal": axis.orthogonal(),
			"length": bounds.size.x * rng.randf_range(0.52, 0.85),
			"width": rng.randf_range(17.0, 34.0),
			"height": rng.randf_range(2800.0, 3900.0) if index == count - 1 else rng.randf_range(950.0, 1800.0),
			"bend_scale": rng.randf_range(70.0, 145.0),
			"phase": rng.randf_range(0.0, TAU),
		})
	return result


static func _smooth_elevations(terrain) -> void:
	var original: PackedFloat32Array = terrain.elevations.duplicate()
	for y in range(1, terrain.height - 1):
		for x in range(1, terrain.width - 1):
			var id: int = y * terrain.width + x
			var total: float = original[id] * 4.0
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				total += original[(y + step.y) * terrain.width + x + step.x] * 2.0
			for step in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
				total += original[(y + step.y) * terrain.width + x + step.x]
			terrain.elevations[id] = total / 16.0


static func _closest_coast_point(point: Vector2, coastline: PackedVector2Array) -> Vector2:
	if coastline.size() < 2:
		return point
	var ascending: bool = coastline[-1].x >= coastline[0].x
	var low := 0
	var high: int = coastline.size() - 1
	while low < high:
		var middle: int = (low + high) / 2
		if (coastline[middle].x < point.x) == ascending:
			low = middle + 1
		else:
			high = middle
	var closest: Vector2 = coastline[clampi(low, 0, coastline.size() - 1)]
	var nearest: float = point.distance_squared_to(closest)
	for index in range(maxi(0, low - 10), mini(coastline.size() - 1, low + 10)):
		var trial: Vector2 = Geometry2D.get_closest_point_to_segment(point, coastline[index], coastline[index + 1])
		var distance: float = point.distance_squared_to(trial)
		if distance < nearest:
			nearest = distance
			closest = trial
	return closest


static func _noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	return noise


static func _lake_polygon(center: Vector2, axes: Vector2, rotation: float, seed_value: int) -> PackedVector2Array:
	var bend_noise := _noise(seed_value, 0.00020, 2)
	var bank_noise := _noise(seed_value + 37, 0.00065, 3)
	var forward: Vector2 = Vector2.from_angle(rotation)
	var across: Vector2 = forward.orthogonal()
	var steps: int = maxi(28, ceili(axes.x * 4.0))
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for index in range(steps + 1):
		var t: float = float(index) / float(steps) * 2.0 - 1.0
		var middle: Vector2 = center + forward * axes.x * t
		var bend: float = bend_noise.get_noise_2d(middle.x * 1000.0, middle.y * 1000.0) * axes.y * 0.48
		middle += across * bend
		var half_width: float = axes.y * sqrt(maxf(0.0, 1.0 - t * t))
		var left_sample: Vector2 = middle + across * half_width
		var right_sample: Vector2 = middle - across * half_width
		var left_width: float = clampf(0.94 + bank_noise.get_noise_2d(left_sample.x * 1000.0, left_sample.y * 1000.0) * 0.48, 0.62, 1.3)
		var right_width: float = clampf(0.94 + bank_noise.get_noise_2d(right_sample.x * 1000.0 + 431.0, right_sample.y * 1000.0 - 257.0) * 0.48, 0.62, 1.3)
		left.append(middle + across * half_width * left_width)
		right.append(middle - across * half_width * right_width)
	var shore := left
	for index in range(steps - 1, 0, -1):
		shore.append(right[index])
	return shore


static func _lake_bounds_radius(center: Vector2, shore: PackedVector2Array) -> Vector2:
	var radius := Vector2.ZERO
	for point in shore:
		radius.x = maxf(radius.x, absf(point.x - center.x))
		radius.y = maxf(radius.y, absf(point.y - center.y))
	return radius


static func _make_lakes(terrain, outline: PackedVector2Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain.seed_value * 65537 + 2207
	var attempts := 0
	while terrain.lakes.size() < 18 and attempts < 500:
		attempts += 1
		var center: Vector2 = terrain.bounds.position + Vector2(rng.randf(), rng.randf()) * terrain.bounds.size
		var major: bool = terrain.lakes.size() < 4
		var axes := Vector2(rng.randf_range(12.0, 23.0), rng.randf_range(2.0, 4.8)) if major else Vector2(rng.randf_range(3.0, 8.0), rng.randf_range(1.0, 2.8))
		var rotation: float = rng.randf_range(-PI, PI)
		if not Geometry2D.is_point_in_polygon(center, outline) or terrain.elevation_at(center) > (340.0 if major else 500.0) or terrain.slope_at(center) > 0.075:
			continue
		var shore: PackedVector2Array = _lake_polygon(center, axes, rotation, terrain.seed_value + attempts * 101)
		var radius: Vector2 = _lake_bounds_radius(center, shore)
		var valid := true
		for p in shore:
			if not Geometry2D.is_point_in_polygon(p, outline):
				valid = false
				break
		for lake in terrain.lakes:
			if center.distance_to(lake["center"]) < maxf(25.0, radius.length() + lake["radius"].length() + 3.0):
				valid = false
		if valid:
			var shore_level := INF
			for point in shore:
				var outward: Vector2 = (point - center).normalized()
				for distance_km in [0.0, 2.0, 4.0]:
					shore_level = minf(shore_level, terrain.elevation_at(point + outward * distance_km))
			terrain.lakes.append({"center": center, "radius": radius, "polygon": shore, "level_m": maxf(1.0, shore_level - 2.0)})


static func _carve_lake_basins(terrain) -> void:
	for lake in terrain.lakes:
		var center: Vector2 = lake["center"]
		var radius: Vector2 = lake["radius"]
		var from_x: int = maxi(0, floori((center.x - radius.x * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
		var to_x: int = mini(terrain.width - 1, ceili((center.x + radius.x * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
		var from_y: int = maxi(0, floori((center.y - radius.y * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
		var to_y: int = mini(terrain.height - 1, ceili((center.y + radius.y * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
		for y in range(from_y, to_y + 1):
			for x in range(from_x, to_x + 1):
				var point: Vector2 = terrain.bounds.position + Vector2(x, y) * TerrainData.GRID_KM
				var radius_squared: float = pow((point.x - center.x) / radius.x, 2.0) + pow((point.y - center.y) / radius.y, 2.0)
				if Geometry2D.is_point_in_polygon(point, lake["polygon"]):
					var id: int = y * terrain.width + x
					terrain.elevations[id] = maxf(1.0, minf(terrain.elevations[id], float(lake["level_m"]) - 8.0 - 18.0 * maxf(0.0, 1.0 - radius_squared)))


static func _priority_push(heap: Array[int], heights: PackedFloat32Array, id: int) -> void:
	heap.append(id)
	var child: int = heap.size() - 1
	while child > 0:
		var parent: int = (child - 1) / 2
		var other: int = heap[parent]
		if heights[other] < heights[id] or (heights[other] == heights[id] and other <= id):
			break
		heap[child] = other
		child = parent
	heap[child] = id


static func _priority_pop(heap: Array[int], heights: PackedFloat32Array) -> int:
	var result: int = heap[0]
	var last: int = heap.pop_back()
	if heap.is_empty():
		return result
	var parent := 0
	while parent * 2 + 1 < heap.size():
		var child: int = parent * 2 + 1
		if child + 1 < heap.size():
			var left: int = heap[child]
			var right: int = heap[child + 1]
			if heights[right] < heights[left] or (heights[right] == heights[left] and right < left):
				child += 1
		var other: int = heap[child]
		if heights[last] < heights[other] or (heights[last] == heights[other] and last <= other):
			break
		heap[parent] = other
		parent = child
	heap[parent] = last
	return result


# Flood inward from coast and lake outlets using each cell's original height.
# This keeps river directions in the valleys while breaching local DEM sinks.
static func _make_drainage(terrain, outline: PackedVector2Array, coast_distances: PackedFloat32Array) -> void:
	var count: int = terrain.width * terrain.height
	var land := PackedByteArray()
	land.resize(count)
	var seed_type := PackedByteArray()
	seed_type.resize(count)
	var parent := PackedInt32Array()
	parent.resize(count)
	parent.fill(-1)
	var effective_height: PackedFloat32Array = terrain.elevations.duplicate()
	var visited := PackedByteArray()
	visited.resize(count)
	var frontier: Array[int] = []
	for y in range(terrain.height):
		for x in range(terrain.width):
			var id: int = y * terrain.width + x
			var point: Vector2 = terrain.bounds.position + Vector2(x, y) * TerrainData.GRID_KM
			if not Geometry2D.is_point_in_polygon(point, outline):
				continue
			land[id] = 1
			if terrain.water_at(point):
				seed_type[id] = 2
				effective_height[id] = terrain.elevation_at(point)
			elif coast_distances[id] <= TerrainData.GRID_KM * 1.2:
				seed_type[id] = 1
				effective_height[id] = 1.0
			if seed_type[id] != 0:
				visited[id] = 1
				_priority_push(frontier, effective_height, id)
	while not frontier.is_empty():
		var id: int = _priority_pop(frontier, effective_height)
		var x: int = id % terrain.width
		var y: int = id / terrain.width
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN, Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
			var nx: int = x + step.x
			var ny: int = y + step.y
			if nx < 0 or ny < 0 or nx >= terrain.width or ny >= terrain.height:
				continue
			var other: int = ny * terrain.width + nx
			if land[other] == 0 or visited[other] != 0:
				continue
			visited[other] = 1
			parent[other] = id
			_priority_push(frontier, effective_height, other)
	var accumulation := PackedFloat32Array()
	var root_ids := PackedInt32Array()
	root_ids.resize(count)
	var flow_order := PackedInt32Array()
	for _pass_index in range(32):
		var children := PackedInt32Array()
		children.resize(count)
		for id in range(count):
			if parent[id] >= 0:
				children[parent[id]] += 1
		accumulation.resize(count)
		accumulation.fill(1.0)
		var queue := PackedInt32Array()
		for id in range(count):
			if land[id] != 0 and children[id] == 0:
				queue.append(id)
		var queue_index := 0
		while queue_index < queue.size():
			var id: int = queue[queue_index]
			queue_index += 1
			if parent[id] < 0:
				continue
			var downstream: int = parent[id]
			accumulation[downstream] += accumulation[id]
			children[downstream] -= 1
			if children[downstream] == 0:
				queue.append(downstream)
		flow_order = queue
		for queue_id in range(queue.size() - 1, -1, -1):
			var id: int = queue[queue_id]
			root_ids[id] = id if parent[id] < 0 else root_ids[parent[id]]
		var basin_candidates: Dictionary = {}
		var lake_root_levels: Dictionary = {}
		for id in range(count):
			if parent[id] < 0 or accumulation[id] < RIVER_CATCHMENT_CELLS:
				continue
			var root: int = root_ids[id]
			if seed_type[root] != 2:
				continue
			if not lake_root_levels.has(root):
				var root_point: Vector2 = terrain.bounds.position + Vector2(root % terrain.width, root / terrain.width) * TerrainData.GRID_KM
				lake_root_levels[root] = terrain.elevation_at(root_point)
			if terrain.elevations[id] + 1.0 >= float(lake_root_levels[root]):
				continue
			var previous: int = basin_candidates.get(root, -1)
			if previous < 0 or terrain.elevations[id] < terrain.elevations[previous]:
				basin_candidates[root] = id
		if basin_candidates.is_empty() or _pass_index == 31:
			break
		for root in basin_candidates:
			var basin_id: int = basin_candidates[root]
			var center: Vector2 = terrain.bounds.position + Vector2(basin_id % terrain.width, basin_id / terrain.width) * TerrainData.GRID_KM
			var radius_km: float = clampf(1.2 + sqrt(accumulation[basin_id]) * 0.035, 1.5, 4.0)
			var downstream_point: Vector2 = terrain.bounds.position + Vector2(parent[basin_id] % terrain.width, parent[basin_id] / terrain.width) * TerrainData.GRID_KM
			var rotation: float = (downstream_point - center).angle()
			var shore := PackedVector2Array()
			var radius := Vector2.ZERO
			for _shrink in range(5):
				shore = _lake_polygon(center, Vector2(radius_km * 1.8, radius_km * 0.72), rotation, terrain.seed_value + basin_id * 19)
				radius = _lake_bounds_radius(center, shore)
				var inside := true
				for shore_point in shore:
					if not Geometry2D.is_point_in_polygon(shore_point, outline):
						inside = false
						break
				if inside:
					break
				radius_km *= 0.5
			terrain.lakes.append({"center": center, "radius": radius, "polygon": shore, "level_m": maxf(1.0, terrain.elevations[basin_id])})
			var lake_left: int = maxi(0, floori((center.x - radius.x * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
			var lake_right: int = mini(terrain.width - 1, ceili((center.x + radius.x * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
			var lake_top: int = maxi(0, floori((center.y - radius.y * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
			var lake_bottom: int = mini(terrain.height - 1, ceili((center.y + radius.y * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
			for lake_y in range(lake_top, lake_bottom + 1):
				for lake_x in range(lake_left, lake_right + 1):
					var lake_point: Vector2 = terrain.bounds.position + Vector2(lake_x, lake_y) * TerrainData.GRID_KM
					if Geometry2D.is_point_in_polygon(lake_point, shore):
						var lake_id: int = lake_y * terrain.width + lake_x
						parent[lake_id] = -1
						seed_type[lake_id] = 2
		terrain.index_lakes()
	_record_visual_valleys(terrain, parent, accumulation, land)
	var river_cells := PackedByteArray()
	river_cells.resize(count)
	for id in range(count):
		var point: Vector2 = terrain.bounds.position + Vector2(id % terrain.width, id / terrain.width) * TerrainData.GRID_KM
		if parent[id] >= 0 and accumulation[id] >= RIVER_CATCHMENT_CELLS and Geometry2D.is_point_in_polygon(point, outline) and not terrain.water_at(point):
			river_cells[id] = 1
	var channel_levels: PackedFloat32Array = effective_height.duplicate()
	for id in flow_order:
		if river_cells[id] == 0:
			continue
		var downstream: int = parent[id]
		if downstream >= 0 and river_cells[downstream] != 0:
			channel_levels[downstream] = minf(channel_levels[downstream], channel_levels[id] - 0.01)
	var used := PackedByteArray()
	used.resize(count)
	for id in range(count):
		if river_cells[id] == 0 or used[id] != 0:
			continue
		var source := true
		var x: int = id % terrain.width
		var y: int = id / terrain.width
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nx: int = x + dx
				var ny: int = y + dy
				if nx >= 0 and ny >= 0 and nx < terrain.width and ny < terrain.height:
					var other: int = ny * terrain.width + nx
					if river_cells[other] != 0 and parent[other] == id:
						source = false
		if not source:
			continue
		var line := PackedVector2Array()
		var levels := PackedFloat32Array()
		var widths := PackedFloat32Array()
		var source_point: Vector2 = terrain.bounds.position + Vector2(id % terrain.width, id / terrain.width) * TerrainData.GRID_KM
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 0 or ny < 0 or nx >= terrain.width or ny >= terrain.height:
					continue
				var upstream: int = ny * terrain.width + nx
				if parent[upstream] != id:
					continue
				var upstream_point: Vector2 = terrain.bounds.position + Vector2(nx, ny) * TerrainData.GRID_KM
				var upstream_lake: Dictionary = _lake_at(terrain, upstream_point)
				if not upstream_lake.is_empty():
					line.append(_boundary_crossing(upstream_point, source_point, upstream_lake["polygon"]))
					levels.append(float(upstream_lake["level_m"]))
					widths.append(_river_width(accumulation[id]))
					break
			if not line.is_empty():
				break
		var cursor := id
		var largest := 0.0
		var outlet := ""
		while cursor >= 0 and river_cells[cursor] != 0 and used[cursor] == 0:
			used[cursor] = 1
			var current_point: Vector2 = terrain.bounds.position + Vector2(cursor % terrain.width, cursor / terrain.width) * TerrainData.GRID_KM
			line.append(current_point)
			levels.append(channel_levels[cursor])
			widths.append(_river_width(accumulation[cursor]))
			largest = maxf(largest, accumulation[cursor])
			var downstream: int = parent[cursor]
			if downstream < 0:
				break
			var downstream_point: Vector2 = terrain.bounds.position + Vector2(downstream % terrain.width, downstream / terrain.width) * TerrainData.GRID_KM
			var lake_entry: Dictionary = _first_lake_crossing(terrain, current_point, downstream_point)
			if not lake_entry.is_empty():
				line.append(lake_entry["point"])
				levels.append(float(lake_entry["lake"]["level_m"]))
				widths.append(_river_width(accumulation[cursor]))
				outlet = "lake"
				break
			if river_cells[downstream] == 0:
				if seed_type[downstream] == 2:
					var downstream_lake: Dictionary = _lake_at(terrain, downstream_point)
					if not downstream_lake.is_empty():
						line.append(_boundary_crossing(current_point, downstream_point, downstream_lake["polygon"]))
						levels.append(float(downstream_lake["level_m"]))
						widths.append(_river_width(accumulation[cursor]))
						outlet = "lake"
						break
				if seed_type[downstream] == 1:
					line.append(downstream_point)
					levels.append(effective_height[downstream])
					widths.append(_river_width(accumulation[downstream]))
					line.append(_closest_coast_point(downstream_point, terrain.coastline))
					levels.append(0.0)
					widths.append(_river_width(accumulation[downstream]))
				else:
					line.append(_boundary_crossing(current_point, downstream_point, outline))
					levels.append(effective_height[downstream])
					widths.append(_river_width(accumulation[downstream]))
				outlet = "sea"
				break
			if used[downstream] != 0:
				line.append(downstream_point)
				levels.append(channel_levels[downstream])
				widths.append(_river_width(accumulation[downstream]))
				outlet = "confluence"
				break
			cursor = downstream
		if line.size() >= 3:
			if outlet == "lake":
				var lake_level: float = levels[-1]
				for level_index in range(levels.size() - 2, -1, -1):
					levels[level_index] = maxf(levels[level_index], lake_level)
			for level_index in range(1, levels.size()):
				levels[level_index] = minf(levels[level_index], levels[level_index - 1])
			var smoothed: Dictionary = _smooth_river(line, levels, widths, outlet)
			terrain.rivers.append({"points": smoothed["points"], "levels": smoothed["levels"], "widths_km": smoothed["widths_km"], "width_km": _river_width(largest), "outlet": outlet})


static func _record_visual_valleys(terrain, parent: PackedInt32Array, accumulation: PackedFloat32Array, land: PackedByteArray) -> void:
	var count: int = terrain.width * terrain.height
	terrain.visual_valley_depths.resize(count)
	for id in range(count):
		if land[id] == 0 or parent[id] < 0 or accumulation[id] < 12.0:
			continue
		var depth: float = minf(34.0, (sqrt(accumulation[id]) - 3.0) * 3.0)
		var x: int = id % terrain.width
		var y: int = id / terrain.width
		for offset_y in range(-2, 3):
			for offset_x in range(-2, 3):
				var nx: int = x + offset_x
				var ny: int = y + offset_y
				if nx < 0 or ny < 0 or nx >= terrain.width or ny >= terrain.height:
					continue
				var other: int = ny * terrain.width + nx
				if land[other] != 0:
					var weight: float = exp(-0.55 * float(offset_x * offset_x + offset_y * offset_y))
					terrain.visual_valley_depths[other] = maxf(terrain.visual_valley_depths[other], depth * weight)


static func _lake_at(terrain, point: Vector2) -> Dictionary:
	for lake in terrain._near_lakes(point):
		var offset: Vector2 = point - lake["center"]
		var radius: Vector2 = lake["radius"] * 1.25
		if absf(offset.x) <= radius.x and absf(offset.y) <= radius.y and Geometry2D.is_point_in_polygon(point, lake["polygon"]):
			return lake
	return {}


static func _first_lake_crossing(terrain, first: Vector2, last: Vector2) -> Dictionary:
	var nearest := INF
	var result: Dictionary = {}
	var candidates: Array[Dictionary] = terrain._near_lakes((first + last) * 0.5)
	for lake in terrain._near_lakes(last):
		if not candidates.has(lake):
			candidates.append(lake)
	for lake in candidates:
		var polygon: PackedVector2Array = lake["polygon"]
		for edge in range(polygon.size()):
			var crossing = Geometry2D.segment_intersects_segment(first, last, polygon[edge], polygon[(edge + 1) % polygon.size()])
			if crossing == null:
				continue
			var distance: float = first.distance_squared_to(crossing)
			if distance < nearest:
				nearest = distance
				result = {"lake": lake, "point": crossing}
	return result


static func _boundary_crossing(first: Vector2, last: Vector2, polygon: PackedVector2Array) -> Vector2:
	for edge in range(polygon.size()):
		var crossing = Geometry2D.segment_intersects_segment(first, last, polygon[edge], polygon[(edge + 1) % polygon.size()])
		if crossing != null:
			return crossing
	var first_inside: bool = Geometry2D.is_point_in_polygon(first, polygon)
	if first_inside != Geometry2D.is_point_in_polygon(last, polygon):
		var outside: Vector2 = last if first_inside else first
		var inside: Vector2 = first if first_inside else last
		for _iteration in range(24):
			var midpoint: Vector2 = (outside + inside) * 0.5
			if Geometry2D.is_point_in_polygon(midpoint, polygon):
				inside = midpoint
			else:
				outside = midpoint
		return (outside + inside) * 0.5
	return (first + last) * 0.5


static func _river_width(catchment_cells: float) -> float:
	return clampf(0.018 + sqrt(maxf(0.0, catchment_cells)) * 0.0065, 0.035, 0.32)


static func _make_delta_branches(terrain, outline: PackedVector2Array) -> void:
	var mouths := PackedVector2Array()
	var original_count: int = terrain.rivers.size()
	for river_id in range(original_count):
		if mouths.size() >= 6:
			break
		var river: Dictionary = terrain.rivers[river_id]
		if river["outlet"] != "sea" or float(river["width_km"]) < 0.16:
			continue
		var line: PackedVector2Array = river["points"]
		var levels: PackedFloat32Array = river["levels"]
		var widths: PackedFloat32Array = river["widths_km"]
		var mouth: Vector2 = line[-1]
		var near_existing := false
		for previous_mouth in mouths:
			if mouth.distance_to(previous_mouth) < 35.0:
				near_existing = true
				break
		if near_existing:
			continue
		var branch_index: int = line.size() - 2
		var upstream_distance := 0.0
		while branch_index > 1 and upstream_distance < 8.0:
			upstream_distance += line[branch_index].distance_to(line[branch_index + 1])
			branch_index -= 1
		if upstream_distance < 5.0 or levels[branch_index] < 0.5:
			continue
		var start: Vector2 = line[branch_index]
		if terrain.gradient_at(start).length() > 0.08:
			continue
		var forward: Vector2 = (mouth - start).normalized()
		if forward.length_squared() < 0.5:
			continue
		var across: Vector2 = forward.orthogonal()
		for side in [1.0, -1.0]:
			var target: Vector2 = _closest_coast_point(mouth + across * side * 5.5, terrain.coastline)
			if target.distance_to(mouth) < 1.5 or target.distance_to(mouth) > 12.0:
				continue
			var guide: Vector2 = start.lerp(target, 0.55) + across * side * 2.2
			var branch := PackedVector2Array()
			var branch_levels := PackedFloat32Array()
			var branch_widths := PackedFloat32Array()
			var valid := true
			for sample_index in range(25):
				var t: float = float(sample_index) / 24.0
				var position: Vector2 = start * pow(1.0 - t, 2.0) + guide * (2.0 * (1.0 - t) * t) + target * t * t
				if sample_index < 24 and not Geometry2D.is_point_in_polygon(position, outline):
					valid = false
					break
				branch.append(position)
				branch_levels.append(lerpf(levels[branch_index], 0.0, t))
				branch_widths.append(widths[branch_index] * lerpf(0.48, 0.70, t))
			if not valid:
				continue
			terrain.rivers.append({"points": branch, "levels": branch_levels, "widths_km": branch_widths, "width_km": branch_widths[-1], "outlet": "sea", "delta_branch": true})
			mouths.append(mouth)
			break


static func _smooth_river(line: PackedVector2Array, levels: PackedFloat32Array, widths: PackedFloat32Array, outlet: String) -> Dictionary:
	var curve := PackedVector2Array([line[0]])
	var curve_levels := PackedFloat32Array([levels[0]])
	var curve_widths := PackedFloat32Array([widths[0]])
	for index in range(line.size() - 1):
		var before: Vector2 = line[maxi(0, index - 1)]
		var start: Vector2 = line[index]
		var end: Vector2 = line[index + 1]
		var after: Vector2 = line[mini(line.size() - 1, index + 2)]
		for subdivision in range(1, 5):
			var fraction: float = float(subdivision) * 0.25
			var position: Vector2 = start.lerp(end, fraction)
			if subdivision < 4 and not (outlet == "lake" and index == line.size() - 2):
				var t2: float = fraction * fraction
				var t3: float = t2 * fraction
				var tangent_a: Vector2 = (end - before) * 0.5
				var tangent_b: Vector2 = (after - start) * 0.5
				var curved: Vector2 = start * (2.0 * t3 - 3.0 * t2 + 1.0) + tangent_a * (t3 - 2.0 * t2 + fraction) + end * (-2.0 * t3 + 3.0 * t2) + tangent_b * (t3 - t2)
				var offset: Vector2 = curved - position
				position += offset.limit_length(minf(0.55, start.distance_to(end) * 0.28))
			curve.append(position)
			curve_levels.append(lerpf(levels[index], levels[index + 1], fraction))
			curve_widths.append(lerpf(widths[index], widths[index + 1], fraction))
	return {"points": curve, "levels": curve_levels, "widths_km": curve_widths}
