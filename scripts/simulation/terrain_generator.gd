extends RefCounted

const TerrainData = preload("res://scripts/simulation/terrain_data.gd")
const RIVER_CATCHMENT_CELLS = 54.0


static func generate(seed_value: int, outline: PackedVector2Array, bounds: Rect2, coastline: PackedVector2Array):
	var terrain = TerrainData.new()
	terrain.seed_value = seed_value
	terrain.coastline = coastline
	terrain.bounds = bounds.grow(TerrainData.GRID_KM)
	terrain.width = ceili(terrain.bounds.size.x / TerrainData.GRID_KM) + 1
	terrain.height = ceili(terrain.bounds.size.y / TerrainData.GRID_KM) + 1
	var broad := _noise(seed_value + 71, 0.000018, 3)
	var hills := _noise(seed_value + 179, 0.00009, 3)
	var ridges := _noise(seed_value + 307, 0.00018, 2)
	var ridge_warp := _noise(seed_value + 389, 0.000035, 2)
	terrain.detail_noise = _noise(seed_value + 541, 0.00075, 2)
	terrain.visual_relief_noise = _noise(seed_value + 613, 0.0006, 3)
	terrain.visual_detail_noise = _noise(seed_value + 719, 0.0018, 2)
	terrain.climate_noise = _noise(seed_value + 823, 0.000035, 2)
	terrain.vegetation_noise = _noise(seed_value + 947, 0.00015, 2)
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
			var mountain: float = smoothstep(0.03, 0.5, bx)
			# A bent ridge train gives mountain districts continuous spurs and
			# valleys rather than isolated circular bumps. The broad noise still
			# determines where mountain country exists.
			var bend: float = ridge_warp.get_noise_2d(point.x * 1000.0, point.y * 1000.0) * 11.0
			var cross_ridge_km: float = point.x * 0.47 + point.y * 0.88 + bend
			var crest: float = pow(maxf(0.0, cos(cross_ridge_km * TAU / 14.0)), 2.0)
			var inland_elevation: float = maxf(2.0, 90.0 + bx * 140.0 + hx * (70.0 + mountain * 100.0) + crest * mountain * (2800.0 + rx * 300.0))
			terrain.elevations[id] = lerpf(2.0, inland_elevation, smoothstep(0.0, 18.0, coast_distance))
	_smooth_elevations(terrain)
	_make_lakes(terrain, outline)
	terrain.index_lakes()
	_carve_lake_basins(terrain)
	_make_drainage(terrain, outline, coast_distances)
	terrain.index_rivers()
	return terrain


static func _smooth_elevations(terrain) -> void:
	for _pass_index in range(1):
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


static func _make_lakes(terrain, outline: PackedVector2Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = terrain.seed_value * 65537 + 2207
	var attempts := 0
	while terrain.lakes.size() < 18 and attempts < 500:
		attempts += 1
		var center: Vector2 = terrain.bounds.position + Vector2(rng.randf(), rng.randf()) * terrain.bounds.size
		var major: bool = terrain.lakes.size() < 4
		var axes := Vector2(rng.randf_range(9.0, 18.0), rng.randf_range(3.0, 7.0)) if major else Vector2(rng.randf_range(2.0, 7.0), rng.randf_range(1.3, 5.0))
		var rotation: float = rng.randf_range(-PI, PI)
		var axis_x: Vector2 = Vector2.from_angle(rotation) * axes.x
		var axis_y: Vector2 = Vector2.from_angle(rotation + PI * 0.5) * axes.y
		var radius := Vector2(absf(axis_x.x) + absf(axis_y.x), absf(axis_x.y) + absf(axis_y.y))
		if not Geometry2D.is_point_in_polygon(center, outline) or terrain.elevation_at(center) > 430.0:
			continue
		var phase_a: float = rng.randf_range(0.0, TAU)
		var phase_b: float = rng.randf_range(0.0, TAU)
		var shore := PackedVector2Array()
		for angle_index in range(72):
			var angle: float = float(angle_index) * TAU / 72.0
			var waviness: float = 1.0 + 0.13 * sin(3.0 * angle + phase_a) + 0.07 * sin(7.0 * angle + phase_b)
			shore.append(center + (axis_x * cos(angle) + axis_y * sin(angle)) * waviness)
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
			var shore := PackedVector2Array()
			for _shrink in range(5):
				shore.clear()
				for angle_index in range(32):
					var angle: float = float(angle_index) * TAU / 32.0
					var wobble: float = 1.0 + 0.12 * sin(angle * 5.0 + float(basin_id) * 0.17)
					shore.append(center + Vector2.from_angle(angle) * radius_km * wobble)
				var inside := true
				for shore_point in shore:
					if not Geometry2D.is_point_in_polygon(shore_point, outline):
						inside = false
						break
				if inside:
					break
				radius_km *= 0.5
			terrain.lakes.append({"center": center, "radius": Vector2.ONE * radius_km, "polygon": shore, "level_m": maxf(1.0, terrain.elevations[basin_id])})
			var lake_left: int = maxi(0, floori((center.x - radius_km * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
			var lake_right: int = mini(terrain.width - 1, ceili((center.x + radius_km * 1.25 - terrain.bounds.position.x) / TerrainData.GRID_KM))
			var lake_top: int = maxi(0, floori((center.y - radius_km * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
			var lake_bottom: int = mini(terrain.height - 1, ceili((center.y + radius_km * 1.25 - terrain.bounds.position.y) / TerrainData.GRID_KM))
			for lake_y in range(lake_top, lake_bottom + 1):
				for lake_x in range(lake_left, lake_right + 1):
					var lake_point: Vector2 = terrain.bounds.position + Vector2(lake_x, lake_y) * TerrainData.GRID_KM
					if Geometry2D.is_point_in_polygon(lake_point, shore):
						var lake_id: int = lake_y * terrain.width + lake_x
						parent[lake_id] = -1
						seed_type[lake_id] = 2
		terrain.index_lakes()
	var river_cells := PackedByteArray()
	river_cells.resize(count)
	for id in range(count):
		var point: Vector2 = terrain.bounds.position + Vector2(id % terrain.width, id / terrain.width) * TerrainData.GRID_KM
		if parent[id] >= 0 and accumulation[id] >= RIVER_CATCHMENT_CELLS and Geometry2D.is_point_in_polygon(point, outline) and not terrain.water_at(point):
			river_cells[id] = 1
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
			levels.append(effective_height[cursor])
			largest = maxf(largest, accumulation[cursor])
			var downstream: int = parent[cursor]
			if downstream < 0:
				break
			var downstream_point: Vector2 = terrain.bounds.position + Vector2(downstream % terrain.width, downstream / terrain.width) * TerrainData.GRID_KM
			var lake_entry: Dictionary = _first_lake_crossing(terrain, current_point, downstream_point)
			if not lake_entry.is_empty():
				line.append(lake_entry["point"])
				levels.append(float(lake_entry["lake"]["level_m"]))
				outlet = "lake"
				break
			if river_cells[downstream] == 0:
				if seed_type[downstream] == 1:
					line.append(downstream_point)
					levels.append(effective_height[downstream])
					line.append(_closest_coast_point(downstream_point, terrain.coastline))
					levels.append(0.0)
				else:
					line.append(_boundary_crossing(current_point, downstream_point, outline))
					levels.append(effective_height[downstream])
				outlet = "sea"
				break
			if used[downstream] != 0:
				line.append(downstream_point)
				levels.append(effective_height[downstream])
				outlet = "confluence"
				break
			cursor = downstream
		if line.size() >= 3:
			for level_index in range(1, levels.size()):
				levels[level_index] = minf(levels[level_index], levels[level_index - 1] - 0.01)
			terrain.rivers.append({"points": _smooth_river(line), "levels": _smooth_river_levels(levels), "width_km": clampf(0.035 + sqrt(largest) * 0.006, 0.05, 0.24), "outlet": outlet})


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
	return (first + last) * 0.5


static func _smooth_river(line: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array([line[0]])
	for i in range(1, line.size()):
		result.append(line[i - 1].lerp(line[i], 0.25))
		result.append(line[i - 1].lerp(line[i], 0.75))
	result.append(line[-1])
	return result


static func _smooth_river_levels(levels: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array([levels[0]])
	for i in range(1, levels.size()):
		result.append(lerpf(levels[i - 1], levels[i], 0.25))
		result.append(lerpf(levels[i - 1], levels[i], 0.75))
	result.append(levels[-1])
	return result
