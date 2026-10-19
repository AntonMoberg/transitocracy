extends RefCounted

const Layout = preload("res://scripts/simulation/street_layout.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const SPACING_KM = 0.12
const FRONTAGE_KM = 1.2
const DEPTH_KM = 0.72
const COLLECTOR_SPACING_KM = 0.38


static func generate(region, city_id: int, route: PackedVector2Array, key: String, exclusions: Array = [], edge_frontage: bool = false, boundary_routes: Array = [], arterial_sides: PackedByteArray = PackedByteArray(), interior_style: String = "Grid", fixed_outline: PackedVector2Array = PackedVector2Array(), grid_guide: Dictionary = {}):
	var layout = Layout.new()
	layout.key = key
	layout.city_id = city_id
	layout.interior_style = interior_style
	if route.size() < 2:
		return layout
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%s" % [region.generation_seed, key])
	var organic: bool = interior_style == "Organic"
	var length: float = _route_length(route)
	var frontage_start_km := 0.0
	var frontage_end_km: float = length
	var pattern_key: String = "starter-city:%d" % city_id if key.begins_with("starter:") else key
	var pattern := RandomNumberGenerator.new()
	pattern.seed = hash("%d:block-pattern:%s" % [region.generation_seed, pattern_key])
	var long_spacing: float = [0.16, 0.18, 0.20, 0.22][pattern.randi_range(0, 3)]
	var short_spacing: float = [0.08, 0.09, 0.10][pattern.randi_range(0, 2)]
	var long_along: bool = pattern.randf() < 0.8
	var column_spacing: float = long_spacing if long_along else short_spacing
	var row_spacing: float = short_spacing if long_along else long_spacing
	var axis: Vector2 = (route[-1] - route[0]).normalized()
	if axis == Vector2.ZERO:
		axis = Vector2.RIGHT
	if edge_frontage and boundary_routes.is_empty() and not fixed_outline.is_empty() and _route_is_straight(route):
		var before := 0.0
		var after := 0.0
		for vertex in fixed_outline:
			var projection: float = (vertex - route[0]).dot(axis)
			before = maxf(before, -projection + 0.02)
			after = maxf(after, projection - length + 0.02)
		if before > 0.05 or after > 0.05:
			var extended := PackedVector2Array()
			if before > 0.05:
				extended.append(route[0] - axis * before)
			extended.append_array(route)
			if after > 0.05:
				extended.append(route[-1] + axis * after)
			route = extended
			frontage_start_km = before if before > 0.05 else 0.0
			frontage_end_km = frontage_start_km + length
			length = _route_length(route)
	if not grid_guide.is_empty() and interior_style == "Grid":
		var guide_axis: Vector2 = grid_guide.get("axis", Vector2.ZERO)
		var alignment: float = absf(axis.dot(guide_axis))
		if alignment >= 0.94:
			column_spacing = float(grid_guide.get("column_spacing", column_spacing))
			row_spacing = float(grid_guide.get("row_spacing", row_spacing))
		elif alignment <= 0.34:
			column_spacing = float(grid_guide.get("row_spacing", column_spacing))
			row_spacing = float(grid_guide.get("column_spacing", row_spacing))
	var columns: int = maxi(4, roundi(length / column_spacing))
	var rows: int = maxi(6, roundi(DEPTH_KM * 2.0 / row_spacing))
	var frontage_depth_km: float = DEPTH_KM * 2.0
	if edge_frontage and boundary_routes.is_empty() and arterial_sides == PackedByteArray([1, 0, 0, 0]) and not fixed_outline.is_empty():
		# A small fused fringe can extend past the usual frontage depth.
		# Give its grid enough rows to reach the added land.
		for vertex in fixed_outline:
			var nearest := INF
			for segment in range(1, route.size()):
				nearest = minf(nearest, vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, route[segment - 1], route[segment])))
			frontage_depth_km = maxf(frontage_depth_km, nearest)
		rows = maxi(rows, ceili(frontage_depth_km / row_spacing))
	if not edge_frontage and rows % 2 != 0:
		rows += 1
	var half_row: int = 0 if edge_frontage else rows / 2
	var maximum_distance: int = rows if edge_frontage else rows / 2
	var available_sides: PackedByteArray = PackedByteArray([1, 1, 1, 1]) if arterial_sides.is_empty() else arterial_sides
	var column_fractions: PackedFloat32Array = _fractions(columns, rng, false)
	var row_fractions: PackedFloat32Array = _fractions(rows, rng, false)
	var aligned_to_guide := false
	if edge_frontage and boundary_routes.is_empty() and not grid_guide.is_empty() and not organic and _route_is_straight(route):
		aligned_to_guide = true
		var guide_origin: Vector2 = grid_guide.get("origin", route[0])
		column_fractions = _aligned_fractions(route[0].dot(axis), guide_origin.dot(axis), length, column_spacing)
		row_fractions = _aligned_fractions(route[0].dot(axis.orthogonal()), guide_origin.dot(axis.orthogonal()), frontage_depth_km, row_spacing)
		columns = column_fractions.size() - 1
		rows = row_fractions.size() - 1
		maximum_distance = rows
	if not edge_frontage:
		row_fractions = _fractions(rows / 2, rng, false)
		for index in range(row_fractions.size()):
			row_fractions[index] *= 0.5
		var upper_rows: PackedFloat32Array = _fractions(rows / 2, rng, false)
		for index in range(1, upper_rows.size()):
			row_fractions.append(0.5 + upper_rows[index] * 0.5)
	if not boundary_routes.is_empty():
		columns = maxi(6, roundi(float(roundi(FRONTAGE_KM / column_spacing)) / 3.0) * 3)
		rows = maxi(6, roundi(float(roundi(DEPTH_KM * 2.0 / row_spacing)) / 2.0) * 2)
		column_fractions = _fractions(columns, rng, false)
		row_fractions = _fractions(rows, rng, false)
		columns = column_fractions.size() - 1
		rows = row_fractions.size() - 1
		maximum_distance = rows
	layout.grid_axis = axis
	layout.grid_origin = route[0]
	layout.grid_column_spacing_km = column_spacing if aligned_to_guide else length / float(columns)
	layout.grid_row_spacing_km = row_spacing if aligned_to_guide else frontage_depth_km / float(rows)
	var upper_depths := PackedFloat32Array([1, 1, 1, 1])
	var lower_depths := PackedFloat32Array([1, 1, 1, 1])
	if not edge_frontage:
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
		if edge_frontage:
			outline = frontage_outline(route)
		else:
			for column in range(columns + 1):
				outline.append(samples[column] + normals[column] * DEPTH_KM * _profile(upper_depths, column_fractions[column]))
			for column in range(columns, -1, -1):
				outline.append(samples[column] - normals[column] * DEPTH_KM * _profile(lower_depths, column_fractions[column]))
	if not fixed_outline.is_empty():
		outline = fixed_outline.duplicate()
	else:
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
	var minimum_area := 0.16 if edge_frontage and boundary_routes.is_empty() and available_sides == PackedByteArray([1, 0, 0, 0]) and not fixed_outline.is_empty() else 0.4
	if outline.size() < 3 or Geography.polygon_area(outline) < minimum_area or triangulate(outline).is_empty():
		return layout
	layout.polygon = outline
	layout.bounds = Geography._bounds(outline)
	var convex: bool = absf(Geography.polygon_area(Geometry2D.convex_hull(outline)) - Geography.polygon_area(outline)) < 0.000001
	var grid: Dictionary = {}
	var grid_positions: Dictionary = {}
	var bend: float = rng.randf_range(0.008, 0.018) if organic else 0.0
	var phase: float = rng.randf_range(0.0, TAU)
	for row in range(rows + 1):
		for column in range(columns + 1):
			var across: float = column_fractions[column]
			var inward: float = row_fractions[row]
			var position: Vector2
			if not boundary_routes.is_empty():
				position = _boundary_point(boundary_routes, across, inward)
			else:
				var lateral: float = inward * frontage_depth_km
				if not edge_frontage:
					lateral = (inward * 2.0 - 1.0) * DEPTH_KM * _profile(lower_depths if row < half_row else upper_depths, across)
				position = samples[column] + normals[column] * lateral
			if row > 0 and row < rows and row != half_row and column > 0 and column < columns:
				var fade: float = sin(across * PI) * sin(PI * (inward if edge_frontage else absf(inward * 2.0 - 1.0)))
				position += normals[column] * sin(across * TAU + phase) * bend * fade
				position += normals[column].orthogonal() * sin(inward * TAU + phase) * bend * fade * 0.5
			grid_positions[Vector2i(column, row)] = position
			if not Jurisdiction.polygon_contains_point(position, outline):
				continue
			grid[Vector2i(column, row)] = layout.nodes.size()
			layout.nodes.append(position)
			var on_frontage: bool = length * column_fractions[column] >= frontage_start_km - 0.01 and length * column_fractions[column] <= frontage_end_km + 0.01
			var arterial: bool = row == half_row if not edge_frontage else ((row == 0 and on_frontage and available_sides[0] != 0) or (column == columns and available_sides[1] != 0) or (row == rows and available_sides[2] != 0) or (column == 0 and available_sides[3] != 0))
			if arterial:
				layout.arterial_nodes.append(layout.nodes.size() - 1)
	var open_frontage: bool = edge_frontage and boundary_routes.is_empty() and available_sides == PackedByteArray([1, 0, 0, 0])
	var collector_row: int = clampi(roundi(0.34 / maxf(0.01, frontage_depth_km / float(rows))), 2, rows - 1)
	var collector_columns: Dictionary = {}
	if open_frontage:
		collector_columns = _frontage_collector_columns(layout, grid, columns, rows, convex, outline)
	elif not boundary_routes.is_empty():
		# Two widely spaced through collectors serve the bounded districts. The
		# remaining parallel streets are local, so the grid has a clear hierarchy.
		for column in range(1, columns):
			if absf(column_fractions[column] - 1.0 / 3.0) < 0.0001 or absf(column_fractions[column] - 2.0 / 3.0) < 0.0001:
				collector_columns[column] = true
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
					var on_arterial: bool = available_sides[side] != 0 and (side != 0 or (length * column_fractions[column] >= frontage_start_km - 0.01 and length * column_fractions[column + 1] <= frontage_end_km + 0.01))
					road_class = Roads.ARTERIAL if on_arterial else (Roads.LOCAL if open_frontage else Roads.COLLECTOR)
				elif not edge_frontage and step == Vector2i.RIGHT and row == half_row:
					road_class = Roads.ARTERIAL
				elif open_frontage:
					if step == Vector2i.DOWN and collector_columns.has(column):
						road_class = Roads.COLLECTOR
					elif step == Vector2i.RIGHT and row == collector_row:
						road_class = Roads.COLLECTOR
				elif not boundary_routes.is_empty():
					if (step == Vector2i.RIGHT and absf(row_fractions[row] - 0.5) < 0.0001) or (step == Vector2i.DOWN and collector_columns.has(column)):
						road_class = Roads.COLLECTOR
				elif (step == Vector2i.RIGHT and absi(row - half_row) == 3) or (step == Vector2i.DOWN and (column % 4 == 0 or column == columns)):
					road_class = Roads.COLLECTOR
				var stage: int = _phase(maxi(absi(row - half_row), absi(next.y - half_row)), maximum_distance)
				if road_class == Roads.COLLECTOR and step == Vector2i.DOWN:
					stage = 1
				_append_edge(layout, first, second, road_class, stage)
	if open_frontage:
		_extend_streets_to_boundary(layout, grid, grid_positions, collector_columns, columns, rows, outline, collector_row, maximum_distance)
	var diagonals: Dictionary = {}
	for row in range(rows):
		for column in range(columns):
			var corners: Array[Vector2i] = [Vector2i(column, row), Vector2i(column + 1, row), Vector2i(column + 1, row + 1), Vector2i(column, row + 1)]
			var polygon := PackedVector2Array()
			var corner_ids := PackedInt32Array()
			for corner in corners:
				if grid.has(corner):
					polygon.append(layout.nodes[grid[corner]])
					corner_ids.append(grid[corner])
			var stage: int = _phase(maxi(absi(row - half_row), absi(row + 1 - half_row)), maximum_distance)
			var block_seed: int = rng.randi()
			var contained: bool = polygon.size() == 4 and triangulate(polygon).size() == 6
			if contained and not convex:
				for corner in range(4):
					if not Geography.segment_on_land(outline, polygon[corner], polygon[(corner + 1) % 4]):
						contained = false
			if not contained:
				var cell := PackedVector2Array()
				for corner in corners:
					cell.append(grid_positions[corner])
				if triangulate(cell).is_empty():
					continue
				for piece in Geometry2D.intersect_polygons(cell, outline):
					if piece.size() < 3 or Geography.polygon_area(piece) < 0.0005 or triangulate(piece).is_empty():
						continue
					var center := Vector2.ZERO
					for point in piece:
						center += point
					center /= float(piece.size())
					var access_id := -1
					var nearest := 0.35 * 0.35
					for corner in corners:
						if not grid.has(corner):
							continue
						var candidate_id: int = grid[corner]
						var distance: float = layout.nodes[candidate_id].distance_squared_to(center)
						if distance < nearest:
							access_id = candidate_id
							nearest = distance
					if access_id < 0:
						# A thin panhandle may cut through cells whose four corners
						# all fall outside the outline. Attach that fringe to a nearby
						# interior street instead of leaving the land blank.
						nearest = 0.5 * 0.5
						for candidate_id in range(layout.nodes.size()):
							if layout.arterial_nodes.has(candidate_id):
								continue
							var distance: float = layout.nodes[candidate_id].distance_squared_to(center)
							if distance < nearest and Geography.segment_on_land(outline, layout.nodes[candidate_id], center):
								access_id = candidate_id
								nearest = distance
					if access_id >= 0:
						_append_block_polygon(layout, piece, PackedInt32Array([access_id]), stage, block_seed, false, true)
				continue
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
	if open_frontage:
		_ensure_frontage_collector(layout)
	_build_core_paths(layout, boundary_corners)
	var has_frontage_access := not open_frontage
	if open_frontage:
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.COLLECTOR:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			if layout.arterial_nodes.has(int(edge.x)) != layout.arterial_nodes.has(int(edge.y)):
				has_frontage_access = true
				break
	if layout.arterial_nodes.is_empty() or layout.core_paths.is_empty() or not has_frontage_access:
		layout.polygon = PackedVector2Array()
	return layout


static func _ensure_frontage_collector(layout) -> void:
	var fallback := -1
	for edge_id in range(layout.edges.size()):
		var edge: Vector2 = layout.edges[edge_id]
		if layout.arterial_nodes.has(int(edge.x)) == layout.arterial_nodes.has(int(edge.y)):
			continue
		if layout.classes[edge_id] == Roads.COLLECTOR:
			return
		if layout.classes[edge_id] == Roads.LOCAL and fallback < 0:
			fallback = edge_id
	if fallback < 0:
		return
	var old_phase: int = layout.phases[fallback]
	var length: float = layout.lengths[fallback]
	layout.phase_costs[old_phase - 1] -= roundi(length * Roads.construction_cost(Roads.LOCAL))
	layout.phase_upkeep[old_phase - 1] -= length * Roads.upkeep(Roads.LOCAL)
	layout.classes[fallback] = Roads.COLLECTOR
	layout.phases[fallback] = 1
	layout.phase_costs[0] += roundi(length * Roads.construction_cost(Roads.COLLECTOR))
	layout.phase_upkeep[0] += length * Roads.upkeep(Roads.COLLECTOR)


static func _frontage_collector_columns(layout, grid: Dictionary, columns: int, rows: int, convex: bool, outline: PackedVector2Array) -> Dictionary:
	var choices: Array[Dictionary] = []
	for column in range(1, columns):
		if not grid.has(Vector2i(column, 0)) or not layout.arterial_nodes.has(grid[Vector2i(column, 0)]):
			continue
		var depth := 0
		for row in range(1, rows + 1):
			if not grid.has(Vector2i(column, row)):
				break
			if not convex and not Geography.segment_on_land(outline, layout.nodes[grid[Vector2i(column, row - 1)]], layout.nodes[grid[Vector2i(column, row)]]):
				break
			depth = row
		if depth >= 3:
			choices.append({"column": column, "depth": depth, "point": layout.nodes[grid[Vector2i(column, 0)]]})
	var selected: Dictionary = {}
	if choices.is_empty():
		return selected
	var first_column: int = choices[0]["column"]
	var last_column: int = choices[-1]["column"]
	var frontage_span: float = choices[0]["point"].distance_to(choices[-1]["point"])
	var targets: Array = [0.5] if frontage_span < 0.95 else [0.33, 0.67]
	for fraction in targets:
		var best: Dictionary = {}
		var best_score := -INF
		for choice in choices:
			if selected.has(choice["column"]):
				continue
			var spaced := true
			for other_column in selected:
				if choice["point"].distance_to(layout.nodes[grid[Vector2i(other_column, 0)]]) < COLLECTOR_SPACING_KM:
					spaced = false
			if not spaced:
				continue
			var position: float = float(int(choice["column"]) - first_column) / float(maxi(1, last_column - first_column))
			var score: float = float(choice["depth"]) * 0.025 - absf(position - fraction)
			if score > best_score:
				best_score = score
				best = choice
		if not best.is_empty():
			selected[int(best["column"])] = true
	return selected


static func _extend_streets_to_boundary(layout, grid: Dictionary, positions: Dictionary, collector_columns: Dictionary, columns: int, rows: int, outline: PackedVector2Array, collector_row: int, maximum_distance: int) -> void:
	for row in range(rows + 1):
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			if row == 0 or not grid.has(address):
				continue
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				# Only continue a street that already reaches this interior node.
				if not grid.has(address - step):
					continue
				var next: Vector2i = address + step
				if grid.has(next) or not positions.has(next):
					continue
				var first: Vector2 = layout.nodes[grid[address]]
				var target: Vector2 = positions[next]
				var boundary: Vector2 = _first_boundary_crossing(first, target, outline)
				if not is_finite(boundary.x) or first.distance_to(boundary) < 0.01:
					continue
				var boundary_id: int = layout.nodes.size()
				layout.nodes.append(boundary)
				var collector: bool = (step.x != 0 and row == collector_row) or (step.y != 0 and collector_columns.has(column))
				var stage: int = 1 if collector else _phase(row, maximum_distance)
				_append_edge(layout, grid[address], boundary_id, Roads.COLLECTOR if collector else Roads.LOCAL, stage)


static func _first_boundary_crossing(first: Vector2, last: Vector2, outline: PackedVector2Array) -> Vector2:
	var nearest := Vector2(INF, INF)
	var distance := INF
	for index in range(outline.size()):
		var hit = Geometry2D.segment_intersects_segment(first, last, outline[index], outline[(index + 1) % outline.size()])
		if hit == null:
			continue
		var along: float = first.distance_to(hit)
		if along > 0.002 and along < distance:
			distance = along
			nearest = hit
	return nearest


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


static func _aligned_fractions(start_projection: float, origin_projection: float, length: float, spacing: float) -> PackedFloat32Array:
	var result := PackedFloat32Array([0.0])
	var first_line: int = ceili((start_projection - origin_projection) / spacing)
	for line in range(first_line, first_line + ceili(length / spacing) + 2):
		var distance: float = origin_projection + float(line) * spacing - start_projection
		if distance >= length - maxf(0.04, spacing * 0.3):
			break
		if distance <= maxf(0.04, spacing * 0.3):
			continue
		result.append(distance / length)
	result.append(1.0)
	return result


static func _route_is_straight(route: PackedVector2Array) -> bool:
	if route.size() < 2:
		return false
	for index in range(1, route.size() - 1):
		if route[index].distance_to(Geometry2D.get_closest_point_to_segment(route[index], route[0], route[-1])) > 0.015:
			return false
	return true


static func _profile(values: PackedFloat32Array, fraction: float) -> float:
	var position: float = clampf(fraction, 0.0, 1.0) * float(values.size() - 1)
	var index: int = mini(floori(position), values.size() - 2)
	return lerpf(values[index], values[index + 1], position - index)


static func _route_length(route: PackedVector2Array) -> float:
	var length := 0.0
	for segment in range(1, route.size()):
		length += route[segment - 1].distance_to(route[segment])
	return length


static func frontage_outline(route: PackedVector2Array) -> PackedVector2Array:
	if route.size() < 2:
		return PackedVector2Array()
	var length: float = _route_length(route)
	var columns: int = maxi(4, roundi(length / SPACING_KM))
	var outline := PackedVector2Array()
	for column in range(columns + 1):
		var distance: float = length * float(column) / float(columns)
		var tangent: Vector2 = (_along(route, minf(length, distance + 0.02)) - _along(route, maxf(0.0, distance - 0.02))).normalized()
		outline.append(_along(route, distance) + Vector2(-tangent.y, tangent.x) * DEPTH_KM * 2.0)
	for index in range(route.size() - 1, -1, -1):
		outline.append(route[index])
	return outline


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
	_append_block_polygon(layout, polygon, nodes, phase, seed_value, park, false)


static func _append_block_polygon(layout, polygon: PackedVector2Array, nodes: PackedInt32Array, phase: int, seed_value: int, park: bool, fringe: bool) -> void:
	layout.blocks.append({"polygon": polygon, "nodes": nodes, "phase": phase, "seed": seed_value, "park": park, "fringe": fringe, "area_ha": Geography.polygon_area(polygon) * 100.0})


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


static func buildings(block: Dictionary, zone: String, density: int, character: String = Character.FINE_GRAIN) -> Array:
	var result: Array = []
	for parcel in parcels(block, zone, density, character):
		result.append_array(parcel["buildings"])
	return result


static func parcels(block: Dictionary, zone: String, density: int, character: String = Character.FINE_GRAIN) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if block["park"]:
		return result
	var polygon: PackedVector2Array = block["polygon"]
	if polygon.size() < 3:
		return result
	var axis: Vector2 = polygon[1] - polygon[0]
	for index in range(1, polygon.size()):
		var side: Vector2 = polygon[(index + 1) % polygon.size()] - polygon[index]
		if side.length_squared() > axis.length_squared():
			axis = side
	axis = axis.normalized()
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = polygon[0]
	var initial: Vector2 = Vector2.ZERO
	var bounds := Rect2(initial, Vector2.ZERO)
	for index in range(polygon.size()):
		var offset: Vector2 = polygon[index] - origin
		var local := Vector2(offset.dot(axis), offset.dot(normal))
		bounds = Rect2(local, Vector2.ZERO) if index == 0 else bounds.expand(local)
	var profile: String = Character.LARGE_PLOT if zone == "Industry" else character
	var columns: int = clampi(roundi(bounds.size.x / Character.frontage_km(profile)), 1, 16)
	var rows: int = 2 if polygon.size() >= 4 and bounds.size.y >= 0.085 and profile != Character.LARGE_PLOT else 1
	var margins: Vector3 = Character.margins_km(profile, density)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(block["seed"])
	for row in range(rows):
		for column in range(columns):
			var x0: float = bounds.position.x + bounds.size.x * float(column) / float(columns)
			var x1: float = bounds.position.x + bounds.size.x * float(column + 1) / float(columns)
			var y0: float = bounds.position.y + bounds.size.y * float(row) / float(rows)
			var y1: float = bounds.position.y + bounds.size.y * float(row + 1) / float(rows)
			var strip := PackedVector2Array([
				origin + axis * x0 + normal * y0,
				origin + axis * x1 + normal * y0,
				origin + axis * x1 + normal * y1,
				origin + axis * x0 + normal * y1,
			])
			var pieces: Array = Geometry2D.intersect_polygons(polygon, strip)
			var lot := PackedVector2Array()
			var best_area := 0.0
			for piece in pieces:
				var area: float = Geography.polygon_area(piece)
				if area > best_area:
					lot = piece
					best_area = area
			if best_area < 0.00005:
				continue
			var front: float = margins.x if row == 0 else margins.z
			var rear: float = margins.z if row == 0 else margins.x
			var side: float = margins.y
			var variation: float = rng.randf_range(0.0, minf(0.003, (x1 - x0) * 0.08))
			var build_x0: float = x0 + side
			var build_x1: float = x1 - side - variation
			var build_y0: float = y0 + front
			var build_y1: float = y1 - rear
			var footprints: Array[PackedVector2Array] = []
			if build_x1 - build_x0 >= 0.004 and build_y1 - build_y0 >= 0.005:
				var envelopes: Array[Rect2] = [Rect2(Vector2(build_x0, build_y0), Vector2(build_x1 - build_x0, build_y1 - build_y0))]
				if profile == Character.COURTYARD and build_x1 - build_x0 >= 0.023 and build_y1 - build_y0 >= 0.030:
					var court_width: float = (build_x1 - build_x0) * 0.34
					var court_height: float = (build_y1 - build_y0) * 0.38
					var court_x0: float = (build_x0 + build_x1 - court_width) * 0.5
					var court_x1: float = court_x0 + court_width
					var court_y0: float = (build_y0 + build_y1 - court_height) * 0.5
					var court_y1: float = court_y0 + court_height
					envelopes = [
						Rect2(Vector2(build_x0, build_y0), Vector2(build_x1 - build_x0, court_y0 - build_y0)),
						Rect2(Vector2(build_x0, court_y1), Vector2(build_x1 - build_x0, build_y1 - court_y1)),
						Rect2(Vector2(build_x0, court_y0), Vector2(court_x0 - build_x0, court_y1 - court_y0)),
						Rect2(Vector2(court_x1, court_y0), Vector2(build_x1 - court_x1, court_y1 - court_y0)),
					]
				for rect in envelopes:
					var envelope := PackedVector2Array([
						origin + axis * rect.position.x + normal * rect.position.y,
						origin + axis * rect.end.x + normal * rect.position.y,
						origin + axis * rect.end.x + normal * rect.end.y,
						origin + axis * rect.position.x + normal * rect.end.y,
					])
					for footprint in Geometry2D.intersect_polygons(lot, envelope):
						if footprint.size() >= 3 and Geography.polygon_area(footprint) >= 0.000012:
							footprints.append(footprint)
			result.append({"polygon": lot, "buildings": footprints})
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
		if block["phase"] > plan.completed_phase or block.get("demolished", false) or neighborhood.block_zoning[block_id] != 0 or float(posmod(block["seed"], 1000)) / 1000.0 > neighborhood.built_fraction:
			continue
		var chosen: int = posmod(block["seed"], 100)
		var zone_id := 0
		for zone in ["Residential", "Commercial", "Office", "Mixed", "Industry"]:
			chosen -= int(neighborhood.zone_shares[zone])
			if chosen < 0:
				neighborhood.block_zoning[block_id] = zone_id * 3 + int(neighborhood.zone_density[zone]) + 1
				break
			zone_id += 1
