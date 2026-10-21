extends RefCounted

const Layout = preload("res://scripts/simulation/street_layout.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const Streamlines = preload("res://scripts/simulation/street_streamline_tracer.gd")
const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")
const CityStreetPlan = preload("res://scripts/simulation/city_street_plan.gd")
const SPACING_KM = 0.12
const FRONTAGE_KM = 1.2
const DEPTH_KM = 0.72
const COLLECTOR_SPACING_KM = 0.38


static func generate(region, city_id: int, route: PackedVector2Array, key: String, exclusions: Array = [], edge_frontage: bool = false, boundary_routes: Array = [], arterial_sides: PackedByteArray = PackedByteArray(), interior_style: String = "Grid", fixed_outline: PackedVector2Array = PackedVector2Array(), grid_guide: Dictionary = {}):
	if edge_frontage and boundary_routes.is_empty() and fixed_outline.size() >= 3 and grid_guide.has("plan_key"):
		var city_layout = _generate_city_lattice(region, city_id, key, fixed_outline, interior_style, grid_guide)
		if city_layout.polygon.size() >= 3:
			return city_layout
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
	if edge_frontage and boundary_routes.is_empty() and key.get_slice_count(":") >= 5:
		pattern_key = "corridor:%d:%s:%s" % [city_id, key.get_slice(":", 1), key.get_slice(":", 4)]
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
	var through_depth_km: float = DEPTH_KM
	if not edge_frontage and not fixed_outline.is_empty():
		# Painted districts may span farther than the usual fixed-width
		# through corridor. Cover both sides of their complete outline.
		for vertex in fixed_outline:
			var nearest := INF
			for segment in range(1, route.size()):
				nearest = minf(nearest, vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, route[segment - 1], route[segment])))
			through_depth_km = maxf(through_depth_km, nearest + 0.02)
	var frontage_depth_km: float = through_depth_km * 2.0
	var rows: int = maxi(6, roundi(frontage_depth_km / row_spacing))
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
	var half_row: int = 0 if edge_frontage else floori(float(rows) / 2.0)
	var maximum_distance: int = rows if edge_frontage else floori(float(rows) / 2.0)
	var available_sides: PackedByteArray = PackedByteArray([1, 1, 1, 1]) if arterial_sides.is_empty() else arterial_sides
	var column_fractions: PackedFloat32Array = _fractions(columns, rng, organic)
	var row_fractions: PackedFloat32Array = _fractions(rows, rng, organic)
	var aligned_to_guide := false
	if boundary_routes.is_empty() and not grid_guide.is_empty() and grid_guide.get("axis", Vector2.ZERO) != Vector2.ZERO and not organic and _route_is_straight(route) and (absf(axis.dot(grid_guide.get("axis", Vector2.ZERO))) >= 0.94 or absf(axis.dot(grid_guide.get("axis", Vector2.ZERO))) <= 0.34):
		aligned_to_guide = true
		var guide_origin: Vector2 = grid_guide.get("origin", route[0])
		column_fractions = _aligned_fractions(route[0].dot(axis), guide_origin.dot(axis), length, column_spacing)
		columns = column_fractions.size() - 1
		var normal: Vector2 = axis.orthogonal()
		if edge_frontage:
			row_fractions = _aligned_fractions(route[0].dot(normal), guide_origin.dot(normal), frontage_depth_km, row_spacing)
			rows = row_fractions.size() - 1
			maximum_distance = rows
		else:
			var aligned_rows: PackedFloat32Array = _aligned_fractions((route[0] - normal * through_depth_km).dot(normal), guide_origin.dot(normal), through_depth_km * 2.0, row_spacing)
			row_fractions = PackedFloat32Array()
			for fraction in aligned_rows:
				if fraction < 0.499:
					row_fractions.append(fraction)
			half_row = row_fractions.size()
			row_fractions.append(0.5)
			for fraction in aligned_rows:
				if fraction > 0.501:
					row_fractions.append(fraction)
			rows = row_fractions.size() - 1
			maximum_distance = maxi(half_row, rows - half_row)
	if not edge_frontage:
		if not aligned_to_guide:
			row_fractions = _fractions(floori(float(rows) / 2.0), rng, organic)
			for index in range(row_fractions.size()):
				row_fractions[index] *= 0.5
			var upper_rows: PackedFloat32Array = _fractions(floori(float(rows) / 2.0), rng, organic)
			for index in range(1, upper_rows.size()):
				row_fractions.append(0.5 + upper_rows[index] * 0.5)
	if not boundary_routes.is_empty():
		columns = maxi(6, roundi(float(roundi(FRONTAGE_KM / column_spacing)) / 3.0) * 3)
		rows = maxi(6, roundi(float(roundi(DEPTH_KM * 2.0 / row_spacing)) / 2.0) * 2)
		column_fractions = _fractions(columns, rng, organic)
		row_fractions = _fractions(rows, rng, organic)
		columns = column_fractions.size() - 1
		rows = row_fractions.size() - 1
		maximum_distance = rows
	layout.grid_axis = axis
	layout.grid_origin = grid_guide.get("origin", route[0]) if aligned_to_guide else route[0]
	layout.grid_column_spacing_km = column_spacing if aligned_to_guide else length / float(columns)
	layout.grid_row_spacing_km = row_spacing if aligned_to_guide else frontage_depth_km / float(rows)
	var upper_depths := PackedFloat32Array([1, 1, 1, 1])
	var lower_depths := PackedFloat32Array([1, 1, 1, 1])
	if not edge_frontage and not aligned_to_guide:
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
				outline.append(samples[column] + normals[column] * through_depth_km * _profile(upper_depths, column_fractions[column]))
			for column in range(columns, -1, -1):
				outline.append(samples[column] - normals[column] * through_depth_km * _profile(lower_depths, column_fractions[column]))
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
	var field_guide: Vector2 = grid_guide.get("axis", Vector2.ZERO)
	if field_guide != Vector2.ZERO and absf(field_guide.dot(axis)) < 0.5:
		field_guide = field_guide.orthogonal()
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
					lateral = (inward * 2.0 - 1.0) * through_depth_km * _profile(lower_depths if row < half_row else upper_depths, across)
				position = samples[column] + normals[column] * lateral
			grid_positions[Vector2i(column, row)] = position
	var seed_positions: Dictionary = grid_positions
	var field_context: Dictionary = DirectionField.city_context(region, city_id, layout.bounds)
	grid_positions = Streamlines.trace_grid(grid_positions, columns, rows, region.generation_seed, city_id, field_guide, organic, region.cities[city_id]["center_km"], 0.11 if organic else 0.04, half_row if not edge_frontage else -1, field_context)
	var canonical_addresses: Dictionary = {}
	if aligned_to_guide and boundary_routes.is_empty() and not organic:
		var city_plan: Dictionary = CityStreetPlan.guide(region, city_id, layout.bounds.get_center())
		for address in seed_positions:
			var original: Vector2 = seed_positions[address]
			var city_address: Vector2i = CityStreetPlan.address(original, city_plan)
			if original.distance_to(CityStreetPlan.base_junction(city_plan, city_address)) <= 0.018:
				canonical_addresses[address] = city_address
				var boundary_distance: float = _point_outline_distance(original, outline)
				var weight: float = clampf((boundary_distance - 0.07) / 0.14, 0.0, 0.6)
				if weight > 0.0:
					grid_positions[address] = grid_positions[address].lerp(CityStreetPlan.junction(region, city_id, city_address, city_plan), weight)
	for address in grid_positions:
		var original: Vector2 = seed_positions[address]
		for segment in range(outline.size()):
			if original.distance_squared_to(Geometry2D.get_closest_point_to_segment(original, outline[segment], outline[(segment + 1) % outline.size()])) < 0.0004:
				grid_positions[address] = original
				break
	var ordinary_seam_targets: Array = []
	for target in grid_guide.get("seam_targets", []):
		if not target.get("arterial_crossing", false):
			ordinary_seam_targets.append(target)
	# Drawn outlines can cross a grid line between nodes. Ease those lines toward
	# the neighboring street; paired generated candidates already share a field.
	_snap_grid_seams(grid_positions, outline, ordinary_seam_targets, columns, rows, half_row, edge_frontage, key.begins_with("growth:"))
	if edge_frontage and boundary_routes.is_empty() and available_sides == PackedByteArray([1, 0, 0, 0]):
		_anchor_arterial_collectors(grid_positions, outline, grid_guide.get("seam_targets", []), columns, rows)
	var organic_paths: Dictionary = {}
	if organic:
		for row in range(rows + 1):
			for column in range(columns + 1):
				var address := Vector2i(column, row)
				for step in [Vector2i.RIGHT, Vector2i.DOWN]:
					var next: Vector2i = address + step
					if next.x > columns or next.y > rows:
						continue
					var path: PackedVector2Array = _organic_grid_path(region, city_id, grid_positions[address], grid_positions[next], field_guide, field_context, outline)
					if path.size() > 2:
						organic_paths[_grid_edge_key(address, next)] = path
	for row in range(rows + 1):
		for column in range(columns + 1):
			var position: Vector2 = grid_positions[Vector2i(column, row)]
			if not Jurisdiction.polygon_contains_point(position, outline):
				continue
			grid[Vector2i(column, row)] = layout.nodes.size()
			layout.nodes.append(position)
			if canonical_addresses.has(Vector2i(column, row)):
				var city_address: Vector2i = canonical_addresses[Vector2i(column, row)]
				layout.canonical_nodes[layout.nodes.size() - 1] = "%d:%d:%d" % [city_id, city_address.x, city_address.y]
			var on_frontage: bool = length * column_fractions[column] >= frontage_start_km - 0.01 and length * column_fractions[column] <= frontage_end_km + 0.01
			var arterial: bool = row == half_row if not edge_frontage else ((row == 0 and on_frontage and available_sides[0] != 0) or (column == columns and available_sides[1] != 0) or (row == rows and available_sides[2] != 0) or (column == 0 and available_sides[3] != 0))
			if arterial:
				layout.arterial_nodes.append(layout.nodes.size() - 1)
	var open_frontage: bool = edge_frontage and boundary_routes.is_empty() and available_sides == PackedByteArray([1, 0, 0, 0])
	var collector_row: int = clampi(roundi(0.34 / maxf(0.01, frontage_depth_km / float(rows))), 2, rows - 1)
	if open_frontage and aligned_to_guide:
		collector_row = _guided_collector_row(samples[floori(float(columns) / 2.0)], normals[floori(float(columns) / 2.0)], axis, row_fractions, frontage_depth_km, collector_row, grid_guide)
	var collector_columns: Dictionary = {}
	if open_frontage:
		collector_columns = _frontage_collector_columns(layout, grid, grid_positions, columns, rows, convex, outline, grid_guide)
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
				if road_class != Roads.ARTERIAL and (_near_field_arterial(layout.nodes[first], layout.nodes[second], field_context, 0.075) or _near_parallel_outline(layout.nodes[first], layout.nodes[second], outline, 0.065)):
					continue
				var stage: int = _phase(maxi(absi(row - half_row), absi(next.y - half_row)), maximum_distance)
				if road_class == Roads.COLLECTOR and step == Vector2i.DOWN:
					stage = 1
				var curved_key: Vector3i = _grid_edge_key(address, next)
				if organic_paths.has(curved_key):
					_append_path_edge(layout, first, second, road_class, stage, organic_paths[curved_key])
				else:
					_append_edge(layout, first, second, road_class, stage)
	if open_frontage or (not edge_frontage and boundary_routes.is_empty()):
		_extend_streets_to_boundary(layout, grid, grid_positions, collector_columns, columns, rows, outline, collector_row, maximum_distance, grid_guide, field_context, not edge_frontage)
	if boundary_routes.is_empty():
		_fill_clipped_grid_lines(region, layout, grid, grid_positions, columns, rows, outline, field_context, grid_guide.get("seam_targets", []))
		_build_boundary_roads(region, layout, outline, field_context)
	var diagonals: Dictionary = {}
	if not organic and columns >= 8 and rows >= 8 and posmod(hash("%d:diagonal:%s" % [region.generation_seed, layout.key]), 6) == 0:
		var first_column: int = maxi(2, floori(float(columns) / 3.0))
		var first_row: int = maxi(2, floori(float(rows) / 3.0))
		var diagonal_length: int = mini(3, mini(columns - first_column - 2, rows - first_row - 2))
		for offset in range(diagonal_length):
			var address := Vector2i(first_column + offset, first_row + offset)
			if not edge_frontage and address.y <= half_row and address.y + 1 >= half_row:
				continue
			var viable := true
			for corner in [address, address + Vector2i.RIGHT, address + Vector2i.ONE, address + Vector2i.DOWN]:
				if not grid.has(corner):
					viable = false
			if viable:
				diagonals[address] = false
	for row in range(rows):
		for column in range(columns):
			var corners: Array[Vector2i] = [Vector2i(column, row), Vector2i(column + 1, row), Vector2i(column + 1, row + 1), Vector2i(column, row + 1)]
			var polygon := PackedVector2Array()
			var curved_cell: PackedVector2Array = _organic_cell_polygon(corners, grid_positions, organic_paths) if organic else PackedVector2Array()
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
				var cell: PackedVector2Array = curved_cell
				if cell.is_empty():
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
			if curved_cell.size() >= 4 and not triangulate(curved_cell).is_empty():
				_append_block_polygon(layout, curved_cell, corner_ids, stage, block_seed, rng.randf() < 0.07, false)
			else:
				_append_block(layout, corner_ids, stage, block_seed, rng.randf() < 0.07)
			if canonical_addresses.has(Vector2i(column, row)) and layout.blocks.size() > 0:
				var block: Dictionary = layout.blocks[-1]
				block["canonical_id"] = CityStreetPlan.block_key(city_id, canonical_addresses[Vector2i(column, row)])
				layout.blocks[-1] = block
	if not grid_guide.get("seam_targets", []).is_empty():
		_connect_unmatched_seams(layout, grid_guide["seam_targets"], field_context)
	if organic:
		_organic_merge_local_blocks(layout, region.generation_seed)
	var boundary_corners := PackedInt32Array()
	if not boundary_routes.is_empty():
		for address in [Vector2i.ZERO, Vector2i(columns, 0), Vector2i(columns, rows), Vector2i(0, rows)]:
			if grid.has(address):
				boundary_corners.append(grid[address])
	if open_frontage:
		_ensure_frontage_collector(layout)
	if boundary_routes.is_empty():
		_service_pointed_fringe(layout)
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


# New districts consume a window of the city's street addresses. Candidate
# polygons choose which blocks are developed; they never choose a new origin
# or spacing for the roads inside them.
static func _generate_city_lattice(region, city_id: int, key: String, outline: PackedVector2Array, interior_style: String, grid_guide: Dictionary):
	var layout = Layout.new()
	layout.key = key
	layout.city_id = city_id
	layout.interior_style = interior_style
	var organic: bool = interior_style == "Organic"
	outline = _clean_polygon(outline)
	if outline.size() < 3 or Geography.polygon_area(outline) < 0.16 or triangulate(outline).is_empty():
		return layout
	layout.polygon = outline
	layout.bounds = Geography._bounds(outline)
	var plan: Dictionary = CityStreetPlan.guide(region, city_id, layout.bounds.get_center())
	layout.grid_axis = plan["axis"]
	layout.grid_origin = plan["origin"]
	layout.grid_column_spacing_km = float(plan["column_spacing"])
	layout.grid_row_spacing_km = float(plan["row_spacing"])
	var low := Vector2i(2147483647, 2147483647)
	var high := Vector2i(-2147483647, -2147483647)
	for vertex in outline:
		var address: Vector2i = CityStreetPlan.address(vertex, plan)
		low.x = mini(low.x, address.x - 2)
		low.y = mini(low.y, address.y - 2)
		high.x = maxi(high.x, address.x + 2)
		high.y = maxi(high.y, address.y + 2)
	var columns: int = high.x - low.x
	var rows: int = high.y - low.y
	if columns < 2 or rows < 2 or columns * rows > 1200:
		layout.polygon = PackedVector2Array()
		return layout
	var positions: Dictionary = {}
	var grid: Dictionary = {}
	for row in range(rows + 1):
		for column in range(columns + 1):
			var address := Vector2i(low.x + column, low.y + row)
			var base: Vector2 = CityStreetPlan.base_junction(plan, address)
			var position: Vector2 = base if _point_outline_distance(base, outline) < 0.016 else CityStreetPlan.junction(region, city_id, address, plan, organic)
			var local := Vector2i(column, row)
			positions[local] = position
			if not Jurisdiction.polygon_contains_point(position, outline):
				continue
			grid[local] = layout.nodes.size()
			layout.nodes.append(position)
			layout.canonical_nodes[layout.nodes.size() - 1] = "%d:%d:%d" % [city_id, address.x, address.y]
	var field_context: Dictionary = DirectionField.city_context(region, city_id, layout.bounds)
	var convex: bool = absf(Geography.polygon_area(Geometry2D.convex_hull(outline)) - Geography.polygon_area(outline)) < 0.000001
	var organic_paths: Dictionary = {}
	for row in range(rows + 1):
		for column in range(columns + 1):
			var local := Vector2i(column, row)
			if not grid.has(local):
				continue
			for step in [Vector2i.RIGHT, Vector2i.DOWN]:
				var next: Vector2i = local + step
				if not grid.has(next):
					continue
				var first: int = grid[local]
				var last: int = grid[next]
				if not convex and not Geography.segment_on_land(outline, layout.nodes[first], layout.nodes[last]):
					continue
				var global_col: int = low.x + column
				var global_row: int = low.y + row
				var road_class: String = Roads.COLLECTOR if (step == Vector2i.DOWN and posmod(global_col, 4) == 0) or (step == Vector2i.RIGHT and posmod(global_row, 4) == 0) else Roads.LOCAL
				if _near_field_arterial(layout.nodes[first], layout.nodes[last], field_context, 0.075) or _near_parallel_outline(layout.nodes[first], layout.nodes[last], outline, 0.045):
					continue
				var phase := 1 if road_class == Roads.COLLECTOR else 2
				if organic:
					var path: PackedVector2Array = _organic_grid_path(region, city_id, layout.nodes[first], layout.nodes[last], plan["axis"], field_context, outline)
					if path.size() > 2:
						organic_paths[_grid_edge_key(local, next)] = path
						_append_path_edge(layout, first, last, road_class, phase, path)
					else:
						_append_edge(layout, first, last, road_class, phase)
				else:
					_append_edge(layout, first, last, road_class, phase)
	_fill_clipped_grid_lines(region, layout, grid, positions, columns, rows, outline, field_context, grid_guide.get("seam_targets", []))
	_build_boundary_roads(region, layout, outline, field_context)
	_promote_city_collector_crossings(layout, plan)
	_connect_disconnected_streets(layout, outline)
	var degree := PackedInt32Array()
	degree.resize(layout.nodes.size())
	for edge in layout.edges:
		degree[int(edge.x)] += 1
		degree[int(edge.y)] += 1
	for row in range(rows):
		for column in range(columns):
			var corners: Array[Vector2i] = [Vector2i(column, row), Vector2i(column + 1, row), Vector2i(column + 1, row + 1), Vector2i(column, row + 1)]
			var cell: PackedVector2Array = _organic_cell_polygon(corners, positions, organic_paths) if organic else PackedVector2Array()
			var curved_cell: bool = not cell.is_empty()
			var corner_ids := PackedInt32Array()
			for corner in corners:
				if not curved_cell:
					cell.append(positions[corner])
				if grid.has(corner) and degree[grid[corner]] > 0:
					corner_ids.append(grid[corner])
			if triangulate(cell).is_empty():
				continue
			var pieces: Array[PackedVector2Array] = Geometry2D.intersect_polygons(cell, outline)
			for piece_index in range(pieces.size()):
				var piece: PackedVector2Array = pieces[piece_index]
				var area: float = Geography.polygon_area(piece)
				if area < 0.0005 or triangulate(piece).is_empty():
					continue
				var access := corner_ids.duplicate()
				if access.is_empty():
					var center := Vector2.ZERO
					for vertex in piece:
						center += vertex
					center /= float(piece.size())
					var nearest := 0.5 * 0.5
					var nearest_id := -1
					for node_id in range(layout.nodes.size()):
						if degree[node_id] == 0:
							continue
						var distance: float = center.distance_squared_to(layout.nodes[node_id])
						if distance < nearest and Geography.segment_on_land(outline, center, layout.nodes[node_id]):
							nearest = distance
							nearest_id = node_id
					if nearest_id < 0:
						continue
					access.append(nearest_id)
				var seed_value: int = hash("%d:block:%d:%d:%d" % [region.generation_seed, city_id, low.x + column, low.y + row])
				_append_block_polygon(layout, piece, access, 2, seed_value, false, area < layout.grid_column_spacing_km * layout.grid_row_spacing_km * 0.92)
				var block: Dictionary = layout.blocks[-1]
				var cell_key: String = CityStreetPlan.block_key(city_id, Vector2i(low.x + column, low.y + row), organic)
				block["canonical_id"] = cell_key if pieces.size() == 1 else "%s:fragment:%d" % [cell_key, piece_index]
				layout.blocks[-1] = block
	if organic:
		_organic_merge_local_blocks(layout, region.generation_seed)
	_connect_unmatched_seams(layout, grid_guide.get("seam_targets", []), field_context)
	_ensure_frontage_collector(layout)
	_space_frontage_collectors(layout, grid_guide.get("seam_targets", []))
	_service_pointed_fringe(layout)
	_build_core_paths(layout)
	_mark_canonical_edges(layout)
	if layout.arterial_nodes.is_empty() or layout.core_paths.is_empty() or layout.blocks.is_empty():
		layout.polygon = PackedVector2Array()
	return layout


static func _mark_canonical_edges(layout) -> void:
	for edge_id in range(layout.edges.size()):
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if not layout.canonical_nodes.has(first) or not layout.canonical_nodes.has(last):
			continue
		var first_key: String = layout.canonical_nodes[first]
		var last_key: String = layout.canonical_nodes[last]
		layout.canonical_edges[edge_id] = "%s|%s" % [first_key, last_key] if first_key < last_key else "%s|%s" % [last_key, first_key]


static func _connect_disconnected_streets(layout, outline: PackedVector2Array) -> void:
	for attempt in range(12):
		var connected_nodes: Dictionary = _arterial_reachable_nodes(layout)
		var stranded: Dictionary = {}
		for edge in layout.edges:
			for node_id in [int(edge.x), int(edge.y)]:
				if not connected_nodes.has(node_id):
					stranded[node_id] = true
		if stranded.is_empty():
			return
		var best := 0.45 * 0.45
		var from_id := -1
		var to_id := -1
		for first_id in stranded:
			for second_id in connected_nodes:
				var distance: float = layout.nodes[first_id].distance_squared_to(layout.nodes[second_id])
				if distance < 0.03 * 0.03 or distance >= best:
					continue
				if not Geography.segment_on_land(outline, layout.nodes[first_id], layout.nodes[second_id]) or _crosses_layout_road(layout, layout.nodes[first_id], layout.nodes[second_id]):
					continue
				best = distance
				from_id = first_id
				to_id = second_id
		if from_id < 0:
			break
		_append_edge(layout, from_id, to_id, Roads.LOCAL, 1)
	var reachable: Dictionary = _arterial_reachable_nodes(layout)
	for edge_id in range(layout.edges.size() - 1, -1, -1):
		var edge: Vector2 = layout.edges[edge_id]
		if reachable.has(int(edge.x)) and reachable.has(int(edge.y)):
			continue
		var road_class: String = layout.classes[edge_id]
		var phase: int = layout.phases[edge_id]
		var length: float = layout.lengths[edge_id]
		if road_class != Roads.ARTERIAL:
			layout.phase_costs[phase - 1] -= roundi(length * Roads.construction_cost(road_class))
			layout.phase_upkeep[phase - 1] -= length * Roads.upkeep(road_class)
		layout.edges.remove_at(edge_id)
		layout.classes.remove_at(edge_id)
		layout.phases.remove_at(edge_id)
		layout.lengths.remove_at(edge_id)
		var shifted_paths: Dictionary = {}
		for old_id in layout.edge_paths:
			if old_id != edge_id:
				shifted_paths[old_id - 1 if old_id > edge_id else old_id] = layout.edge_paths[old_id]
		layout.edge_paths = shifted_paths


static func _promote_city_collector_crossings(layout, plan: Dictionary) -> void:
	var axis: Vector2 = plan["axis"]
	var cross_axis: Vector2 = axis.orthogonal()
	var origin: Vector2 = plan["origin"]
	var column_spacing: float = float(plan["column_spacing"])
	var row_spacing: float = float(plan["row_spacing"])
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] != Roads.LOCAL:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if layout.arterial_nodes.has(first) == layout.arterial_nodes.has(last):
			continue
		var arterial_point: Vector2 = layout.nodes[first] if layout.arterial_nodes.has(first) else layout.nodes[last]
		var interior_point: Vector2 = layout.nodes[last] if layout.arterial_nodes.has(first) else layout.nodes[first]
		var direction: Vector2 = (interior_point - arterial_point).normalized()
		var coordinate: Vector2 = arterial_point - origin
		var column: int = roundi(coordinate.dot(axis) / column_spacing)
		var row: int = roundi(coordinate.dot(cross_axis) / row_spacing)
		var along_column: bool = posmod(column, 4) == 0 and absf(coordinate.dot(axis) - float(column) * column_spacing) < 0.03 and absf(direction.dot(cross_axis)) > 0.7
		var along_row: bool = posmod(row, 4) == 0 and absf(coordinate.dot(cross_axis) - float(row) * row_spacing) < 0.03 and absf(direction.dot(axis)) > 0.7
		if not along_column and not along_row:
			continue
		_promote_local_to_collector(layout, edge_id)


static func _promote_local_to_collector(layout, edge_id: int) -> void:
	if layout.classes[edge_id] != Roads.LOCAL:
		return
	var old_phase: int = layout.phases[edge_id]
	var length: float = layout.lengths[edge_id]
	layout.phase_costs[old_phase - 1] -= roundi(length * Roads.construction_cost(Roads.LOCAL))
	layout.phase_upkeep[old_phase - 1] -= length * Roads.upkeep(Roads.LOCAL)
	layout.classes[edge_id] = Roads.COLLECTOR
	layout.phases[edge_id] = 1
	layout.phase_costs[0] += roundi(length * Roads.construction_cost(Roads.COLLECTOR))
	layout.phase_upkeep[0] += length * Roads.upkeep(Roads.COLLECTOR)


static func _space_frontage_collectors(layout, seam_targets: Array) -> void:
	var entrances: Array[Dictionary] = []
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] != Roads.COLLECTOR:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if layout.arterial_nodes.has(first) == layout.arterial_nodes.has(last):
			continue
		var point: Vector2 = layout.nodes[first] if layout.arterial_nodes.has(first) else layout.nodes[last]
		var priority := 0
		for target in seam_targets:
			if target.get("arterial_crossing", false) and point.distance_to(target["point"]) < 0.015:
				priority = 1
				break
		entrances.append({"edge_id": edge_id, "point": point, "priority": priority, "length": layout.lengths[edge_id]})
	entrances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["priority"] != b["priority"]:
			return int(a["priority"]) > int(b["priority"])
		return float(a["length"]) > float(b["length"])
	)
	var kept := PackedVector2Array()
	for entrance in entrances:
		var close := false
		for point in kept:
			if point.distance_to(entrance["point"]) < 0.36:
				close = true
				break
		if not close and kept.size() < 3:
			kept.append(entrance["point"])
			continue
		var edge_id: int = entrance["edge_id"]
		var length: float = layout.lengths[edge_id]
		layout.phase_costs[0] -= roundi(length * Roads.construction_cost(Roads.COLLECTOR))
		layout.phase_upkeep[0] -= length * Roads.upkeep(Roads.COLLECTOR)
		layout.classes[edge_id] = Roads.LOCAL
		layout.phases[edge_id] = 2
		layout.phase_costs[1] += roundi(length * Roads.construction_cost(Roads.LOCAL))
		layout.phase_upkeep[1] += length * Roads.upkeep(Roads.LOCAL)


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
	_promote_local_to_collector(layout, fallback)


static func _frontage_collector_columns(layout, grid: Dictionary, positions: Dictionary, columns: int, rows: int, convex: bool, outline: PackedVector2Array, guide: Dictionary) -> Dictionary:
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
	var seam_priorities: Array = guide.get("seam_targets", []).duplicate()
	seam_priorities.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return bool(first.get("arterial_crossing", false)) and not bool(second.get("arterial_crossing", false)))
	for target in seam_priorities:
		if target.get("road_class", "") != Roads.COLLECTOR:
			continue
		var best_column := -1
		var best_distance := 0.09
		for choice in choices:
			var column: int = choice["column"]
			if selected.has(column):
				continue
			var spaced := true
			for other_column in selected:
				if choice["point"].distance_to(layout.nodes[grid[Vector2i(other_column, 0)]]) < COLLECTOR_SPACING_KM:
					spaced = false
			if not spaced:
				continue
			var first: Vector2 = positions[Vector2i(column, 0)]
			var interior: Vector2 = positions[Vector2i(column, choice["depth"])]
			var span: float = first.distance_to(interior)
			if span < 0.1:
				continue
			var direction: Vector2 = (interior - first) / span
			var offset: Vector2 = target["point"] - first
			var along: float = offset.dot(direction)
			var arterial_crossing: bool = target.get("arterial_crossing", false)
			if (arterial_crossing and first.distance_to(target["point"]) > 0.015) or (not arterial_crossing and along < 0.25):
				continue
			if along > span + 0.25 or absf(direction.dot(target["direction"])) < 0.65:
				continue
			var distance: float = first.distance_to(target["point"]) if arterial_crossing else absf(direction.cross(offset))
			if distance < best_distance:
				best_distance = distance
				best_column = column
		if best_column >= 0:
			selected[best_column] = true
			if selected.size() >= 2:
				return selected
	var first_column: int = choices[0]["column"]
	var last_column: int = choices[-1]["column"]
	var frontage_span: float = choices[0]["point"].distance_to(choices[-1]["point"])
	var targets: Array = [0.5] if frontage_span < 0.95 else [0.33, 0.67]
	for fraction in targets:
		if selected.size() >= 2:
			break
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


static func _anchor_arterial_collectors(positions: Dictionary, outline: PackedVector2Array, targets: Array, columns: int, rows: int) -> void:
	var used_columns: Dictionary = {}
	var anchored_points := PackedVector2Array()
	for target in targets:
		if not target.get("arterial_crossing", false) or target.get("road_class", "") != Roads.COLLECTOR:
			continue
		var point: Vector2 = target["point"]
		if _point_outline_distance(point, outline) > 0.008:
			continue
		var spaced := true
		for previous in anchored_points:
			if point.distance_to(previous) < COLLECTOR_SPACING_KM:
				spaced = false
		if not spaced:
			continue
		var best_column := -1
		var best_distance := 0.085
		for column in range(1, columns):
			if used_columns.has(column):
				continue
			var first: Vector2 = positions[Vector2i(column, 0)]
			var interior: Vector2 = positions[Vector2i(column, mini(3, rows))]
			var direction: Vector2 = (interior - first).normalized()
			if absf(direction.dot(target["direction"])) < 0.65:
				continue
			var distance: float = first.distance_to(point)
			if distance >= best_distance:
				continue
			var left: Vector2 = positions[Vector2i(column - 1, 0)]
			var right: Vector2 = positions[Vector2i(column + 1, 0)]
			if point.distance_to(left) < 0.065 or point.distance_to(right) < 0.065:
				continue
			if not Geography.segment_on_land(outline, point, positions[Vector2i(column, 1)]):
				continue
			best_column = column
			best_distance = distance
		if best_column < 0:
			continue
		used_columns[best_column] = true
		var shift: Vector2 = point - positions[Vector2i(best_column, 0)]
		positions[Vector2i(best_column, 0)] = point
		# Ease the first block into the existing grid without shifting the far seam.
		if rows > 2 and _point_outline_distance(positions[Vector2i(best_column, 1)], outline) > 0.025:
			var next: Vector2 = positions[Vector2i(best_column, 1)] + shift * 0.35
			if Jurisdiction.polygon_contains_point(next, outline):
				positions[Vector2i(best_column, 1)] = next
		anchored_points.append(point)
		if anchored_points.size() >= 2:
			return


static func _point_outline_distance(point: Vector2, outline: PackedVector2Array) -> float:
	var nearest := INF
	for segment in range(outline.size()):
		nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[segment], outline[(segment + 1) % outline.size()])))
	return nearest


static func _guided_collector_row(sample: Vector2, normal: Vector2, axis: Vector2, fractions: PackedFloat32Array, depth: float, fallback: int, guide: Dictionary) -> int:
	var points: PackedVector2Array = guide.get("collector_points", PackedVector2Array())
	var directions: PackedVector2Array = guide.get("collector_directions", PackedVector2Array())
	var best_row := fallback
	var best_distance := 0.11
	for index in range(mini(points.size(), directions.size())):
		if absf(directions[index].dot(axis)) < 0.94:
			continue
		for row in range(2, fractions.size() - 1):
			if fractions[row] * depth > 0.75:
				break
			var point: Vector2 = sample + normal * fractions[row] * depth
			var distance: float = absf((points[index] - point).dot(normal))
			if distance < best_distance:
				best_distance = distance
				best_row = row
	return best_row


static func _snap_grid_seams(positions: Dictionary, outline: PackedVector2Array, targets: Array, columns: int, rows: int, half_row: int, edge_frontage: bool, line_guidance: bool = true) -> void:
	if targets.is_empty():
		return
	if edge_frontage and not line_guidance:
		return
	if not edge_frontage:
		_snap_through_grid_seams(positions, outline, targets, columns, rows, half_row)
		return
	var boundary_addresses: Array[Vector2i] = []
	for row in range(rows + 1):
		if (row == half_row and not edge_frontage) or (row == 0 and edge_frontage):
			continue
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			var point: Vector2 = positions[address]
			if _point_outline_distance(point, outline) <= 0.035:
				boundary_addresses.append(address)
	var ordered_targets: Array = targets.duplicate()
	ordered_targets.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return first.get("road_class", "") == Roads.COLLECTOR and second.get("road_class", "") != Roads.COLLECTOR)
	var original: Dictionary = positions.duplicate()
	var used_addresses: Dictionary = {}
	var assignments: Array[Dictionary] = []
	for target in ordered_targets:
		var best: Dictionary = {}
		var best_score := 0.13
		for address in boundary_addresses:
			if used_addresses.has(address):
				continue
			var point: Vector2 = original[address]
			var offset: Vector2 = target["point"] - point
			if offset.length() >= 0.13:
				continue
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var next: Vector2i = address + step
				if not original.has(next):
					continue
				var heading: Vector2 = (original[next] - target["point"]).normalized()
				var alignment: float = heading.dot(target["direction"])
				if alignment < 0.7:
					continue
				var run := 0.0
				var cursor: Vector2i = address
				for segment in range(5):
					var following: Vector2i = cursor + step
					if not original.has(following) or not Jurisdiction.polygon_contains_point(original[following], outline) or not Geography.segment_on_land(outline, target["point"] if cursor == address else original[cursor], original[following]):
						break
					run += original[cursor].distance_to(original[following])
					cursor = following
				var across := Vector2i(-step.y, step.x)
				var cross_street := false
				for side in [-1, 1]:
					var neighbor: Vector2i = next + across * side
					if original.has(neighbor) and Jurisdiction.polygon_contains_point(original[neighbor], outline) and Geography.segment_on_land(outline, original[next], original[neighbor]):
						cross_street = true
				if run < 0.22 and not (run >= 0.09 and cross_street):
					continue
				var clear := true
				for side in [-1, 1]:
					var adjacent: Vector2i = address + across * side
					if original.has(adjacent) and target["point"].distance_to(original[adjacent]) < 0.055:
						clear = false
				if not clear:
					continue
				var score: float = offset.length() + (1.0 - alignment) * 0.04
				if score < best_score:
					best_score = score
					best = {"address": address, "step": step, "point": target["point"], "shift": offset}
		if not best.is_empty():
			used_addresses[best["address"]] = true
			assignments.append(best)
	var shifts: Dictionary = {}
	for assignment in assignments:
		var cursor: Vector2i = assignment["address"]
		var step: Vector2i = assignment["step"]
		var distance := 0.0
		for segment in range(8):
			if not original.has(cursor) or distance >= 0.75:
				break
			var weight: float = 1.0 - distance / 0.75
			shifts[cursor] = shifts.get(cursor, Vector2.ZERO) + assignment["shift"] * weight
			var following: Vector2i = cursor + step
			if not original.has(following) or not Jurisdiction.polygon_contains_point(original[following], outline):
				break
			distance += original[cursor].distance_to(original[following])
			cursor = following
	for address in shifts:
		var moved: Vector2 = original[address] + shifts[address]
		if Jurisdiction.polygon_contains_point(moved, outline) or _point_outline_distance(moved, outline) < 0.005:
			positions[address] = moved
	for assignment in assignments:
		positions[assignment["address"]] = assignment["point"]


static func _snap_through_grid_seams(positions: Dictionary, outline: PackedVector2Array, targets: Array, columns: int, rows: int, half_row: int) -> void:
	var used: Dictionary = {}
	for row in range(rows + 1):
		if row == half_row:
			continue
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			var point: Vector2 = positions[address]
			if _point_outline_distance(point, outline) > 0.035:
				continue
			var nearest := 0.15
			var selected := -1
			for target_id in range(targets.size()):
				if used.has(target_id):
					continue
				var distance: float = point.distance_to(targets[target_id]["point"])
				if distance < nearest:
					nearest = distance
					selected = target_id
			if selected >= 0:
				positions[address] = targets[selected]["point"]
				used[selected] = true


static func _extend_streets_to_boundary(layout, grid: Dictionary, positions: Dictionary, collector_columns: Dictionary, columns: int, rows: int, outline: PackedVector2Array, collector_row: int, maximum_distance: int, guide: Dictionary, field_context: Dictionary, through: bool = false) -> void:
	var seam_targets: Array = guide.get("seam_targets", [])
	var used_targets: Dictionary = {}
	var built_connections: Dictionary = {}
	var connected_edges: Dictionary = {}
	for pair in layout.edges:
		var first_id := int(pair.x)
		var last_id := int(pair.y)
		built_connections[Vector2i(mini(first_id, last_id), maxi(first_id, last_id))] = true
		connected_edges[first_id] = int(connected_edges.get(first_id, 0)) + 1
		connected_edges[last_id] = int(connected_edges.get(last_id, 0)) + 1
	for row in range(rows + 1):
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			if (row == 0 and not through) or not grid.has(address):
				continue
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				# Only continue a street that already reaches this interior node.
				if not grid.has(address - step):
					continue
				var first_id: int = grid[address]
				var previous_id: int = grid[address - step]
				if not built_connections.has(Vector2i(mini(first_id, previous_id), maxi(first_id, previous_id))) or (int(connected_edges.get(first_id, 0)) < 2 and int(connected_edges.get(previous_id, 0)) < 2):
					continue
				var next: Vector2i = address + step
				if grid.has(next) or not positions.has(next):
					continue
				var first: Vector2 = layout.nodes[grid[address]]
				var target: Vector2 = positions[next]
				var boundary: Vector2 = _first_boundary_crossing(first, target, outline)
				if not is_finite(boundary.x) or first.distance_to(boundary) < 0.01:
					continue
				var selected_target := -1
				var collector: bool = (step.x != 0 and (absi(row - floori(float(rows) / 2.0)) == 3 if through else row == collector_row)) or (step.y != 0 and ((column % 4 == 0 or column == columns) if through else collector_columns.has(column)))
				var snap_distance := 0.16 if through else 0.11
				var best_score := snap_distance
				for target_id in range(seam_targets.size()):
					if used_targets.has(target_id):
						continue
					var seam_target: Dictionary = seam_targets[target_id]
					if seam_target.get("arterial_crossing", false):
						continue
					var seam_point: Vector2 = seam_target["point"]
					var distance: float = boundary.distance_to(seam_point)
					if distance > snap_distance or (seam_point - first).normalized().dot(seam_target["direction"]) > -0.55 or not Geography.segment_on_land(outline, first, seam_point):
						continue
					var same_class: bool = collector == (seam_target["road_class"] == Roads.COLLECTOR)
					var score: float = distance + (0.025 if not same_class else 0.0)
					if score < best_score:
						best_score = score
						selected_target = target_id
				if selected_target >= 0:
					boundary = seam_targets[selected_target]["point"]
					collector = collector or seam_targets[selected_target]["road_class"] == Roads.COLLECTOR
				if _near_field_arterial(first, boundary, field_context, 0.075):
					continue
				if selected_target >= 0:
					used_targets[selected_target] = true
				var boundary_id: int = layout.nodes.size()
				layout.nodes.append(boundary)
				var stage: int = 1 if collector else _phase(absi(row - floori(float(rows) / 2.0)) if through else row, maximum_distance)
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


# A tapered tip can cut several grid cells without containing any grid
# junctions. Clip their shared grid lines into streets so those cells do not
# form one visually empty cap between the last full row and the perimeter.
static func _fill_clipped_grid_lines(region, layout, grid: Dictionary, positions: Dictionary, columns: int, rows: int, outline: PackedVector2Array, field_context: Dictionary, seam_targets: Array = []) -> void:
	var built_connections: Dictionary = {}
	for edge in layout.edges:
		built_connections[Vector2i(mini(int(edge.x), int(edge.y)), maxi(int(edge.x), int(edge.y)))] = true
	for row in range(rows + 1):
		for column in range(columns + 1):
			var address := Vector2i(column, row)
			for step in [Vector2i.RIGHT, Vector2i.DOWN]:
				var next: Vector2i = address + step
				if next.x > columns or next.y > rows:
					continue
				if grid.has(address) and grid.has(next) and built_connections.has(Vector2i(mini(grid[address], grid[next]), maxi(grid[address], grid[next]))):
					continue
				var first: Vector2 = positions[address]
				var last: Vector2 = positions[next]
				if first.distance_to(last) < 0.04:
					continue
				var stations: Array[Dictionary] = []
				for point in [first, last]:
					if Jurisdiction.polygon_contains_point(point, outline) or _point_on_outline(point, outline):
						stations.append({"point": point, "distance": first.distance_to(point)})
				for segment in range(outline.size()):
					var hit = Geometry2D.segment_intersects_segment(first, last, outline[segment], outline[(segment + 1) % outline.size()])
					if hit == null:
						continue
					var inside: Vector2 = last if Jurisdiction.polygon_contains_point(last, outline) else first
					var inward: Vector2 = (inside - hit).normalized()
					if inward != Vector2.ZERO:
						# A clipped crossing is often between grid nodes, so snap the
						# crossing itself to the road in the neighboring district.
						var nearest_target := 0.055
						for target in seam_targets:
							if target.get("arterial_crossing", false) or inward.dot(target["direction"]) < 0.65:
								continue
							var distance: float = hit.distance_to(target["point"])
							if distance < nearest_target and Geography.segment_on_land(outline, target["point"], inside):
								nearest_target = distance
								hit = target["point"]
					var duplicate := false
					for station in stations:
						if station["point"].distance_to(hit) < 0.003:
							duplicate = true
							break
					if not duplicate:
						stations.append({"point": hit, "distance": first.distance_to(hit)})
				stations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
				for index in range(stations.size() - 1):
					var start: Vector2 = stations[index]["point"]
					var finish: Vector2 = stations[index + 1]["point"]
					if start.distance_to(finish) < 0.065:
						continue
					var middle: Vector2 = (start + finish) * 0.5
					if not Jurisdiction.polygon_contains_point(middle, outline) or _near_layout_road(layout, middle, 0.008) or _near_highway(region, middle, 0.07) or _near_field_arterial(start, finish, field_context, 0.075) or _near_parallel_outline(start, finish, outline, 0.065) or _near_parallel_layout_road(layout, start, finish, 0.055):
						continue
					_append_clipped_street_run(layout, start, finish, outline)


# A clipped fringe is a buildable block, but it looks like vacant land when its
# outside edge has no street. Continue local streets along the usable district
# perimeter and join each new run to the existing interior network.
static func _build_boundary_roads(region, layout, outline: PackedVector2Array, field_context: Dictionary) -> void:
	var boundary_nodes: Dictionary = {}
	for segment in range(outline.size()):
		var first: Vector2 = outline[segment]
		var last: Vector2 = outline[(segment + 1) % outline.size()]
		var length: float = first.distance_to(last)
		if length < 0.015:
			continue
		var stations: Array[Dictionary] = [{"point": first, "distance": 0.0}, {"point": last, "distance": length}]
		for node_id in range(layout.nodes.size()):
			var point: Vector2 = layout.nodes[node_id]
			var along: float = (point - first).dot((last - first) / length)
			if along <= 0.003 or along >= length - 0.003:
				continue
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last)) < 0.003:
				stations.append({"point": point, "distance": along})
		stations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
		for index in range(stations.size() - 1):
			var start: Vector2 = stations[index]["point"]
			var finish: Vector2 = stations[index + 1]["point"]
			if start.distance_to(finish) < 0.012:
				continue
			var middle: Vector2 = (start + finish) * 0.5
			if _near_layout_road(layout, middle, 0.014) or _near_highway(region, middle, 0.07):
				continue
			var on_arterial: bool = _near_field_arterial(start, finish, field_context, 0.002)
			if not on_arterial and _near_field_arterial(start, finish, field_context, 0.075):
				# The actual regional arterial already serves this thin frontage.
				# A local perimeter street here would draw almost on top of it.
				continue
			var start_id: int = _ensure_boundary_node(layout, start)
			var finish_id: int = _ensure_boundary_node(layout, finish)
			if start_id == finish_id:
				continue
			if on_arterial:
				_append_edge(layout, start_id, finish_id, Roads.ARTERIAL, 1)
				if not layout.arterial_nodes.has(start_id):
					layout.arterial_nodes.append(start_id)
				if not layout.arterial_nodes.has(finish_id):
					layout.arterial_nodes.append(finish_id)
			else:
				_append_edge(layout, start_id, finish_id, Roads.LOCAL, 1)
				boundary_nodes[start_id] = true
				boundary_nodes[finish_id] = true
	_connect_boundary_roads(layout, outline, boundary_nodes)


static func _ensure_boundary_node(layout, point: Vector2) -> int:
	for node_id in range(layout.nodes.size()):
		if layout.nodes[node_id].distance_squared_to(point) < 0.003 * 0.003:
			return node_id
	var result: int = layout.nodes.size()
	layout.nodes.append(point)
	return result


static func _layout_edge_path(layout, edge_id: int) -> PackedVector2Array:
	if layout.edge_paths.has(edge_id):
		return layout.edge_paths[edge_id]
	var edge: Vector2 = layout.edges[edge_id]
	return PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]])


static func _path_length(path: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return length


static func _ensure_street_intersection(layout, point: Vector2) -> int:
	for node_id in range(layout.nodes.size()):
		if layout.nodes[node_id].distance_squared_to(point) < 0.003 * 0.003:
			return node_id
	for edge_id in range(layout.edges.size()):
		var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
		for segment in range(1, path.size()):
			var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(point, path[segment - 1], path[segment])
			if nearest.distance_to(point) > 0.003 or nearest.distance_to(path[segment - 1]) < 0.005 or nearest.distance_to(path[segment]) < 0.005:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var old_length: float = layout.lengths[edge_id]
			var first_path: PackedVector2Array = path.slice(0, segment)
			first_path.append(nearest)
			var second_path := PackedVector2Array([nearest])
			second_path.append_array(path.slice(segment))
			var new_id: int = layout.nodes.size()
			layout.nodes.append(nearest)
			layout.edges[edge_id] = Vector2(edge.x, new_id)
			layout.lengths[edge_id] = _path_length(first_path)
			if first_path.size() > 2:
				layout.edge_paths[edge_id] = first_path
			else:
				layout.edge_paths.erase(edge_id)
			var road_class: String = layout.classes[edge_id]
			var phase: int = layout.phases[edge_id]
			if road_class == Roads.ARTERIAL:
				layout.arterial_nodes.append(new_id)
			else:
				layout.phase_costs[phase - 1] += roundi(layout.lengths[edge_id] * Roads.construction_cost(road_class)) - roundi(old_length * Roads.construction_cost(road_class))
				layout.phase_upkeep[phase - 1] += (layout.lengths[edge_id] - old_length) * Roads.upkeep(road_class)
			_append_path_edge(layout, new_id, int(edge.y), road_class, phase, second_path)
			return new_id
	return _ensure_boundary_node(layout, point)


static func _append_clipped_street_run(layout, first: Vector2, last: Vector2, outline: PackedVector2Array) -> void:
	var stations: Array[Vector2] = [first, last]
	for edge_id in range(layout.edges.size()):
		var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
		for segment in range(1, path.size()):
			var hit = Geometry2D.segment_intersects_segment(first, last, path[segment - 1], path[segment])
			if hit == null or hit.distance_to(first) < 0.003 or hit.distance_to(last) < 0.003:
				continue
			var duplicate := false
			for station in stations:
				if station.distance_to(hit) < 0.003:
					duplicate = true
					break
			if not duplicate:
				stations.append(hit)
	stations.sort_custom(func(a: Vector2, b: Vector2) -> bool: return first.distance_squared_to(a) < first.distance_squared_to(b))
	for index in range(stations.size() - 1):
		var start: Vector2 = stations[index]
		var finish: Vector2 = stations[index + 1]
		if start.distance_to(finish) < 0.065 or not Jurisdiction.polygon_contains_point((start + finish) * 0.5, outline) or _near_layout_road(layout, (start + finish) * 0.5, 0.008):
			continue
		var start_id: int = _ensure_street_intersection(layout, start)
		var finish_id: int = _ensure_street_intersection(layout, finish)
		if start_id == finish_id:
			continue
		_append_edge(layout, start_id, finish_id, Roads.LOCAL, 1)


static func _near_parallel_layout_road(layout, first: Vector2, last: Vector2, tolerance: float) -> bool:
	var direction: Vector2 = (last - first).normalized()
	if direction == Vector2.ZERO:
		return false
	var middle: Vector2 = (first + last) * 0.5
	for edge_id in range(layout.edges.size()):
		var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
		for segment in range(1, path.size()):
			var other: Vector2 = path[segment] - path[segment - 1]
			if other.length_squared() < 0.000001 or absf(direction.dot(other.normalized())) < 0.93:
				continue
			if middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, path[segment - 1], path[segment])) < tolerance:
				return true
	return false


static func _near_parallel_outline(first: Vector2, last: Vector2, outline: PackedVector2Array, tolerance: float) -> bool:
	var direction: Vector2 = (last - first).normalized()
	if direction == Vector2.ZERO:
		return false
	var middle: Vector2 = (first + last) * 0.5
	for index in range(outline.size()):
		var before: Vector2 = outline[index]
		var after: Vector2 = outline[(index + 1) % outline.size()]
		var side: Vector2 = after - before
		if side.length_squared() < 0.000001 or absf(direction.dot(side.normalized())) < 0.93:
			continue
		var distance: float = middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, before, after))
		if distance > 0.003 and distance < tolerance:
			return true
	return false


static func _near_layout_road(layout, point: Vector2, tolerance: float) -> bool:
	for edge in layout.edges:
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])) < tolerance:
			return true
	return false


static func _near_highway(region, point: Vector2, tolerance: float) -> bool:
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY or not Geography._bounds(link.points).grow(tolerance).has_point(point):
			continue
		for segment in range(1, link.points.size()):
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, link.points[segment - 1], link.points[segment])) < tolerance:
				return true
	return false


static func _connect_boundary_roads(layout, outline: PackedVector2Array, boundary_nodes: Dictionary) -> void:
	if boundary_nodes.is_empty():
		return
	var connected: Dictionary = _arterial_reachable_nodes(layout)
	for boundary_id in boundary_nodes:
		if connected.has(boundary_id):
			continue
		var point: Vector2 = layout.nodes[boundary_id]
		var nearest := 0.35
		var target_id := -1
		for candidate_id in connected:
			var target: Vector2 = layout.nodes[candidate_id]
			var distance: float = point.distance_to(target)
			if distance < 0.02 or distance >= nearest or not Geography.segment_on_land(outline, point, target) or _crosses_layout_road(layout, point, target):
				continue
			nearest = distance
			target_id = candidate_id
		if target_id >= 0:
			_append_edge(layout, boundary_id, target_id, Roads.LOCAL, 1)
			connected = _arterial_reachable_nodes(layout)


static func _arterial_reachable_nodes(layout) -> Dictionary:
	var neighbors: Dictionary = {}
	for edge in layout.edges:
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if not neighbors.has(first):
			neighbors[first] = []
		if not neighbors.has(last):
			neighbors[last] = []
		neighbors[first].append(last)
		neighbors[last].append(first)
	var connected: Dictionary = {}
	var pending: Array[int] = []
	for node_id in layout.arterial_nodes:
		connected[node_id] = true
		pending.append(node_id)
	while not pending.is_empty():
		var node_id: int = pending.pop_back()
		for next_id in neighbors.get(node_id, []):
			if connected.has(next_id):
				continue
			connected[next_id] = true
			pending.append(next_id)
	return connected


static func _crosses_layout_road(layout, first: Vector2, last: Vector2) -> bool:
	for edge in layout.edges:
		var hit = Geometry2D.segment_intersects_segment(first, last, layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])
		if hit != null and hit.distance_to(first) > 0.003 and hit.distance_to(last) > 0.003:
			return true
	return false


# Pointed fringe blocks have frontage on the first-phase perimeter street.
# Let them develop with that street instead of leaving the tip vacant until a
# distant grid row reaches its later construction phase.
static func _service_pointed_fringe(layout) -> void:
	var corners := PackedVector2Array()
	for index in range(layout.polygon.size()):
		var point: Vector2 = layout.polygon[index]
		var before: Vector2 = layout.polygon[posmod(index - 1, layout.polygon.size())] - point
		var after: Vector2 = layout.polygon[(index + 1) % layout.polygon.size()] - point
		if before.length() < 0.08 or after.length() < 0.08:
			continue
		var angle: float = absf(rad_to_deg(before.angle_to(after)))
		if angle < 15.0 or angle > 65.0:
			continue
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.LOCAL or layout.phases[edge_id] != 1:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var first: Vector2 = layout.nodes[int(edge.x)]
			var last: Vector2 = layout.nodes[int(edge.y)]
			if minf(first.distance_to(point), last.distance_to(point)) < 0.42 and _point_on_outline(first, layout.polygon) and _point_on_outline(last, layout.polygon):
				corners.append(point)
				break
	if corners.is_empty():
		return
	for block in layout.blocks:
		if not block.get("fringe", false) or int(block["phase"]) <= 1:
			continue
		var polygon: PackedVector2Array = block["polygon"]
		var center := Vector2.ZERO
		for point in polygon:
			center += point
		center /= float(polygon.size())
		for corner in corners:
			if center.distance_to(corner) > 0.42:
				continue
			var has_boundary_frontage := false
			for point in polygon:
				if point.distance_to(corner) < 0.42 and _point_on_outline(point, layout.polygon):
					has_boundary_frontage = true
					break
			if has_boundary_frontage:
				block["phase"] = 1
				break


static func _point_on_outline(point: Vector2, outline: PackedVector2Array) -> bool:
	for index in range(outline.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[index], outline[(index + 1) % outline.size()])) < 0.003:
			return true
	return false


static func _grid_edge_key(first: Vector2i, last: Vector2i) -> Vector3i:
	return Vector3i(mini(first.x, last.x), mini(first.y, last.y), 0 if first.y == last.y else 1)


static func _grid_edge_path(first: Vector2i, last: Vector2i, positions: Dictionary, paths: Dictionary) -> PackedVector2Array:
	var path: PackedVector2Array = paths.get(_grid_edge_key(first, last), PackedVector2Array())
	if path.is_empty():
		return PackedVector2Array([positions[first], positions[last]])
	if first.x > last.x or first.y > last.y:
		path = path.duplicate()
		path.reverse()
	return path


static func _organic_cell_polygon(corners: Array[Vector2i], positions: Dictionary, paths: Dictionary) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for side in range(4):
		var path: PackedVector2Array = _grid_edge_path(corners[side], corners[(side + 1) % 4], positions, paths)
		for index in range(path.size() - 1):
			polygon.append(path[index])
	return polygon if not triangulate(polygon).is_empty() else PackedVector2Array()


static func _organic_grid_path(region, city_id: int, first: Vector2, last: Vector2, guide: Vector2, field_context: Dictionary, outline: PackedVector2Array) -> PackedVector2Array:
	var distance: float = first.distance_to(last)
	if distance < 0.055 or _point_on_outline(first, outline) or _point_on_outline(last, outline):
		return PackedVector2Array()
	var chord: Vector2 = (last - first) / distance
	var center: Vector2 = region.cities[city_id]["center_km"]
	var entry: Vector2 = DirectionField.axis(region.generation_seed, city_id, first, chord, guide, true, center, field_context)
	var exit: Vector2 = DirectionField.axis(region.generation_seed, city_id, last, chord, guide, true, center, field_context)
	entry = chord.slerp(entry, 1.0).normalized()
	exit = chord.slerp(exit, 1.0).normalized()
	var control_first: Vector2 = first + entry * distance * 0.45
	var control_last: Vector2 = last - exit * distance * 0.45
	var result := PackedVector2Array([first])
	for station in range(1, 4):
		var t: float = float(station) / 4.0
		var inverse: float = 1.0 - t
		var point: Vector2 = first * inverse * inverse * inverse + control_first * 3.0 * inverse * inverse * t + control_last * 3.0 * inverse * t * t + last * t * t * t
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last)) > minf(0.030, distance * 0.22) or not Jurisdiction.polygon_contains_point(point, outline):
			return PackedVector2Array()
		result.append(point)
	result.append(last)
	return result


static func _near_field_arterial(first: Vector2, last: Vector2, field_context: Dictionary, tolerance: float) -> bool:
	var direction: Vector2 = (last - first).normalized()
	if direction == Vector2.ZERO:
		return false
	for road in field_context.get("roads", []):
		if absf(direction.dot(road["axis"])) < 0.93:
			continue
		var close := true
		for t in [0.25, 0.5, 0.75]:
			var point: Vector2 = first.lerp(last, t)
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, road["first"], road["last"])) >= tolerance:
				close = false
				break
		if close:
			return true
	return false


static func _fractions(count: int, rng: RandomNumberGenerator, varied: bool) -> PackedFloat32Array:
	var weights := PackedFloat32Array()
	var total := 0.0
	var phase: float = rng.randf_range(0.0, TAU) if varied else 0.0
	for index in range(count):
		# Organic spacing changes gradually across several blocks. Independent
		# random widths made the same district look like a distorted grid.
		var weight: float = clampf(1.0 + 0.22 * sin(float(index) * 0.48 + phase) + 0.12 * sin(float(index) * 0.21 - phase * 1.3), 0.72, 1.28) if varied else 1.0
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


static func _append_path_edge(layout, first: int, last: int, road_class: String, phase: int, path: PackedVector2Array) -> void:
	if path.size() < 3:
		_append_edge(layout, first, last, road_class, phase)
		return
	layout.edges.append(Vector2(first, last))
	layout.classes.append(road_class)
	layout.phases.append(phase)
	layout.edge_paths[layout.edges.size() - 1] = path
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
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


# Organic districts keep the through collectors, but join selected pairs of
# local blocks across a removed street.  This produces loops and occasional
# dead ends in the street graph rather than merely bowing a rectangular grid.
static func _organic_merge_local_blocks(layout, seed_value: int) -> void:
	var degree := PackedInt32Array()
	degree.resize(layout.nodes.size())
	for edge in layout.edges:
		degree[int(edge.x)] += 1
		degree[int(edge.y)] += 1
	for edge_id in range(layout.edges.size() - 1, -1, -1):
		if layout.classes[edge_id] != Roads.LOCAL:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if degree[first] < 2 or degree[last] < 2 or mini(degree[first], degree[last]) == 2 and maxi(degree[first], degree[last]) < 4:
			continue
		if posmod(hash("%d:organic-gap:%s:%d:%d" % [seed_value, layout.key, mini(first, last), maxi(first, last)]), 100) >= 29:
			continue
		var touching: Array[int] = []
		for block_id in range(layout.blocks.size()):
			var block: Dictionary = layout.blocks[block_id]
			if block.get("fringe", false) or block.get("park", false):
				continue
			var nodes: PackedInt32Array = block["nodes"]
			if nodes.has(first) and nodes.has(last):
				touching.append(block_id)
				if touching.size() > 2:
					break
		if touching.size() != 2:
			continue
		var a: Dictionary = layout.blocks[touching[0]]
		var b: Dictionary = layout.blocks[touching[1]]
		var combined: Array[PackedVector2Array] = Geometry2D.merge_polygons(a["polygon"], b["polygon"])
		if combined.size() != 1 or triangulate(combined[0]).is_empty():
			continue
		var area: float = Geography.polygon_area(combined[0])
		if absf(area - float(a["area_ha"] + b["area_ha"]) * 0.01) > 0.003:
			continue
		var joined_nodes: PackedInt32Array = a["nodes"].duplicate()
		for node_id in b["nodes"]:
			if not joined_nodes.has(node_id):
				joined_nodes.append(node_id)
		a["polygon"] = combined[0]
		a["nodes"] = joined_nodes
		a["area_ha"] = area * 100.0
		if a.has("canonical_id") and b.has("canonical_id"):
			var parts := PackedStringArray([a["canonical_id"], b["canonical_id"]])
			parts.sort()
			a["canonical_id"] = "+".join(parts)
		layout.blocks[touching[0]] = a
		layout.blocks.remove_at(touching[1])
		var phase: int = layout.phases[edge_id]
		var length: float = layout.lengths[edge_id]
		layout.phase_costs[phase - 1] -= roundi(length * Roads.construction_cost(Roads.LOCAL))
		layout.phase_upkeep[phase - 1] -= length * Roads.upkeep(Roads.LOCAL)
		layout.edges.remove_at(edge_id)
		layout.classes.remove_at(edge_id)
		layout.phases.remove_at(edge_id)
		layout.lengths.remove_at(edge_id)
		var shifted_paths: Dictionary = {}
		for old_id in layout.edge_paths:
			if old_id != edge_id:
				shifted_paths[old_id - 1 if old_id > edge_id else old_id] = layout.edge_paths[old_id]
		layout.edge_paths = shifted_paths
		degree[first] -= 1
		degree[last] -= 1


static func _connect_unmatched_seams(layout, targets: Array, field_context: Dictionary) -> void:
	var connected: Dictionary = {}
	for edge in layout.edges:
		connected[int(edge.x)] = int(connected.get(int(edge.x), 0)) + 1
		connected[int(edge.y)] = int(connected.get(int(edge.y), 0)) + 1
	var reachable: Dictionary = _arterial_reachable_nodes(layout)
	for target in targets:
		var arterial_crossing: bool = target.get("arterial_crossing", false)
		var point: Vector2 = target["point"]
		if _point_outline_distance(point, layout.polygon) > 0.012:
			continue
		var already := false
		var nearby_collector := -1
		for node_id in range(layout.nodes.size()):
			if not connected.has(node_id):
				continue
			var node_distance: float = layout.nodes[node_id].distance_to(point)
			if node_distance >= (0.025 if arterial_crossing else 0.015):
				continue
			if arterial_crossing:
				for edge_id in range(layout.edges.size()):
					var edge: Vector2 = layout.edges[edge_id]
					if int(edge.x) != node_id and int(edge.y) != node_id or layout.classes[edge_id] == Roads.ARTERIAL:
						continue
					if layout.classes[edge_id] == Roads.LOCAL and node_distance < 0.005:
						_promote_local_to_collector(layout, edge_id)
					if layout.classes[edge_id] != Roads.COLLECTOR:
						continue
					if node_distance < 0.003:
						if not layout.arterial_nodes.has(node_id):
							layout.arterial_nodes.append(node_id)
						already = true
					elif nearby_collector < 0 and Geography.segment_on_land(layout.polygon, point, layout.nodes[node_id]) and not _crosses_layout_road(layout, point, layout.nodes[node_id]):
						nearby_collector = node_id
					break
			else:
				already = true
			if already:
				break
		if already:
			continue
		var chosen: int = nearby_collector
		var shortest := 0.42 if arterial_crossing else 0.27
		for node_id in range(layout.nodes.size()) if chosen < 0 else []:
			if not connected.has(node_id) or connected[node_id] < 2 or not reachable.has(node_id) or layout.arterial_nodes.has(node_id):
				continue
			var interior: Vector2 = layout.nodes[node_id]
			var distance: float = point.distance_to(interior)
			if distance < 0.045 or distance >= shortest or (interior - point).normalized().dot(target["direction"]) < 0.68:
				continue
			if _point_outline_distance(interior, layout.polygon) < 0.035 or not Geography.segment_on_land(layout.polygon, point, interior) or _near_field_arterial(point, interior, field_context, 0.055) or _crosses_layout_road(layout, point, interior):
				continue
			chosen = node_id
			shortest = distance
		if chosen < 0:
			var ray_end: Vector2 = point + target["direction"] * (0.42 if arterial_crossing else 0.35)
			var crossing_edge := -1
			var crossing_point := Vector2.ZERO
			var crossing_distance := point.distance_to(ray_end)
			for edge_id in range(layout.edges.size()):
				if layout.classes[edge_id] == Roads.ARTERIAL:
					continue
				var edge: Vector2 = layout.edges[edge_id]
				if not reachable.has(int(edge.x)) or not reachable.has(int(edge.y)):
					continue
				var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
				for segment in range(1, path.size()):
					var hit = Geometry2D.segment_intersects_segment(point, ray_end, path[segment - 1], path[segment])
					if hit == null:
						continue
					var distance: float = point.distance_to(hit)
					if distance < 0.045 or distance >= crossing_distance or _point_outline_distance(hit, layout.polygon) < 0.035 or not Geography.segment_on_land(layout.polygon, point, hit) or _near_field_arterial(point, hit, field_context, 0.055):
						continue
					crossing_edge = edge_id
					crossing_point = hit
					crossing_distance = distance
			if crossing_edge < 0:
				for edge_id in range(layout.edges.size()):
					if layout.classes[edge_id] == Roads.ARTERIAL:
						continue
					var edge: Vector2 = layout.edges[edge_id]
					if not reachable.has(int(edge.x)) or not reachable.has(int(edge.y)):
						continue
					var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
					for segment in range(1, path.size()):
						var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(point, path[segment - 1], path[segment])
						var distance: float = point.distance_to(nearest)
						if distance < 0.045 or distance >= crossing_distance or (nearest - point).normalized().dot(target["direction"]) < 0.5:
							continue
						if _point_outline_distance(nearest, layout.polygon) < 0.035 or not Geography.segment_on_land(layout.polygon, point, nearest) or _near_field_arterial(point, nearest, field_context, 0.055) or _crosses_layout_road(layout, point, nearest):
							continue
						crossing_edge = edge_id
						crossing_point = nearest
						crossing_distance = distance
			if crossing_edge < 0:
				continue
			chosen = _ensure_street_intersection(layout, crossing_point)
		var boundary_id: int = _ensure_street_intersection(layout, point) if arterial_crossing else layout.nodes.size()
		if not arterial_crossing:
			layout.nodes.append(point)
		elif not layout.arterial_nodes.has(boundary_id):
			layout.arterial_nodes.append(boundary_id)
		if chosen == boundary_id:
			continue
		var road_class: String = Roads.COLLECTOR if target.get("road_class", "") == Roads.COLLECTOR else Roads.LOCAL
		_append_edge(layout, chosen, boundary_id, road_class, 1 if road_class == Roads.COLLECTOR else 2)
		connected[chosen] = int(connected.get(chosen, 0)) + 1
		connected[boundary_id] = 1
		# The short new street occupies land that otherwise belongs to the
		# clipped edge blocks.  Trim those parcels now, before buildings appear.
		var corridor: Array[PackedVector2Array] = Geometry2D.offset_polyline(PackedVector2Array([point, layout.nodes[chosen]]), 0.004, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)
		for block_id in range(layout.blocks.size() - 1, -1, -1):
			var block: Dictionary = layout.blocks[block_id]
			if not Geography._bounds(block["polygon"]).intersects(Geography._bounds(corridor[0])):
				continue
			var fragments: Array[PackedVector2Array] = [block["polygon"]]
			for mask in corridor:
				var remaining: Array[PackedVector2Array] = []
				for fragment in fragments:
					remaining.append_array(Geometry2D.clip_polygons(fragment, mask))
				fragments = remaining
			if fragments.size() == 1 and absf(Geography.polygon_area(fragments[0]) - float(block["area_ha"]) * 0.01) < 0.000001:
				continue
			layout.blocks.remove_at(block_id)
			for fragment in fragments:
				if fragment.size() < 3 or Geography.polygon_area(fragment) < 0.00004 or triangulate(fragment).is_empty():
					continue
				var piece: Dictionary = block.duplicate(true)
				piece["polygon"] = fragment
				piece["area_ha"] = Geography.polygon_area(fragment) * 100.0
				layout.blocks.append(piece)


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
				var forward: bool = int(edge.x) == cursor
				cursor = int(edge.y) if forward else int(edge.x)
				var path: PackedVector2Array = _layout_edge_path(layout, edge_id)
				if not forward:
					path = path.duplicate()
					path.reverse()
				for point_id in range(1, path.size()):
					points.append(path[point_id])
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
