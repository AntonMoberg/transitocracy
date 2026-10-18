extends RefCounted

const Layout = preload("res://scripts/simulation/street_layout.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const SPACING_KM = 0.12
const FRONTAGE_KM = 1.2
const DEPTH_KM = 0.72


static func generate(region, city_id: int, route: PackedVector2Array, key: String, exclusions: Array = [], edge_frontage: bool = false, boundary_routes: Array = [], arterial_sides: PackedByteArray = PackedByteArray()):
	var layout = Layout.new()
	layout.key = key
	layout.city_id = city_id
	if route.size() < 2:
		return layout
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%s" % [region.generation_seed, key])
	var style: int = rng.randi_range(0, 4)
	var length: float = _route_length(route)
	var columns: int = maxi(4, roundi(length / SPACING_KM))
	var rows := 12
	var half_row: int = 0 if edge_frontage else rows / 2
	var maximum_distance: int = rows if edge_frontage else rows / 2
	var available_sides: PackedByteArray = PackedByteArray([1, 1, 1, 1]) if arterial_sides.is_empty() else arterial_sides
	var column_fractions: PackedFloat32Array = _fractions(columns, rng, style != 0)
	var row_fractions: PackedFloat32Array = _fractions(rows, rng, style != 0)
	if not edge_frontage:
		row_fractions = _fractions(rows / 2, rng, style != 0)
		for index in range(row_fractions.size()):
			row_fractions[index] *= 0.5
		var upper_rows: PackedFloat32Array = _fractions(rows / 2, rng, style != 0)
		for index in range(1, upper_rows.size()):
			row_fractions.append(0.5 + upper_rows[index] * 0.5)
	if not boundary_routes.is_empty():
		var boundary_rng := RandomNumberGenerator.new()
		boundary_rng.seed = hash("%d:boundary-streets:%d" % [region.generation_seed, city_id])
		column_fractions = _boundary_fractions(_fractions(roundi(FRONTAGE_KM / SPACING_KM), boundary_rng, true))
		row_fractions = _boundary_fractions(_fractions(rows, boundary_rng, true))
		columns = column_fractions.size() - 1
		rows = row_fractions.size() - 1
		maximum_distance = rows
	var upper_depths := PackedFloat32Array([1, 1, 1, 1])
	var lower_depths := PackedFloat32Array([1, 1, 1, 1])
	if style != 0 and not edge_frontage:
		for index in range(4):
			upper_depths[index] = rng.randf_range(0.65, 1.35)
			lower_depths[index] = rng.randf_range(0.65, 1.35)
	var samples := PackedVector2Array()
	var normals := PackedVector2Array()
	for column in range(columns + 1):
		var distance: float = length * column_fractions[column]
		var point: Vector2 = _along(route, distance)
		var tangent: Vector2 = (_along(route, minf(length, distance + 0.02)) - _along(route, maxf(0.0, distance - 0.02))).normalized()
		samples.append(point)
		normals.append(Vector2(-tangent.y, tangent.x))
	var outline := PackedVector2Array()
	if not boundary_routes.is_empty():
		for side in range(4):
			var points: PackedVector2Array = boundary_routes[side].duplicate()
			if side >= 2:
				points.reverse()
			outline.append_array(points.slice(0, points.size() - 1))
	else:
		for column in range(columns + 1):
			var depth: float = DEPTH_KM * (2.0 if edge_frontage else _profile(upper_depths, column_fractions[column]))
			outline.append(samples[column] + normals[column] * depth)
		for column in range(columns, -1, -1):
			var depth: float = 0.0 if edge_frontage else DEPTH_KM * _profile(lower_depths, column_fractions[column])
			outline.append(samples[column] - normals[column] * depth)
	var pieces: Array = Geometry2D.intersect_polygons(outline, city.polygon_km)
	if pieces.size() != 1:
		return layout
	outline = pieces[0]
	for exclusion in exclusions:
		if Geometry2D.intersect_polygons(outline, exclusion).is_empty():
			continue
		pieces = Geometry2D.clip_polygons(outline, exclusion)
		if pieces.size() != 1:
			return layout
		outline = pieces[0]
	outline = _clean_polygon(outline)
	if outline.size() < 3 or Geography.polygon_area(outline) < 0.4 or triangulate(outline).is_empty():
		return layout
	layout.polygon = outline
	layout.bounds = Geography._bounds(outline)
	var convex: bool = absf(Geography.polygon_area(Geometry2D.convex_hull(outline)) - Geography.polygon_area(outline)) < 0.000001
	var grid: Dictionary = {}
	var bend: float = 0.0 if style == 0 else rng.randf_range(0.035, 0.075)
	var phase: float = rng.randf_range(0.0, TAU)
	for row in range(rows + 1):
		for column in range(columns + 1):
			var across: float = column_fractions[column]
			var inward: float = row_fractions[row]
			var position: Vector2
			if not boundary_routes.is_empty():
				position = _boundary_point(boundary_routes, across, inward)
			else:
				var lateral: float = inward * DEPTH_KM * 2.0
				if not edge_frontage:
					lateral = (inward * 2.0 - 1.0) * DEPTH_KM * _profile(lower_depths if row < half_row else upper_depths, across)
				position = samples[column] + normals[column] * lateral
			if row > 0 and row < rows and row != half_row and column > 0 and column < columns:
				var fade: float = sin(across * PI) * sin(PI * (inward if edge_frontage else absf(inward * 2.0 - 1.0)))
				position += normals[column] * sin(across * TAU + phase) * bend * fade
				position += normals[column].orthogonal() * sin(inward * TAU + phase) * bend * fade * 0.5
			if not Jurisdiction.polygon_contains_point(position, outline):
				continue
			grid[Vector2i(column, row)] = layout.nodes.size()
			layout.nodes.append(position)
			var arterial: bool = row == half_row if not edge_frontage else ((row == 0 and available_sides[0] != 0) or (column == columns and available_sides[1] != 0) or (row == rows and available_sides[2] != 0) or (column == 0 and available_sides[3] != 0))
			if arterial:
				layout.arterial_nodes.append(layout.nodes.size() - 1)
	for row in range(rows + 1):
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			if not grid.has(address):
				continue
			for step in [Vector2i.RIGHT, Vector2i.DOWN]:
				var next: Vector2i = address + step
				if not grid.has(next):
					continue
				var first: int = grid[address]
				var second: int = grid[next]
				if not convex and not Geography.segment_on_land(outline, layout.nodes[first], layout.nodes[second]):
					continue
				var road_class: String = Roads.LOCAL
				if edge_frontage and ((step == Vector2i.RIGHT and row in [0, rows]) or (step == Vector2i.DOWN and column in [0, columns])):
					var side: int = (0 if row == 0 else 2) if step == Vector2i.RIGHT else (3 if column == 0 else 1)
					road_class = Roads.ARTERIAL if available_sides[side] != 0 else Roads.COLLECTOR
				elif not edge_frontage and step == Vector2i.RIGHT and row == half_row:
					road_class = Roads.ARTERIAL
				elif (step == Vector2i.RIGHT and absi(row - half_row) == 3) or (step == Vector2i.DOWN and (column % 4 == 0 or column == columns)):
					road_class = Roads.COLLECTOR
				var stage: int = _phase(maxi(absi(row - half_row), absi(next.y - half_row)), maximum_distance)
				if road_class == Roads.COLLECTOR and step == Vector2i.DOWN:
					stage = 1
				_append_edge(layout, first, second, road_class, stage)
	var diagonals: Dictionary = {}
	if style >= 2:
		var run: int = mini(rng.randi_range(3, 5), columns - 2)
		var first_column: int = rng.randi_range(0, columns - run)
		var first_row: int = rng.randi_range(1, rows - run - 1)
		var descending: bool = rng.randf() < 0.5
		for index in range(run):
			diagonals[Vector2i(first_column + index, first_row + (run - index - 1 if descending else index))] = descending
	for row in range(rows):
		for column in range(columns):
			var corners: Array[Vector2i] = [Vector2i(column, row), Vector2i(column + 1, row), Vector2i(column + 1, row + 1), Vector2i(column, row + 1)]
			var polygon := PackedVector2Array()
			var corner_ids := PackedInt32Array()
			for corner in corners:
				if grid.has(corner):
					polygon.append(layout.nodes[grid[corner]])
					corner_ids.append(grid[corner])
			if polygon.size() != 4 or triangulate(polygon).size() != 6:
				continue
			var contained: bool = true
			if not convex:
				for corner in range(4):
					if not Geography.segment_on_land(outline, polygon[corner], polygon[(corner + 1) % 4]):
						contained = false
			if not contained:
				continue
			var stage: int = _phase(maxi(absi(row - half_row), absi(row + 1 - half_row)), maximum_distance)
			var block_seed: int = rng.randi()
			if diagonals.has(Vector2i(column, row)):
				var diagonal: int = 1 if diagonals[Vector2i(column, row)] else 0
				var first: int = corner_ids[diagonal]
				var last: int = corner_ids[diagonal + 2]
				if Geography.segment_on_land(polygon, layout.nodes[first], layout.nodes[last]):
					_append_edge(layout, first, last, Roads.LOCAL, stage)
					_append_block(layout, PackedInt32Array([first, corner_ids[diagonal + 1], last]), stage, block_seed, false)
					_append_block(layout, PackedInt32Array([first, last, corner_ids[(diagonal + 3) % 4]]), stage, rng.randi(), false)
					continue
			_append_block(layout, corner_ids, stage, block_seed, rng.randf() < 0.07)
	var boundary_corners := PackedInt32Array()
	if not boundary_routes.is_empty():
		for address in [Vector2i.ZERO, Vector2i(columns, 0), Vector2i(columns, rows), Vector2i(0, rows)]:
			if grid.has(address):
				boundary_corners.append(grid[address])
	_build_core_paths(layout, boundary_corners)
	if layout.arterial_nodes.is_empty() or layout.core_paths.is_empty():
		layout.polygon = PackedVector2Array()
	return layout


static func _fractions(count: int, rng: RandomNumberGenerator, varied: bool) -> PackedFloat32Array:
	var weights := PackedFloat32Array()
	var total := 0.0
	for index in range(count):
		var weight: float = rng.randf_range(0.6, 1.65) if varied else 1.0
		weights.append(weight)
		total += weight
	var result := PackedFloat32Array([0.0])
	var distance := 0.0
	for weight in weights:
		distance += weight
		result.append(distance / total)
	result[-1] = 1.0
	return result


static func _profile(values: PackedFloat32Array, fraction: float) -> float:
	var position: float = clampf(fraction, 0.0, 1.0) * float(values.size() - 1)
	var index: int = mini(floori(position), values.size() - 2)
	return lerpf(values[index], values[index + 1], position - index)


static func _route_length(route: PackedVector2Array) -> float:
	var length := 0.0
	for segment in range(1, route.size()):
		length += route[segment - 1].distance_to(route[segment])
	return length


static func _boundary_fractions(fractions: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array([0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0])
	for fraction in fractions:
		var nearby := false
		for anchor in result:
			if absf(fraction - anchor) < 0.035:
				nearby = true
				break
		if not nearby:
			result.append(fraction)
	result.sort()
	return result


static func _boundary_sample(route: PackedVector2Array, fraction: float) -> Vector2:
	var position: float = clampf(fraction, 0.0, 1.0) * float(route.size() - 1)
	var index: int = mini(floori(position), route.size() - 2)
	return route[index].lerp(route[index + 1], position - index)


static func _boundary_point(boundaries: Array, across: float, inward: float) -> Vector2:
	var bottom: Vector2 = _boundary_sample(boundaries[0], across)
	var right: Vector2 = _boundary_sample(boundaries[1], inward)
	var top: Vector2 = _boundary_sample(boundaries[2], across)
	var left: Vector2 = _boundary_sample(boundaries[3], inward)
	if inward == 0.0:
		return bottom
	if inward == 1.0:
		return top
	if across == 0.0:
		return left
	if across == 1.0:
		return right
	var origin: Vector2 = boundaries[0][0]
	var bottom_corner: Vector2 = (boundaries[0][0] - origin).lerp(boundaries[0][-1] - origin, across)
	var top_corner: Vector2 = (boundaries[2][0] - origin).lerp(boundaries[2][-1] - origin, across)
	return origin + (bottom - origin).lerp(top - origin, inward) + (left - origin).lerp(right - origin, across) - bottom_corner.lerp(top_corner, inward)


static func triangulate(polygon: PackedVector2Array) -> PackedInt32Array:
	var local := PackedVector2Array()
	for point in polygon:
		local.append(point - polygon[0])
	return Geometry2D.triangulate_polygon(local)


static func _append_edge(layout, first: int, last: int, road_class: String, phase: int) -> void:
	layout.edges.append(Vector2(first, last))
	layout.classes.append(road_class)
	layout.phases.append(phase)
	var length: float = layout.nodes[first].distance_to(layout.nodes[last])
	layout.lengths.append(length)
	if road_class != Roads.ARTERIAL:
		layout.phase_costs[phase - 1] += roundi(length * Roads.construction_cost(road_class))
		layout.phase_upkeep[phase - 1] += length * Roads.upkeep(road_class)


static func _append_block(layout, nodes: PackedInt32Array, phase: int, seed_value: int, park: bool) -> void:
	var polygon := PackedVector2Array()
	for node_id in nodes:
		polygon.append(layout.nodes[node_id])
	layout.blocks.append({"polygon": polygon, "nodes": nodes, "phase": phase, "seed": seed_value, "park": park, "area_ha": Geography.polygon_area(polygon) * 100.0})


static func _phase(distance: int, maximum_distance: int = 6) -> int:
	return clampi(ceili(float(distance) * 3.0 / float(maximum_distance)), 1, 3)


static func _clean_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	var result := polygon.duplicate()
	var cursor := 0
	while cursor < result.size() and result.size() > 3:
		var first: Vector2 = result[posmod(cursor - 1, result.size())]
		var middle: Vector2 = result[cursor]
		var last: Vector2 = result[(cursor + 1) % result.size()]
		if middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, first, last)) < 0.0002:
			result.remove_at(cursor)
			cursor = maxi(0, cursor - 1)
		else:
			cursor += 1
	return result


static func _build_core_paths(layout, boundary_corners: PackedInt32Array = PackedInt32Array()) -> void:
	var neighbors: Dictionary = {}
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] != Roads.COLLECTOR:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		for node_id in [int(edge.x), int(edge.y)]:
			if not neighbors.has(node_id):
				neighbors[node_id] = []
			neighbors[node_id].append(edge_id)
	var visited: Dictionary = {}
	for node_id in neighbors:
		var phase_boundary: bool = neighbors[node_id].size() == 2 and layout.phases[neighbors[node_id][0]] != layout.phases[neighbors[node_id][1]]
		if neighbors[node_id].size() == 2 and not layout.arterial_nodes.has(node_id) and not boundary_corners.has(node_id) and not phase_boundary:
			continue
		for first_edge in neighbors[node_id]:
			if visited.has(first_edge):
				continue
			var points := PackedVector2Array([layout.nodes[node_id]])
			var edges := PackedInt32Array()
			var cursor: int = node_id
			var edge_id: int = first_edge
			var stage := 1
			while not visited.has(edge_id):
				visited[edge_id] = true
				edges.append(edge_id)
				stage = maxi(stage, layout.phases[edge_id])
				var edge: Vector2 = layout.edges[edge_id]
				cursor = int(edge.y) if int(edge.x) == cursor else int(edge.x)
				points.append(layout.nodes[cursor])
				phase_boundary = neighbors[cursor].size() == 2 and layout.phases[neighbors[cursor][0]] != layout.phases[neighbors[cursor][1]]
				if neighbors[cursor].size() != 2 or layout.arterial_nodes.has(cursor) or boundary_corners.has(cursor) or phase_boundary:
					break
				edge_id = neighbors[cursor][0] if neighbors[cursor][1] == edge_id else neighbors[cursor][1]
			layout.core_paths.append({"from": node_id, "to": cursor, "points": points, "edges": edges, "phase": stage})


static func _along(route: PackedVector2Array, distance: float) -> Vector2:
	for segment in range(1, route.size()):
		var length: float = route[segment - 1].distance_to(route[segment])
		if distance <= length:
			return route[segment - 1].lerp(route[segment], distance / maxf(0.00001, length))
		distance -= length
	return route[-1]


static func frontage(route: PackedVector2Array, start: float, finish: float) -> PackedVector2Array:
	var result := PackedVector2Array([_along(route, start)])
	var traveled := 0.0
	for segment in range(1, route.size()):
		traveled += route[segment - 1].distance_to(route[segment])
		if traveled > start and traveled < finish:
			result.append(route[segment])
	result.append(_along(route, finish))
	return result


static func buildings(block: Dictionary, zone: String, density: int) -> Array:
	var result: Array = []
	if block["park"]:
		return result
	var polygon: PackedVector2Array = block["polygon"]
	var plots: Array = Geometry2D.offset_polygon(polygon, -0.008)
	if plots.size() != 1 or plots[0].size() < 3:
		return result
	var plot: PackedVector2Array = plots[0]
	var axis: Vector2 = polygon[1] - polygon[0]
	for index in range(1, polygon.size()):
		var side: Vector2 = polygon[(index + 1) % polygon.size()] - polygon[index]
		if side.length_squared() > axis.length_squared():
			axis = side
	axis = axis.normalized()
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = polygon[0]
	var bounds := Rect2(Vector2.ZERO, Vector2.ZERO)
	for point in plot:
		var offset: Vector2 = point - origin
		bounds = bounds.expand(Vector2(offset.dot(axis), offset.dot(normal)))
	var spacing: float = 0.038 if zone == "Residential" and density == 0 else 0.055
	var columns: int = clampi(roundi(bounds.size.x / spacing), 1, 6)
	var rows: int = clampi(roundi(bounds.size.y / spacing), 1, 6)
	if zone == "Industry":
		columns = 1
		rows = 1
	var rng := RandomNumberGenerator.new()
	rng.seed = block["seed"]
	for row in range(rows):
		for column in range(columns):
			var margin: float = 0.10 if density >= 1 else 0.28
			var first: Vector2 = bounds.position + bounds.size * Vector2((column + margin) / columns, (row + margin) / rows)
			var last: Vector2 = bounds.position + bounds.size * Vector2((column + 1.0 - margin - rng.randf_range(0.0, 0.10)) / columns, (row + 1.0 - margin - rng.randf_range(0.0, 0.10)) / rows)
			var footprint := PackedVector2Array([
				origin + axis * first.x + normal * first.y,
				origin + axis * last.x + normal * first.y,
				origin + axis * last.x + normal * last.y,
				origin + axis * first.x + normal * last.y,
			])
			var pieces: Array = Geometry2D.intersect_polygons(footprint, plot)
			if pieces.size() == 1 and pieces[0].size() >= 3 and Geography.polygon_area(pieces[0]) >= 0.000012:
				result.append(pieces[0])
	return result


static func update_buildings(neighborhood) -> void:
	if neighborhood.street_layout == null or not neighborhood.development_approved:
		return
	var plan = neighborhood.development_plan
	var demand: float = maxf(plan.design_demand, float(plan.target_housing) * 2.0 + plan.target_jobs)
	neighborhood.built_fraction = maxf(neighborhood.built_fraction, minf(1.0, (float(neighborhood.households) * 2.0 + neighborhood.jobs) / maxf(1.0, demand)))
	var blocks: Array = neighborhood.street_layout.blocks
	neighborhood.block_zoning.resize(blocks.size())
	for block_id in range(blocks.size()):
		var block: Dictionary = blocks[block_id]
		if block["phase"] > plan.completed_phase or neighborhood.block_zoning[block_id] != 0 or float(posmod(block["seed"], 1000)) / 1000.0 > neighborhood.built_fraction:
			continue
		var chosen: int = posmod(block["seed"], 100)
		var zone_id := 0
		for zone in ["Residential", "Commercial", "Office", "Mixed", "Industry"]:
			chosen -= int(neighborhood.zone_shares[zone])
			if chosen < 0:
				neighborhood.block_zoning[block_id] = zone_id * 3 + int(neighborhood.zone_density[zone]) + 1
				break
			zone_id += 1
