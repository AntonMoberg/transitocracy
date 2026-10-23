extends RefCounted

const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const StreetLayoutOps = preload("res://scripts/simulation/street_layout_ops.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")
const GridFamily = preload("res://scripts/simulation/grid_family_layout.gd")
const BorderSeams = preload("res://scripts/simulation/city_border_seams.gd")
const RoadTerrain = preload("res://scripts/simulation/road_terrain.gd")

# Absolute city addresses own junctions and blocks. Seeded shared seams
# divide them into connected districts; all designs keep the same perimeter
# roads and through collectors, regardless of approval order.
const COLUMNS = 8
const ROWS = 12


static func build_starting_city(region, city: Dictionary) -> void:
	var neighborhood_ids: Array[int] = []
	for neighborhood_id in city["neighborhood_ids"]:
		if region.neighborhoods[neighborhood_id].initially_developed:
			neighborhood_ids.append(neighborhood_id)
	if neighborhood_ids.is_empty():
		return
	var city_id: int = city["id"]
	var center: Vector2 = city["center_km"]
	var sectors: Array[Vector2i] = _starter_sectors(region.generation_seed, city_id, neighborhood_ids.size())
	var count_x := 0
	var count_y := 0
	for sector in sectors:
		count_x = maxi(count_x, sector.x + 1)
		count_y = maxi(count_y, sector.y + 1)
	var start_x: int = -floori(float(count_x) / 2.0)
	var start_y: int = -floori(float(count_y) / 2.0)
	for index in range(sectors.size()):
		sectors[index] += Vector2i(start_x, start_y)
	region.cities[city_id]["urban_start_x"] = start_x
	region.cities[city_id]["urban_start_y"] = start_y
	region.cities[city_id]["urban_count_x"] = count_x
	region.cities[city_id]["urban_count_y"] = count_y
	region.cities[city_id]["urban_start_sectors"] = sectors
	var best_plan: Dictionary = {}
	var best_score := -1
	var guide: Dictionary = CityPlan.guide(region, city_id, center)
	var angle_offset: int = posmod(hash("%d:starting-angle:%d" % [region.generation_seed, city_id]), 12)
	for trial in range(12):
		var axis: Vector2 = Vector2.from_angle(float((trial + angle_offset) % 12) * PI / 12.0 + float(city_id % 5) * 0.04)
		var proposed: Dictionary = {"axis": axis, "origin": center, "column_spacing": guide["column_spacing"], "row_spacing": guide["row_spacing"]}
		var score := 0
		for sector in sectors:
			for point in sector_outline(proposed, sector, region, city_id):
				if region.jurisdictions[region.city_jurisdiction_ids[city_id]].contains_point(point) and region.jurisdictions[0].contains_point(point):
					score += 1
		if score > best_score:
			best_score = score
			best_plan = proposed
	region.cities[city_id]["street_plan"] = best_plan
	region.cities[city_id]["street_axis"] = best_plan["axis"]
	# The starter fabric is fixed before later player arterials influence the field.
	for sector in sectors:
		for cell in district_cells(region, city_id, sector):
			for corner in [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]:
				var key: String = "%d:%d:%d" % [city_id, corner.x, corner.y]
				region.urban_locked_junctions[key] = CityPlan.base_junction(best_plan, corner)
	var node_grid: Dictionary = {}
	var min_x: int = start_x * COLUMNS
	var max_x: int = (start_x + count_x) * COLUMNS
	var min_y: int = start_y * ROWS
	var max_y: int = (start_y + count_y) * ROWS
	for y in range(min_y, max_y + 1, 4):
		for x in range(min_x, max_x + 1, 4):
			var address := Vector2i(x, y)
			var point: Vector2 = CityPlan.base_junction(best_plan, address)
			if region.jurisdictions[0].contains_point(point):
				node_grid[address] = StreetNetwork.ensure_node(region, point, city_id)
	var horizontal_y: int = (start_y + maxi(1, count_y / 2)) * ROWS if count_y > 1 else (start_y + posmod(hash("%d:starter-side:%d" % [region.generation_seed, city_id]), 2)) * ROWS
	var horizontal_corridor_id: int = region.next_road_link_id
	var horizontal_distance := 0.0
	for x in range(min_x, max_x, 4):
		var a := Vector2i(x, horizontal_y)
		var b := Vector2i(x + 4, horizontal_y)
		if not node_grid.has(a) or not node_grid.has(b):
			continue
		var length: float = _add_start_arterial(region, city_id, node_grid[a], node_grid[b], horizontal_corridor_id, horizontal_distance)
		horizontal_distance += length
	var vertical_x: int = (start_x + maxi(1, count_x / 2)) * COLUMNS if count_x > 1 else (start_x + posmod(hash("%d:starter-end:%d" % [region.generation_seed, city_id]), 2)) * COLUMNS
	var corridor_id: int = region.next_road_link_id
	var distance := 0.0
	for y in range(min_y, max_y, 4):
		var a := Vector2i(vertical_x, y)
		var b := Vector2i(vertical_x, y + 4)
		if not node_grid.has(a) or not node_grid.has(b):
			continue
		var length: float = _add_start_arterial(region, city_id, node_grid[a], node_grid[b], corridor_id, distance)
		distance += length
	region.street_spatial_cache = {}
	for index in range(neighborhood_ids.size()):
		var sector: Vector2i = sectors[index]
		var generated: Dictionary = make_layout(region, city_id, sector)
		var layout = generated["layout"]
		if generated["frontage_id"] < 0 or layout.core_paths.is_empty() or layout.blocks.is_empty():
			push_warning("Could not create starting street graph for city %d sector %s (frontage=%d, paths=%d, blocks=%d)" % [city_id, sector, generated["frontage_id"], layout.core_paths.size(), layout.blocks.size()])
			continue
		region.urban_sector_claims[sector_key(city_id, sector)] = neighborhood_ids[index]
		for cell in district_cells(region, city_id, sector):
			region.urban_block_claims[block_key(city_id, cell)] = neighborhood_ids[index]
		for cell in layout.border_cells:
			region.urban_block_claims[block_key(city_id, cell)] = neighborhood_ids[index]
		StreetNetwork.attach(region, region.neighborhoods[neighborhood_ids[index]], layout, true)
		register_layout(region, layout, neighborhood_ids[index], 3)


static func _starter_sectors(seed_value: int, city_id: int, count: int) -> Array[Vector2i]:
	var shape: Array = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]
	match count:
		2:
			shape = [Vector2i.ZERO, Vector2i.RIGHT]
		3:
			shape = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN] if posmod(hash("%d:starter-shape:%d" % [seed_value, city_id]), 2) == 0 else [Vector2i.ZERO, Vector2i.RIGHT, Vector2i(2, 0)]
		5:
			shape = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i(2, 0), Vector2i.DOWN, Vector2i.ONE]
		6:
			shape = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i(2, 0), Vector2i.DOWN, Vector2i.ONE, Vector2i(2, 1)]
	var turn: int = posmod(hash("%d:starter-turn:%d" % [seed_value, city_id]), 4)
	var minimum := Vector2i(100, 100)
	for index in range(shape.size()):
		var point: Vector2i = shape[index]
		for _step in range(turn):
			point = Vector2i(-point.y, point.x)
		shape[index] = point
		minimum.x = mini(minimum.x, point.x)
		minimum.y = mini(minimum.y, point.y)
	var result: Array[Vector2i] = []
	for point in shape:
		result.append(point - minimum)
	return result


static func register_layout(region, layout, neighborhood_id: int, built_phase: int = 0) -> void:
	for local_id in layout.canonical_nodes:
		var junction_key: String = layout.canonical_nodes[local_id]
		if not region.urban_locked_junctions.has(junction_key):
			region.urban_locked_junctions[junction_key] = layout.nodes[local_id]
	for edge_id in layout.canonical_edges:
		var key: String = layout.canonical_edges[edge_id]
		var edge: Vector2 = layout.edges[edge_id]
		var record: Dictionary = region.urban_plan_edges.get(key, {})
		if record.is_empty():
			record = {
				"from": layout.canonical_nodes[int(edge.x)],
				"to": layout.canonical_nodes[int(edge.y)],
				"points": PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]]),
				"road_class": layout.classes[edge_id],
				"status": "planned",
				"owners": [],
			}
		if not record["owners"].has(neighborhood_id):
			record["owners"].append(neighborhood_id)
		if layout.phases[edge_id] <= built_phase:
			record["status"] = "built"
		region.urban_plan_edges[key] = record


static func mark_built(region, layout, phase: int) -> void:
	for edge_id in layout.canonical_edges:
		if layout.phases[edge_id] > phase:
			continue
		var key: String = layout.canonical_edges[edge_id]
		if not region.urban_plan_edges.has(key):
			continue
		var record: Dictionary = region.urban_plan_edges[key]
		record["status"] = "built"
		region.urban_plan_edges[key] = record


static func _add_start_arterial(region, city_id: int, first_id: int, last_id: int, corridor_id: int, start_km: float) -> float:
	var first: Vector2 = region.road_nodes[first_id].position_km
	var last: Vector2 = region.road_nodes[last_id].position_km
	var link = Roads.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = first_id
	link.to_node_id = last_id
	link.road_class = Roads.ARTERIAL
	link.points = PackedVector2Array([first, last])
	link.corridor_id = corridor_id
	link.corridor_start_km = start_km
	link.owner_jurisdiction_id = region.city_jurisdiction_ids[city_id]
	link.recalculate_length()
	if region.terrain != null:
		link.terrain_spans = RoadTerrain.spans(region, link.points, link.road_class)
	region.road_links.append(link)
	return link.length_km


static func sector_key(city_id: int, sector: Vector2i) -> String:
	return "%d:%d:%d" % [city_id, sector.x, sector.y]


static func block_key(city_id: int, cell: Vector2i) -> String:
	return "%d:%d:%d" % [city_id, cell.x, cell.y]


static func sector_at(point: Vector2, plan: Dictionary, region = null, city_id: int = -1) -> Vector2i:
	var address: Vector2i = CityPlan.address(point, plan)
	if region == null or city_id < 0:
		return Vector2i(floori(float(address.x) / float(COLUMNS)), floori(float(address.y) / float(ROWS)))
	return Vector2i(_sector_for_coordinate(region, city_id, true, address.x), _sector_for_coordinate(region, city_id, false, address.y))


static func sector_outline(plan: Dictionary, sector: Vector2i, region = null, city_id: int = -1) -> PackedVector2Array:
	var first := Vector2i(sector.x * COLUMNS, sector.y * ROWS)
	var last := first + Vector2i(COLUMNS, ROWS)
	if region != null and city_id >= 0:
		first = Vector2i(_sector_boundary(region, city_id, true, sector.x), _sector_boundary(region, city_id, false, sector.y))
		last = Vector2i(_sector_boundary(region, city_id, true, sector.x + 1), _sector_boundary(region, city_id, false, sector.y + 1))
	return PackedVector2Array([
		CityPlan.base_junction(plan, first),
		CityPlan.base_junction(plan, Vector2i(last.x, first.y)),
		CityPlan.base_junction(plan, last),
		CityPlan.base_junction(plan, Vector2i(first.x, last.y)),
	])


# The starting wards retain their original addresses. Outside them, each
# shared seam gets a seeded width in whole pairs of blocks. Every district
# reads the same seam position, regardless of approval order.
static func _sector_boundary(region, city_id: int, horizontal: bool, seam: int) -> int:
	var city: Dictionary = region.cities[city_id]
	var stride: int = COLUMNS if horizontal else ROWS
	var start_key: String = "urban_start_x" if horizontal else "urban_start_y"
	if not city.has(start_key) and not city.has("neighborhood_ids"):
		return seam * stride
	var start: int = int(city.get(start_key, 0))
	var count: int = int(city.get("urban_count_x" if horizontal else "urban_count_y", 0))
	if seam >= start and seam <= start + count:
		return seam * stride
	var position: int = (start + count) * stride if seam > start + count else start * stride
	if seam > start + count:
		for index in range(start + count, seam):
			position += _sector_width(region, city_id, horizontal, index)
	else:
		for index in range(seam, start):
			position -= _sector_width(region, city_id, horizontal, index)
	return position


static func _sector_width(region, city_id: int, horizontal: bool, index: int) -> int:
	var city: Dictionary = region.cities[city_id]
	var caps: Vector2i = city.get("urban_growth_width_caps", Vector2i.ZERO)
	if caps == Vector2i.ZERO:
		var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
		caps = Vector2i(maxi(2, floori(2.95 / (2.0 * float(plan["column_spacing"]))) * 2), maxi(2, floori(2.95 / (2.0 * float(plan["row_spacing"]))) * 2))
		region.cities[city_id]["urban_growth_width_caps"] = caps
	var widths: Array = [2, 4, 6, 8, 8, 10, 12, 14, 14, 16] if horizontal else [4, 6, 8, 10, 12, 12, 16, 20, 24, 24]
	var axis_tag: String = "x" if horizontal else "y"
	return mini(int(widths[posmod(hash("district-width:%d:%d:%s:%d" % [region.generation_seed, city_id, axis_tag, index]), widths.size())]), caps.x if horizontal else caps.y)


static func _sector_for_coordinate(region, city_id: int, horizontal: bool, coordinate: int) -> int:
	var stride: int = COLUMNS if horizontal else ROWS
	var sector: int = floori(float(coordinate) / float(stride))
	while coordinate < _sector_boundary(region, city_id, horizontal, sector):
		sector -= 1
	while coordinate >= _sector_boundary(region, city_id, horizontal, sector + 1):
		sector += 1
	return sector


static func is_buildable(region, city_id: int, sector: Vector2i) -> bool:
	return district_cells(region, city_id, sector).size() >= 8


static func district_cells(region, city_id: int, sector: Vector2i) -> Array[Vector2i]:
	var cache_key: String = sector_key(city_id, sector)
	if region.urban_district_cells.has(cache_key):
		return region.urban_district_cells[cache_key]
	var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var state = region.jurisdictions[0]
	var first := Vector2i(_sector_boundary(region, city_id, true, sector.x), _sector_boundary(region, city_id, false, sector.y))
	var last := Vector2i(_sector_boundary(region, city_id, true, sector.x + 1), _sector_boundary(region, city_id, false, sector.y + 1))
	var axis: Vector2 = plan["axis"]
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = plan["origin"]
	var column_spacing: float = plan["column_spacing"]
	var row_spacing: float = plan["row_spacing"]
	var result: Array[Vector2i] = []
	for y in range(first.y - 6, last.y + 6, 2):
		for x in range(first.x - 6, last.x + 6, 2):
			# A pair of neighboring districts uses the same absolute seam. The
			# seams move only in two-block steps, so roads and claims meet exactly.
			if _district_owner(region, city_id, Vector2i(x, y)) != sector:
				continue
			for dy in range(2):
				for dx in range(2):
					var cell := Vector2i(x + dx, y + dy)
					var valid := true
					for corner in [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]:
						var corner_key := Vector3i(city_id, corner.x, corner.y)
						if not region.urban_valid_junction_cache.has(corner_key):
							var point: Vector2 = origin + axis * (float(corner.x) * column_spacing) + normal * (float(corner.y) * row_spacing)
							region.urban_valid_junction_cache[corner_key] = city.contains_point(point) and state.contains_point(point)
						if not region.urban_valid_junction_cache[corner_key]:
							valid = false
							break
					if valid:
						result.append(cell)
	region.urban_district_cells[cache_key] = result
	return result


# Shared seams resemble the long, mostly regular ward boundaries seen in
# gridded cities. Some jog at a major cross street or make a broad appendage.
# Only alternating seams move. A few new growth bands use a straight,
# two-column compact district; the starting neighborhoods keep their seams.
static func _district_owner(region, city_id: int, group: Vector2i) -> Vector2i:
	var owner_key := Vector3i(city_id, group.x, group.y)
	if region.urban_district_owner_cache.has(owner_key):
		return region.urban_district_owner_cache[owner_key]
	var vertical: bool = posmod(hash("%d:district-seam-axis:%d" % [region.generation_seed, city_id]), 4) != 0
	var result: Vector2i
	if vertical:
		var band: int = _sector_for_coordinate(region, city_id, false, group.y)
		var approximate: int = _sector_for_coordinate(region, city_id, true, group.x + 1)
		var local: int = group.y - _sector_boundary(region, city_id, false, band)
		var left: int = _sector_boundary(region, city_id, true, approximate) + _district_seam_shift(region, city_id, true, approximate, band, local)
		if group.x + 1 < left:
			result = Vector2i(approximate - 1, band)
		else:
			var right: int = _sector_boundary(region, city_id, true, approximate + 1) + _district_seam_shift(region, city_id, true, approximate + 1, band, local)
			result = Vector2i(approximate + 1 if group.x + 1 >= right else approximate, band)
	else:
		var band: int = _sector_for_coordinate(region, city_id, true, group.x)
		var approximate: int = _sector_for_coordinate(region, city_id, false, group.y + 1)
		var local: int = group.x - _sector_boundary(region, city_id, true, band)
		var top: int = _sector_boundary(region, city_id, false, approximate) + _district_seam_shift(region, city_id, false, approximate, band, local)
		if group.y + 1 < top:
			result = Vector2i(band, approximate - 1)
		else:
			var bottom: int = _sector_boundary(region, city_id, false, approximate + 1) + _district_seam_shift(region, city_id, false, approximate + 1, band, local)
			result = Vector2i(band, approximate + 1 if group.y + 1 >= bottom else approximate)
	region.urban_district_owner_cache[owner_key] = result
	return result


static func _district_seam_shift(region, city_id: int, vertical: bool, seam: int, band: int, local: int) -> int:
	var seed_value: int = region.generation_seed
	var before: int = _sector_boundary(region, city_id, vertical, seam) - _sector_boundary(region, city_id, vertical, seam - 1)
	var after: int = _sector_boundary(region, city_id, vertical, seam + 1) - _sector_boundary(region, city_id, vertical, seam)
	var inward_cap: int = mini(4, maxi(0, before - 4))
	var outward_cap: int = mini(4, maxi(0, after - 4))
	inward_cap -= posmod(inward_cap, 2)
	outward_cap -= posmod(outward_cap, 2)
	var phase: int = posmod(hash("%d:district-seam-phase:%d" % [seed_value, city_id]), 2)
	if posmod(seam + phase, 2) != 0:
		return 0
	var tag: String = "%d:%d:%d:%d:%d" % [seed_value, city_id, int(vertical), seam, band]
	var city: Dictionary = region.cities[city_id]
	var start: int = int(city.get("urban_start_y", 0))
	var count: int = int(city.get("urban_count_y", 0))
	var band_height: int = _sector_boundary(region, city_id, false, band + 1) - _sector_boundary(region, city_id, false, band)
	if vertical and city.has("neighborhood_ids") and band_height >= 6 and (band < start or band >= start + count) and posmod(hash("district-compact:%s" % tag), 3) == 0:
		var direction: int = -1 if seam > 0 else 1
		var compact_inward: int = mini(6, maxi(0, before - 2))
		var compact_outward: int = mini(6, maxi(0, after - 2))
		compact_inward -= posmod(compact_inward, 2)
		compact_outward -= posmod(compact_outward, 2)
		return clampi(direction * 6, -compact_inward, compact_outward)
	var shape: int = posmod(hash("district-seam-shape:%s" % tag), 12)
	if shape < 5:
		return clampi((posmod(hash("district-seam-base:%s" % tag), 3) - 1) * 2, -inward_cap, outward_cap)
	var direction: int = -1 if posmod(hash("district-seam-side:%s" % tag), 2) == 0 else 1
	var span: int = _sector_boundary(region, city_id, not vertical, band + 1) - _sector_boundary(region, city_id, not vertical, band)
	var midpoint: int = floori(float(span) * 0.5)
	var cut: int = midpoint - 2 if posmod(hash("district-seam-cut:%s" % tag), 2) == 0 else midpoint + 2
	var shift := 0
	if shape < 9:
		shift = direction * 2 if local >= cut else 0
	else:
		var leading: bool = posmod(hash("district-seam-end:%s" % tag), 2) == 0
		shift = direction * 4 if (local < cut) == leading else 0
	return clampi(shift, -inward_cap, outward_cap)


static func _cell_outline(region, city_id: int, plan: Dictionary, cells: Array[Vector2i], context: Dictionary = {}) -> PackedVector2Array:
	var selected: Dictionary = {}
	for cell in cells:
		selected[cell] = true
	var edges: Dictionary = {}
	for cell in cells:
		if not selected.has(cell + Vector2i.UP):
			edges[cell] = cell + Vector2i.RIGHT
		if not selected.has(cell + Vector2i.RIGHT):
			edges[cell + Vector2i.RIGHT] = cell + Vector2i.ONE
		if not selected.has(cell + Vector2i.DOWN):
			edges[cell + Vector2i.ONE] = cell + Vector2i.DOWN
		if not selected.has(cell + Vector2i.LEFT):
			edges[cell + Vector2i.DOWN] = cell
	if edges.is_empty():
		return PackedVector2Array()
	var start: Vector2i = edges.keys()[0]
	var current: Vector2i = start
	var addresses: Array[Vector2i] = []
	for _index in range(edges.size() + 1):
		if not edges.has(current):
			return PackedVector2Array()
		addresses.append(current)
		current = edges[current]
		if current == start:
			break
	if current != start or addresses.size() != edges.size():
		return PackedVector2Array()
	var path := PackedVector2Array()
	for address in addresses:
		path.append(CityPlan.junction(region, city_id, address, plan, false, context))
	var outline := PackedVector2Array()
	for index in range(path.size()):
		var before: Vector2 = path[(index + path.size() - 1) % path.size()]
		var point: Vector2 = path[index]
		var after: Vector2 = path[(index + 1) % path.size()]
		# Keep the corners in an irregular district seam while removing the
		# redundant nodes along its straight block edges.
		if absf((point - before).cross(after - point)) < 0.0000001:
			continue
		outline.append(point)
	return outline


static func make_layout(region, city_id: int, sector: Vector2i, variant: int = 0) -> Dictionary:
	var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	var layout = Layout.new()
	layout.key = "graph:%s" % sector_key(city_id, sector)
	layout.city_id = city_id
	layout.interior_style = "Grid"
	layout.grid_axis = plan["axis"]
	layout.grid_origin = plan["origin"]
	layout.grid_column_spacing_km = plan["column_spacing"]
	layout.grid_row_spacing_km = plan["row_spacing"]
	var cells: Array[Vector2i] = district_cells(region, city_id, sector)
	var base_bounds: Rect2 = Geography._bounds(sector_outline(plan, sector, region, city_id)).grow(0.85)
	var road_context: Dictionary = DirectionField.city_context(region, city_id, base_bounds)
	layout.polygon = _cell_outline(region, city_id, plan, cells, road_context)
	if layout.polygon.size() < 3 or cells.size() < 8:
		return {"layout": layout, "frontage_id": -1}
	var border: Dictionary = _city_border_envelope(region, city_id, sector, plan, cells, layout.polygon, road_context)
	if not border.is_empty():
		layout.polygon = border["polygon"]
		layout.border_cells = border["cells"]
	layout.bounds = Geography._bounds(layout.polygon)
	var rotated: Dictionary = GridFamily.continue_chart(region, city_id, sector, layout.polygon, GridFamily.separating_chart(region, city_id, layout.polygon, plan))
	if not rotated.is_empty():
		var clipped: Dictionary = GridFamily.fill(layout, plan, rotated, variant, road_context, region.generation_seed)
		if layout.blocks.is_empty() or layout.edges.is_empty():
			return {"layout": layout, "frontage_id": -1}
		var chart_nodes: Dictionary = clipped["node_ids"]
		var chart_boundary: Dictionary = clipped["boundary_nodes"]
		var chart_access: Dictionary = _find_access(region, layout, chart_nodes, chart_boundary, 0.4 if region.cities[city_id].get("urban_start_sectors", []).has(sector) else 0.25)
		var chart_frontage_id: int = int(chart_access.get("link_id", -1))
		if chart_frontage_id < 0:
			return {"layout": layout, "frontage_id": -1}
		for local_id in chart_access.get("node_ids", []):
			layout.arterial_nodes.append(local_id)
		_connect_access_to_collectors(layout, int(chart_access["near_id"]))
		if chart_access.has("connector_point"):
			var anchor_id: int = layout.nodes.size()
			layout.nodes.append(chart_access["connector_point"])
			layout.arterial_nodes.append(anchor_id)
			StreetLayoutOps._append_edge(layout, anchor_id, int(chart_access["near_id"]), Roads.COLLECTOR, 1)
		_connect_local_arterials(region, layout, road_context)
		_prune_redundant_edges(region, layout)
		_connect_access_to_collectors(layout, int(chart_access["near_id"]))
		StreetLayoutOps._build_core_paths(layout)
		StreetLayoutOps._mark_canonical_edges(layout)
		BorderSeams.plan(region, layout)
		BorderSeams.finalize(region, layout)
		_reserve_border_connector_blocks(layout)
		_apply_terrain(region, layout)
		return {"layout": layout, "frontage_id": chart_frontage_id}
	var selected: Dictionary = {}
	var addresses: Dictionary = {}
	for cell in cells:
		selected[cell] = true
		for corner in [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN]:
			addresses[corner] = true
	var node_ids: Dictionary = {}
	for address in addresses:
		var id: int = layout.nodes.size()
		node_ids[address] = id
		layout.nodes.append(CityPlan.junction(region, city_id, address, plan, false, road_context))
		layout.canonical_nodes[id] = "%d:%d:%d" % [city_id, address.x, address.y]
	var boundary_nodes: Dictionary = {}
	for cell in cells:
		if not selected.has(cell + Vector2i.UP):
			boundary_nodes[cell] = true
			boundary_nodes[cell + Vector2i.RIGHT] = true
		if not selected.has(cell + Vector2i.RIGHT):
			boundary_nodes[cell + Vector2i.RIGHT] = true
			boundary_nodes[cell + Vector2i.ONE] = true
		if not selected.has(cell + Vector2i.DOWN):
			boundary_nodes[cell + Vector2i.ONE] = true
			boundary_nodes[cell + Vector2i.DOWN] = true
		if not selected.has(cell + Vector2i.LEFT):
			boundary_nodes[cell + Vector2i.DOWN] = true
			boundary_nodes[cell] = true
	var handled_edges: Dictionary = {}
	var present_roads: Dictionary = {}
	for cell in cells:
		for side in range(4):
			var first: Vector2i = [cell, cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN][side]
			var last: Vector2i = [cell + Vector2i.RIGHT, cell + Vector2i.ONE, cell + Vector2i.DOWN, cell][side]
			var neighbor: Vector2i = cell + [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT][side]
			var edge_key: String = _cell_edge_key(first, last)
			if handled_edges.has(edge_key):
				continue
			handled_edges[edge_key] = true
			var boundary: bool = not selected.has(neighbor)
			var horizontal: bool = first.y == last.y
			var absolute_line: int = first.y if horizontal else first.x
			var collector: bool = posmod(absolute_line, 4) == 0
			var keep: bool = boundary or collector or (variant != (2 if horizontal else 1)) or posmod(absolute_line, 2) == 0
			if not keep:
				continue
			var first_id: int = node_ids[first]
			var last_id: int = node_ids[last]
			if not boundary and not collector and region.terrain != null:
				var street_a: Vector2 = layout.nodes[first_id]
				var street_b: Vector2 = layout.nodes[last_id]
				var street_mid: Vector2 = (street_a + street_b) * 0.5
				var land_slope: float = region.terrain.slope_at(street_mid)
				var street_grade: float = absf(region.terrain.elevation_at(street_a) - region.terrain.elevation_at(street_b)) / maxf(1.0, street_a.distance_to(street_b) * 1000.0)
				if region.terrain.water_at(street_mid) or (land_slope > 0.25 and street_grade > 0.22):
					continue
			if _covered_by_access_road(region, layout.nodes[first_id], layout.nodes[last_id]) or StreetLayoutOps._near_field_arterial(layout.nodes[first_id], layout.nodes[last_id], road_context, 0.075):
				continue
			var road_class: String = Roads.COLLECTOR if collector else Roads.LOCAL
			StreetLayoutOps._append_edge(layout, first_id, last_id, road_class, 1 if collector else 2)
			present_roads[edge_key] = true
	var visited: Dictionary = {}
	for cell in cells:
		if visited.has(cell):
			continue
		var component: Array[Vector2i] = []
		var queue: Array[Vector2i] = [cell]
		visited[cell] = true
		var cursor := 0
		while cursor < queue.size():
			var current: Vector2i = queue[cursor]
			cursor += 1
			component.append(current)
			for side in range(4):
				var neighbor: Vector2i = current + [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT][side]
				if not selected.has(neighbor) or visited.has(neighbor):
					continue
				var a: Vector2i = [current, current + Vector2i.RIGHT, current + Vector2i.ONE, current + Vector2i.DOWN][side]
				var b: Vector2i = [current + Vector2i.RIGHT, current + Vector2i.ONE, current + Vector2i.DOWN, current][side]
				if present_roads.has(_cell_edge_key(a, b)):
					continue
				visited[neighbor] = true
				queue.append(neighbor)
		var block_polygon: PackedVector2Array = _cell_outline(region, city_id, plan, component, road_context)
		if block_polygon.size() < 3:
			continue
		var access_nodes := PackedInt32Array()
		for member in component:
			for corner in [member, member + Vector2i.RIGHT, member + Vector2i.ONE, member + Vector2i.DOWN]:
				var local_id: int = node_ids[corner]
				if not access_nodes.has(local_id):
					access_nodes.append(local_id)
		var block_seed: int = hash("%d:graph-block:%d:%d:%d:%d" % [region.generation_seed, city_id, cell.x, cell.y, variant])
		StreetLayoutOps._append_block_polygon(layout, block_polygon, access_nodes, 2, block_seed, false, false)
		var block: Dictionary = layout.blocks[-1]
		block["canonical_id"] = "%d:%d:%d:%d" % [city_id, cell.x, cell.y, variant]
		layout.blocks[-1] = block
	if not border.is_empty():
		_extend_grid_to_city_border(region, city_id, plan, layout, border["cells"], road_context)
	for local_id in range(layout.nodes.size()):
		if _near_layout_outline(layout.nodes[local_id], layout.polygon, 0.003):
			node_ids[local_id] = local_id
			boundary_nodes[local_id] = true
	var access: Dictionary = _find_access(region, layout, node_ids, boundary_nodes, 0.4 if region.cities[city_id].get("urban_start_sectors", []).has(sector) else 0.25)
	var frontage_id: int = int(access.get("link_id", -1))
	if frontage_id < 0:
		return {"layout": layout, "frontage_id": -1}
	for local_id in access.get("node_ids", []):
		layout.arterial_nodes.append(local_id)
	_connect_access_to_collectors(layout, int(access["near_id"]))
	if access.has("connector_point"):
		var anchor_id: int = layout.nodes.size()
		layout.nodes.append(access["connector_point"])
		layout.arterial_nodes.append(anchor_id)
		StreetLayoutOps._append_edge(layout, anchor_id, int(access["near_id"]), Roads.COLLECTOR, 1)
	_connect_local_arterials(region, layout, road_context)
	_prune_redundant_edges(region, layout)
	_connect_access_to_collectors(layout, int(access["near_id"]))
	StreetLayoutOps._build_core_paths(layout)
	StreetLayoutOps._mark_canonical_edges(layout)
	BorderSeams.plan(region, layout)
	BorderSeams.finalize(region, layout)
	_reserve_border_connector_blocks(layout)
	_apply_terrain(region, layout)
	return {"layout": layout, "frontage_id": frontage_id}


static func _apply_terrain(region, layout) -> void:
	if region.terrain == null:
		return
	var terrain = region.terrain
	var total_slope := 0.0
	var sampled := 0
	for block_id in range(layout.blocks.size()):
		var block: Dictionary = layout.blocks[block_id]
		var polygon: PackedVector2Array = block["polygon"]
		if polygon.size() < 3:
			continue
		var center := Vector2.ZERO
		for vertex in polygon:
			center += vertex
		center /= float(polygon.size())
		total_slope += terrain.slope_at(center)
		sampled += 1
		if terrain.buildable_fraction(polygon, 3) < 0.35:
			block["park"] = true
			layout.blocks[block_id] = block
	if sampled > 0 and total_slope / float(sampled) >= 0.10:
		layout.interior_style = "Hillside"
	for path in layout.core_paths:
		var terrain_impact: Dictionary = RoadTerrain.preview(region, path["points"], Roads.COLLECTOR, true)
		if terrain_impact.get("ok", false):
			layout.phase_costs[int(path["phase"]) - 1] += int(terrain_impact["cost"])


static func _connect_access_to_collectors(layout, access_node: int) -> void:
	# The closest point on an arterial can be a local-only grid junction. One
	# existing street path must join the phase-one collector graph before the
	# district opens, even when the arterial itself needs no new connector.
	var backbone: Dictionary = {}
	var neighbors: Dictionary = {}
	for edge_id in range(layout.edges.size()):
		var edge: Vector2 = layout.edges[edge_id]
		var first: int = int(edge.x)
		var last: int = int(edge.y)
		if layout.classes[edge_id] == Roads.COLLECTOR:
			backbone[first] = true
			backbone[last] = true
		elif layout.classes[edge_id] == Roads.LOCAL:
			if not neighbors.has(first):
				neighbors[first] = []
			if not neighbors.has(last):
				neighbors[last] = []
			neighbors[first].append({"to": last, "edge": edge_id})
			neighbors[last].append({"to": first, "edge": edge_id})
	if backbone.has(access_node) or backbone.is_empty():
		return
	var queue: Array[int] = [access_node]
	var previous: Dictionary = {access_node: {}}
	var cursor := 0
	var target := -1
	while cursor < queue.size():
		var current: int = queue[cursor]
		cursor += 1
		if backbone.has(current):
			target = current
			break
		for next in neighbors.get(current, []):
			var neighbor: int = next["to"]
			if previous.has(neighbor):
				continue
			previous[neighbor] = {"from": current, "edge": next["edge"]}
			queue.append(neighbor)
	if target < 0:
		var closest := -1
		var nearest := 0.6
		for node_id in backbone:
			var distance: float = layout.nodes[access_node].distance_to(layout.nodes[node_id])
			if distance >= nearest:
				continue
			var inside := true
			for fraction in [0.25, 0.5, 0.75]:
				if not Geometry2D.is_point_in_polygon(layout.nodes[access_node].lerp(layout.nodes[node_id], fraction), layout.polygon):
					inside = false
			if inside:
				closest = node_id
				nearest = distance
		if closest >= 0:
			StreetLayoutOps._append_edge(layout, access_node, closest, Roads.COLLECTOR, 1)
		return
	while target >= 0 and target != access_node:
		var step: Dictionary = previous[target]
		var edge_id: int = step["edge"]
		var length: float = layout.lengths[edge_id]
		var old_phase: int = layout.phases[edge_id] - 1
		layout.phase_costs[old_phase] -= roundi(length * Roads.construction_cost(Roads.LOCAL))
		layout.phase_upkeep[old_phase] -= length * Roads.upkeep(Roads.LOCAL)
		layout.classes[edge_id] = Roads.COLLECTOR
		layout.phases[edge_id] = 1
		layout.phase_costs[0] += roundi(length * Roads.construction_cost(Roads.COLLECTOR))
		layout.phase_upkeep[0] += length * Roads.upkeep(Roads.COLLECTOR)
		target = step["from"]


static func _connect_local_arterials(region, layout, road_context: Dictionary) -> void:
	_split_local_arterial_crossings(region, layout)
	var installed := PackedVector2Array()
	var original_count: int = layout.edges.size()
	for edge_id in range(original_count):
		if layout.classes[edge_id] != Roads.LOCAL:
			continue
		var edge: Vector2 = layout.edges[edge_id]
		for end_id in [int(edge.x), int(edge.y)]:
			var other_id: int = int(edge.y) if end_id == int(edge.x) else int(edge.x)
			var point: Vector2 = layout.nodes[end_id]
			var direction: Vector2 = (point - layout.nodes[other_id]).normalized()
			var best_point := Vector2.ZERO
			var best_distance := 0.17
			for link_index in Spatial.near_links(region, point):
				var link = region.road_links[link_index]
				if link.road_class != Roads.ARTERIAL:
					continue
				var projected: Vector2 = RoadPlanner.closest_point(link.points, point)
				var distance: float = point.distance_to(projected)
				if distance >= best_distance or distance > 0.002 and (projected - point).normalized().dot(direction) < 0.7:
					continue
				best_point = projected
				best_distance = distance
			if best_distance >= 0.17:
				continue
			if best_distance >= 0.002 and not _near_layout_outline(point, layout.polygon, 0.03):
				continue
			var connector_middle: Vector2 = (point + best_point) * 0.5
			if best_distance >= 0.002 and Geometry2D.is_point_in_polygon(connector_middle, layout.polygon) and not _near_layout_outline(connector_middle, layout.polygon, 0.03):
				continue
			if best_distance >= 0.002 and StreetLayoutOps._near_field_arterial(point, best_point, road_context, 0.075):
				continue
			var spaced := true
			for previous in installed:
				if previous.distance_to(best_point) < 0.07:
					spaced = false
					break
			if not spaced:
				continue
			installed.append(best_point)
			if best_distance < 0.002:
				if not layout.arterial_nodes.has(end_id):
					layout.arterial_nodes.append(end_id)
			else:
				var anchor_id: int = layout.nodes.size()
				layout.nodes.append(best_point)
				layout.arterial_nodes.append(anchor_id)
				StreetLayoutOps._append_edge(layout, end_id, anchor_id, Roads.LOCAL, 2)


static func _split_local_arterial_crossings(region, layout) -> void:
	var original_count: int = layout.edges.size()
	for edge_id in range(original_count * 3):
		if edge_id >= layout.edges.size():
			break
		if layout.classes[edge_id] != Roads.LOCAL or layout.edge_paths.has(edge_id):
			continue
		var edge: Vector2 = layout.edges[edge_id]
		var first_id: int = int(edge.x)
		var last_id: int = int(edge.y)
		var first: Vector2 = layout.nodes[first_id]
		var last: Vector2 = layout.nodes[last_id]
		var candidates: Dictionary = {}
		for probe in [first, (first + last) * 0.5, last]:
			for link_index in Spatial.near_links(region, probe):
				candidates[link_index] = true
		var best_hit = null
		var best_score := INF
		for link_index in candidates:
			var link = region.road_links[link_index]
			if link.road_class != Roads.ARTERIAL:
				continue
			for segment in range(1, link.points.size()):
				var road_first: Vector2 = link.points[segment - 1]
				var road_last: Vector2 = link.points[segment]
				if absf((last - first).normalized().cross((road_last - road_first).normalized())) < 0.28:
					continue
				var hit = Geometry2D.segment_intersects_segment(first, last, road_first, road_last)
				if hit == null or hit.distance_to(first) < 0.025 or hit.distance_to(last) < 0.025:
					continue
				var score: float = hit.distance_to((first + last) * 0.5)
				if score < best_score:
					best_score = score
					best_hit = hit
		if best_hit == null:
			continue
		var crossing_id: int = layout.nodes.size()
		layout.nodes.append(best_hit)
		layout.arterial_nodes.append(crossing_id)
		layout.canonical_nodes[crossing_id] = "%d:arterial-cross:%d:%d" % [layout.city_id, roundi(best_hit.x * 1000.0), roundi(best_hit.y * 1000.0)]
		var old_length: float = layout.lengths[edge_id]
		var first_length: float = first.distance_to(best_hit)
		var last_length: float = best_hit.distance_to(last)
		var phase: int = layout.phases[edge_id]
		layout.edges[edge_id] = Vector2(first_id, crossing_id)
		layout.lengths[edge_id] = first_length
		layout.edges.append(Vector2(crossing_id, last_id))
		layout.classes.append(Roads.LOCAL)
		layout.phases.append(phase)
		layout.lengths.append(last_length)
		layout.phase_costs[phase - 1] += roundi(first_length * Roads.construction_cost(Roads.LOCAL)) + roundi(last_length * Roads.construction_cost(Roads.LOCAL)) - roundi(old_length * Roads.construction_cost(Roads.LOCAL))
		layout.phase_upkeep[phase - 1] += (first_length + last_length - old_length) * Roads.upkeep(Roads.LOCAL)


static func _near_layout_outline(point: Vector2, outline: PackedVector2Array, reach: float) -> bool:
	for index in range(outline.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[index], outline[(index + 1) % outline.size()])) <= reach:
			return true
	return false


# Clip the complete sector lattice to the city once. The old cell-by-cell
# fringe merge depended on iteration order and on a nearby road node, leaving
# broad triangular holes wherever the municipal line crossed the grid.
static func _city_border_envelope(region, city_id: int, sector: Vector2i, plan: Dictionary, core_cells: Array[Vector2i], core_outline: PackedVector2Array, context: Dictionary) -> Dictionary:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var near_border := false
	for vertex in core_outline:
		for edge_id in range(city.polygon_km.size()):
			if vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, city.polygon_km[edge_id], city.polygon_km[(edge_id + 1) % city.polygon_km.size()])) < 0.65:
				near_border = true
				break
		if near_border:
			break
	if not near_border:
		return {}
	var full: Dictionary = {}
	for cell in core_cells:
		full[cell] = true
	var fringe_cells: Array[Vector2i] = []
	var adopted: Dictionary = {}
	for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor: Vector2i = sector + step
		var neighbor_outline: PackedVector2Array = sector_outline(plan, neighbor, region, city_id)
		if not Geography._bounds(neighbor_outline).grow(0.75).intersects(city.bounds_km):
			continue
		var wholly_inside := true
		for corner in neighbor_outline:
			if not city.contains_point(corner):
				wholly_inside = false
				break
		if wholly_inside:
			continue
		if district_cells(region, city_id, neighbor).size() >= 8:
			continue
		if _residual_parent(region, city_id, neighbor, plan, context) == sector:
			for member in region.urban_sector_merge_members.get(sector_key(city_id, sector), []):
				adopted[member] = true
	var first := Vector2i(_sector_boundary(region, city_id, true, sector.x), _sector_boundary(region, city_id, false, sector.y))
	var last := Vector2i(_sector_boundary(region, city_id, true, sector.x + 1), _sector_boundary(region, city_id, false, sector.y + 1))
	for neighbor in adopted:
		first.x = mini(first.x, _sector_boundary(region, city_id, true, neighbor.x))
		first.y = mini(first.y, _sector_boundary(region, city_id, false, neighbor.y))
		last.x = maxi(last.x, _sector_boundary(region, city_id, true, neighbor.x + 1))
		last.y = maxi(last.y, _sector_boundary(region, city_id, false, neighbor.y + 1))
	for y in range(first.y - 6, last.y + 6):
		for x in range(first.x - 6, last.x + 6):
			var cell := Vector2i(x, y)
			var owner: Vector2i = _district_owner(region, city_id, Vector2i(x - posmod(x, 2), y - posmod(y, 2)))
			if owner != sector and not adopted.has(owner):
				continue
			if full.has(cell):
				continue
			var quad := _grid_cell_quad(region, city_id, cell, plan, context)
			if not Geography._bounds(quad).intersects(city.bounds_km):
				continue
			for piece in Geometry2D.intersect_polygons(quad, city.polygon_km):
				if Geography.polygon_area(piece) >= 0.000015:
					fringe_cells.append(cell)
					break
	if fringe_cells.is_empty():
		return {}
	var candidates: Dictionary = full.duplicate()
	for cell in fringe_cells:
		candidates[cell] = true
	var connected: Dictionary = {}
	var queue: Array[Vector2i] = core_cells.duplicate()
	for cell in core_cells:
		connected[cell] = true
	var cursor := 0
	while cursor < queue.size():
		var current: Vector2i = queue[cursor]
		cursor += 1
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor: Vector2i = current + step
			if candidates.has(neighbor) and not connected.has(neighbor):
				connected[neighbor] = true
				queue.append(neighbor)
	var all_cells: Array[Vector2i] = queue
	var sector_outline_clipped: PackedVector2Array = _cell_outline(region, city_id, plan, all_cells, context)
	if sector_outline_clipped.size() < 3:
		return {}
	var chosen := PackedVector2Array()
	var greatest_overlap := 0.0
	for piece in Geometry2D.intersect_polygons(sector_outline_clipped, city.polygon_km):
		var overlap := 0.0
		for shared in Geometry2D.intersect_polygons(piece, core_outline):
			overlap += Geography.polygon_area(shared)
		if overlap > greatest_overlap:
			greatest_overlap = overlap
			chosen = piece
	if greatest_overlap < Geography.polygon_area(core_outline) * 0.98 or Geography.polygon_area(chosen) < Geography.polygon_area(core_outline) + 0.000015:
		return {}
	var connected_fringe: Array[Vector2i] = []
	for cell in fringe_cells:
		var quad: PackedVector2Array = _grid_cell_quad(region, city_id, cell, plan, context)
		for piece in Geometry2D.intersect_polygons(quad, chosen):
			if Geography.polygon_area(piece) >= 0.000015:
				connected_fringe.append(cell)
				break
	return {"polygon": chosen, "cells": connected_fringe}


# Connected border scraps too small to approve on their own belong to one
# neighboring district. Treat them as a group so a second scrap cannot be
# stranded behind the first one while its separately chosen parent is dormant.
static func _residual_parent(region, city_id: int, small: Vector2i, plan: Dictionary, context: Dictionary) -> Vector2i:
	var key: String = sector_key(city_id, small)
	if region.urban_sector_merges.has(key):
		return region.urban_sector_merges[key]
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var component: Array[Vector2i] = _residual_component(region, city_id, small, plan)
	if component.is_empty():
		region.urban_sector_merges[key] = Vector2i(2147483647, 2147483647)
		return region.urban_sector_merges[key]
	var members: Dictionary = {}
	for member in component:
		members[member] = true
	var scores: Dictionary = {}
	for member in component:
		var first := Vector2i(_sector_boundary(region, city_id, true, member.x), _sector_boundary(region, city_id, false, member.y))
		var last := Vector2i(_sector_boundary(region, city_id, true, member.x + 1), _sector_boundary(region, city_id, false, member.y + 1))
		for y in range(first.y - 6, last.y + 6):
			for x in range(first.x - 6, last.x + 6):
				var cell := Vector2i(x, y)
				if _district_owner(region, city_id, Vector2i(x - posmod(x, 2), y - posmod(y, 2))) != member:
					continue
				var quad: PackedVector2Array = _grid_cell_quad(region, city_id, cell, plan, context)
				if not Geography._bounds(quad).intersects(city.bounds_km):
					continue
				var land: bool = city.contains_point((quad[0] + quad[2]) * 0.5)
				if not land:
					for corner in quad:
						if city.contains_point(corner):
							land = true
							break
				if not land:
					continue
				for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var other: Vector2i = cell + step
					var owner: Vector2i = _district_owner(region, city_id, Vector2i(other.x - posmod(other.x, 2), other.y - posmod(other.y, 2)))
					if members.has(owner):
						continue
					var side: int = 0 if step == Vector2i.UP else (1 if step == Vector2i.RIGHT else (2 if step == Vector2i.DOWN else 3))
					for fraction in [0.25, 0.5, 0.75]:
						if city.contains_point(quad[side].lerp(quad[(side + 1) % 4], fraction)):
							scores[owner] = float(scores.get(owner, 0.0)) + quad[side].distance_to(quad[(side + 1) % 4]) / 3.0
	var best := Vector2i(2147483647, 2147483647)
	var best_score := 0.0
	for owner in scores:
		if district_cells(region, city_id, owner).size() < 8:
			continue
		var score: float = scores[owner]
		if score > best_score + 0.0001 or is_equal_approx(score, best_score) and str(owner) < str(best):
			best = owner
			best_score = score
	for member in component:
		region.urban_sector_merges[sector_key(city_id, member)] = best
	if best != Vector2i(2147483647, 2147483647):
		var group_key: String = sector_key(city_id, best)
		var group: Array = region.urban_sector_merge_members.get(group_key, [])
		for member in component:
			if not group.has(member):
				group.append(member)
		region.urban_sector_merge_members[group_key] = group
	return best


static func _residual_component(region, city_id: int, first: Vector2i, plan: Dictionary) -> Array[Vector2i]:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var state = region.jurisdictions[0]
	var component: Array[Vector2i] = []
	var pending: Array[Vector2i] = [first]
	var seen: Dictionary = {first: true}
	var cursor := 0
	while cursor < pending.size():
		var sector: Vector2i = pending[cursor]
		cursor += 1
		var outline: PackedVector2Array = sector_outline(plan, sector, region, city_id)
		if not Geography._bounds(outline).grow(0.75).intersects(city.bounds_km):
			continue
		var wholly_inside := true
		for point in outline:
			if not city.contains_point(point) or not state.contains_point(point):
				wholly_inside = false
				break
		if wholly_inside:
			continue
		var complete_cells: int = district_cells(region, city_id, sector).size()
		if complete_cells >= 8:
			continue
		if complete_cells == 0 and not _residual_has_partial_land(region, city_id, sector, plan, city):
			continue
		component.append(sector)
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor: Vector2i = sector + step
			if not seen.has(neighbor):
				seen[neighbor] = true
				pending.append(neighbor)
	return component


static func _residual_has_partial_land(region, city_id: int, sector: Vector2i, plan: Dictionary, city) -> bool:
	var first := Vector2i(_sector_boundary(region, city_id, true, sector.x), _sector_boundary(region, city_id, false, sector.y))
	var last := Vector2i(_sector_boundary(region, city_id, true, sector.x + 1), _sector_boundary(region, city_id, false, sector.y + 1))
	for y in range(first.y - 6, last.y + 6):
		for x in range(first.x - 6, last.x + 6):
			var cell := Vector2i(x, y)
			if _district_owner(region, city_id, Vector2i(x - posmod(x, 2), y - posmod(y, 2))) != sector:
				continue
			var quad := PackedVector2Array([
				CityPlan.base_junction(plan, cell),
				CityPlan.base_junction(plan, cell + Vector2i.RIGHT),
				CityPlan.base_junction(plan, cell + Vector2i.ONE),
				CityPlan.base_junction(plan, cell + Vector2i.DOWN),
			])
			if not Geography._bounds(quad).intersects(city.bounds_km):
				continue
			for piece in Geometry2D.intersect_polygons(quad, city.polygon_km):
				if Geography.polygon_area(piece) >= 0.000015:
					return true
	return false


static func _grid_cell_quad(region, city_id: int, cell: Vector2i, plan: Dictionary, context: Dictionary) -> PackedVector2Array:
	return PackedVector2Array([
		CityPlan.junction(region, city_id, cell, plan, false, context),
		CityPlan.junction(region, city_id, cell + Vector2i.RIGHT, plan, false, context),
		CityPlan.junction(region, city_id, cell + Vector2i.ONE, plan, false, context),
		CityPlan.junction(region, city_id, cell + Vector2i.DOWN, plan, false, context),
	])


static func _point_key(point: Vector2) -> String:
	return "%d:%d" % [roundi(point.x * 10000.0), roundi(point.y * 10000.0)]


static func _segment_key(first: Vector2, last: Vector2) -> String:
	var a: String = _point_key(first)
	var b: String = _point_key(last)
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]


static func _on_city_outline(point: Vector2, city) -> bool:
	for index in range(city.polygon_km.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, city.polygon_km[index], city.polygon_km[(index + 1) % city.polygon_km.size()])) < 0.002:
			return true
	return false


static func _border_neighbors(region, city_id: int, bounds: Rect2) -> Array[int]:
	var result: Array[int] = []
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	for other_id in range(region.cities.size()):
		if other_id == city_id:
			continue
		var other = region.jurisdictions[region.city_jurisdiction_ids[other_id]]
		if city.bounds_km.grow(0.03).intersects(other.bounds_km) and bounds.grow(0.03).intersects(other.bounds_km):
			result.append(other_id)
	return result


static func _on_shared_city_border(region, city_id: int, first: Vector2, last: Vector2, neighbors: Array[int]) -> bool:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var middle: Vector2 = (first + last) * 0.5
	if not _on_city_outline(middle, city):
		return false
	var normal: Vector2 = (last - first).normalized().orthogonal() * 0.02
	var first_side: Vector2 = middle + normal
	var second_side: Vector2 = middle - normal
	var first_inside: bool = city.contains_point(first_side)
	var second_inside: bool = city.contains_point(second_side)
	if first_inside == second_inside:
		return false
	var outside: Vector2 = second_side if first_inside else first_side
	for other_id in neighbors:
		if region.jurisdictions[region.city_jurisdiction_ids[other_id]].contains_point(outside):
			return true
	return false


static func _extend_grid_to_city_border(region, city_id: int, plan: Dictionary, layout, fringe_cells: Array[Vector2i], context: Dictionary) -> void:
	var neighbors: Array[int] = _border_neighbors(region, city_id, layout.bounds)
	var node_ids: Dictionary = {}
	var road_keys: Dictionary = {}
	var active_nodes: Dictionary = {}
	for node_id in range(layout.nodes.size()):
		node_ids[_point_key(layout.nodes[node_id])] = node_id
	for edge in layout.edges:
		road_keys[_segment_key(layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])] = true
		active_nodes[int(edge.x)] = true
		active_nodes[int(edge.y)] = true
	var axis: Vector2 = plan["axis"]
	var normal: Vector2 = axis.orthogonal()
	for cell in fringe_cells:
		var quad: PackedVector2Array = _grid_cell_quad(region, city_id, cell, plan, context)
		for piece in Geometry2D.intersect_polygons(quad, layout.polygon):
			if Geography.polygon_area(piece) < 0.000015:
				continue
			var vertex_ids := PackedInt32Array()
			for point in piece:
				var key: String = _point_key(point)
				if not node_ids.has(key):
					var new_id: int = layout.nodes.size()
					node_ids[key] = new_id
					layout.nodes.append(point)
					layout.canonical_nodes[new_id] = "%d:border:%s" % [city_id, key]
				vertex_ids.append(node_ids[key])
			for index in range(piece.size()):
				var first: Vector2 = piece[index]
				var last: Vector2 = piece[(index + 1) % piece.size()]
				var midpoint: Vector2 = (first + last) * 0.5
				var length: float = first.distance_to(last)
				if length < 0.015 or _on_shared_city_border(region, city_id, first, last, neighbors):
					continue
				var key: String = _segment_key(first, last)
				if road_keys.has(key):
					continue
				var direction: Vector2 = (last - first) / length
				var horizontal: bool = absf(direction.dot(axis)) > 0.999
				var vertical: bool = absf(direction.dot(normal)) > 0.999
				if not horizontal and not vertical:
					continue
				var line: int = roundi((midpoint - plan["origin"]).dot(normal) / float(plan["row_spacing"])) if horizontal else roundi((midpoint - plan["origin"]).dot(axis) / float(plan["column_spacing"]))
				var road_class: String = Roads.COLLECTOR if posmod(line, 4) == 0 else Roads.LOCAL
				if _covered_by_access_road(region, first, last) or StreetLayoutOps._near_field_arterial(first, last, context, 0.075):
					continue
				StreetLayoutOps._append_edge(layout, vertex_ids[index], vertex_ids[(index + 1) % piece.size()], road_class, 1 if road_class == Roads.COLLECTOR else 2)
				road_keys[key] = true
				active_nodes[vertex_ids[index]] = true
				active_nodes[vertex_ids[(index + 1) % piece.size()]] = true
			var access_id := -1
			var nearest := INF
			var center := Vector2.ZERO
			for point in piece:
				center += point
			center /= float(piece.size())
			for id in active_nodes:
				var distance: float = layout.nodes[id].distance_squared_to(center)
				if distance < nearest:
					nearest = distance
					access_id = id
			if access_id < 0:
				continue
			StreetLayoutOps._append_block_polygon(layout, piece, PackedInt32Array([access_id]), 2, hash("%d:border-fringe:%d:%d:%d" % [region.generation_seed, city_id, cell.x, cell.y]), false, true)


static func _prune_redundant_edges(region, layout) -> void:
	var neighbors: Array[int] = _border_neighbors(region, layout.city_id, layout.bounds)
	var full_context: Dictionary = DirectionField.city_context(region, layout.city_id, layout.bounds)
	var kept_edges := PackedVector2Array()
	var kept_classes := PackedStringArray()
	var kept_phases := PackedInt32Array()
	var kept_lengths := PackedFloat32Array()
	var kept_paths: Dictionary = {}
	for index in range(layout.edges.size()):
		var edge: Vector2 = layout.edges[index]
		var first: Vector2 = layout.nodes[int(edge.x)]
		var last: Vector2 = layout.nodes[int(edge.y)]
		var redundant_local: bool = layout.classes[index] == Roads.LOCAL and StreetLayoutOps._near_field_arterial(first, last, full_context, 0.075)
		if _on_shared_city_border(region, layout.city_id, first, last, neighbors) or redundant_local:
			if layout.classes[index] != Roads.ARTERIAL:
				layout.phase_costs[layout.phases[index] - 1] -= roundi(layout.lengths[index] * Roads.construction_cost(layout.classes[index]))
				layout.phase_upkeep[layout.phases[index] - 1] -= layout.lengths[index] * Roads.upkeep(layout.classes[index])
			continue
		var new_index: int = kept_edges.size()
		kept_edges.append(edge)
		kept_classes.append(layout.classes[index])
		kept_phases.append(layout.phases[index])
		kept_lengths.append(layout.lengths[index])
		if layout.edge_paths.has(index):
			kept_paths[new_index] = layout.edge_paths[index]
	layout.edges = kept_edges
	layout.classes = kept_classes
	layout.phases = kept_phases
	layout.lengths = kept_lengths
	layout.edge_paths = kept_paths
	layout.canonical_edges.clear()


static func _reserve_border_connector_blocks(layout) -> void:
	var masks: Array[PackedVector2Array] = []
	for seam in layout.border_seams:
		var anchor: int = int(seam["anchor"])
		if anchor < 0:
			continue
		var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
		masks.append_array(Geometry2D.offset_polyline(PackedVector2Array([layout.nodes[anchor], middle]), 0.014, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND))
	if masks.is_empty():
		return
	var blocks: Array[Dictionary] = []
	for block in layout.blocks:
		var block_bounds: Rect2 = Geography._bounds(block["polygon"])
		var nearby_masks: Array[PackedVector2Array] = []
		for mask in masks:
			if block_bounds.intersects(Geography._bounds(mask)):
				nearby_masks.append(mask)
		if nearby_masks.is_empty():
			blocks.append(block)
			continue
		var fragments: Array[PackedVector2Array] = [block["polygon"]]
		for mask in nearby_masks:
			var remaining: Array[PackedVector2Array] = []
			for fragment in fragments:
				remaining.append_array(Geometry2D.clip_polygons(fragment, mask))
			fragments = remaining
		for fragment in fragments:
			var area: float = Geography.polygon_area(fragment)
			if area < 0.000015:
				continue
			var part: Dictionary = block.duplicate()
			part["polygon"] = fragment
			part["area_ha"] = area * 100.0
			blocks.append(part)
	layout.blocks = blocks


static func _cell_edge_key(first: Vector2i, last: Vector2i) -> String:
	if first.x > last.x or first.x == last.x and first.y > last.y:
		return "%d:%d|%d:%d" % [last.x, last.y, first.x, first.y]
	return "%d:%d|%d:%d" % [first.x, first.y, last.x, last.y]


static func _find_access(region, layout, node_ids: Dictionary, boundary_nodes: Dictionary, reach_km: float = 0.25) -> Dictionary:
	var best_distance: float = reach_km + 0.01
	var best_link_id := -1
	var best_point := Vector2.ZERO
	var best_node := -1
	var exact_nodes: Array[int] = []
	var street_nodes: Dictionary = {}
	for edge in layout.edges:
		street_nodes[int(edge.x)] = true
		street_nodes[int(edge.y)] = true
	for address in boundary_nodes:
		var local_id: int = node_ids[address]
		if not street_nodes.has(local_id):
			continue
		var point: Vector2 = layout.nodes[local_id]
		for link_index in Spatial.near_links(region, point):
			var link = region.road_links[link_index]
			if link.road_class not in [Roads.ARTERIAL, Roads.COLLECTOR] or link.managed_neighborhood_id >= 0 and region.neighborhoods[link.managed_neighborhood_id].development_plan != null and region.neighborhoods[link.managed_neighborhood_id].development_plan.completed_phase == 0:
				continue
			var projected: Vector2 = RoadPlanner.closest_point(link.points, point)
			var distance: float = point.distance_to(projected)
			if distance > reach_km and link.border_city_ids.x < 0:
				continue
			if distance < 0.002:
				exact_nodes.append(local_id)
			if distance < best_distance:
				best_distance = distance
				best_link_id = link.id
				best_point = projected
				best_node = local_id
	if best_link_id < 0:
		return {}
	var result: Dictionary = {"link_id": best_link_id, "node_ids": exact_nodes, "near_id": best_node}
	if best_distance >= 0.002:
		result["connector_point"] = best_point
	elif exact_nodes.is_empty():
		result["node_ids"] = [best_node]
	return result


static func _covered_by_access_road(region, first: Vector2, last: Vector2) -> bool:
	var midpoint: Vector2 = (first + last) * 0.5
	for link_index in Spatial.near_links(region, midpoint):
		var link = region.road_links[link_index]
		if link.road_class not in [Roads.ARTERIAL, Roads.COLLECTOR]:
			continue
		if RoadPlanner.closest_point(link.points, first).distance_to(first) < 0.012 and RoadPlanner.closest_point(link.points, last).distance_to(last) < 0.012:
			return true
	return false
