extends RefCounted

const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")
const GridFamily = preload("res://scripts/simulation/grid_family_layout.gd")

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
	var count_x: int = ceili(sqrt(float(neighborhood_ids.size())))
	var count_y: int = ceili(float(neighborhood_ids.size()) / float(count_x))
	var start_x: int = -floori(float(count_x) / 2.0)
	var start_y: int = -floori(float(count_y) / 2.0)
	region.cities[city_id]["urban_start_x"] = start_x
	region.cities[city_id]["urban_start_y"] = start_y
	region.cities[city_id]["urban_count_x"] = count_x
	region.cities[city_id]["urban_count_y"] = count_y
	var best_plan: Dictionary = {}
	var best_score := -1
	for trial in range(12):
		var axis: Vector2 = Vector2.from_angle(float(trial) * PI / 12.0 + float(city_id % 5) * 0.04)
		var proposed: Dictionary = {"axis": axis, "origin": center, "column_spacing": 0.16, "row_spacing": 0.09}
		var score := 0
		for index in range(neighborhood_ids.size()):
			var sector := Vector2i(start_x + index % count_x, start_y + floori(float(index) / float(count_x)))
			for point in sector_outline(proposed, sector, region, city_id):
				if region.jurisdictions[region.city_jurisdiction_ids[city_id]].contains_point(point) and region.jurisdictions[0].contains_point(point):
					score += 1
		if score > best_score:
			best_score = score
			best_plan = proposed
	region.cities[city_id]["street_plan"] = best_plan
	region.cities[city_id]["street_axis"] = best_plan["axis"]
	# The starter fabric is fixed before later player arterials influence the field.
	for index in range(neighborhood_ids.size()):
		var sector := Vector2i(start_x + index % count_x, start_y + floori(float(index) / float(count_x)))
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
	for y in range(min_y, max_y + 1, ROWS):
		var horizontal_corridor_id: int = region.next_road_link_id
		var horizontal_distance := 0.0
		for x in range(min_x, max_x, 4):
			var a := Vector2i(x, y)
			var b := Vector2i(x + 4, y)
			if not node_grid.has(a) or not node_grid.has(b):
				continue
			var length: float = _add_start_arterial(region, city_id, node_grid[a], node_grid[b], horizontal_corridor_id, horizontal_distance)
			horizontal_distance += length
	var vertical_x: int = 0 if 0 >= min_x and 0 <= max_x else min_x
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
		var sector := Vector2i(start_x + index % count_x, start_y + floori(float(index) / float(count_x)))
		var generated: Dictionary = make_layout(region, city_id, sector)
		var layout = generated["layout"]
		if generated["frontage_id"] < 0 or layout.core_paths.is_empty() or layout.blocks.is_empty():
			push_warning("Could not create starting street graph for city %d sector %s" % [city_id, sector])
			continue
		region.urban_sector_claims[sector_key(city_id, sector)] = neighborhood_ids[index]
		for cell in district_cells(region, city_id, sector):
			region.urban_block_claims[block_key(city_id, cell)] = neighborhood_ids[index]
		StreetNetwork.attach(region, region.neighborhoods[neighborhood_ids[index]], layout, true)
		register_layout(region, layout, neighborhood_ids[index], 3)


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
						var point: Vector2 = origin + axis * (float(corner.x) * column_spacing) + normal * (float(corner.y) * row_spacing)
						if not city.contains_point(point) or not state.contains_point(point):
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
	var vertical: bool = posmod(hash("%d:district-seam-axis:%d" % [region.generation_seed, city_id]), 4) != 0
	if vertical:
		var band: int = _sector_for_coordinate(region, city_id, false, group.y)
		var approximate: int = _sector_for_coordinate(region, city_id, true, group.x + 1)
		var local: int = group.y - _sector_boundary(region, city_id, false, band)
		var left: int = _sector_boundary(region, city_id, true, approximate) + _district_seam_shift(region, city_id, true, approximate, band, local)
		if group.x + 1 < left:
			return Vector2i(approximate - 1, band)
		var right: int = _sector_boundary(region, city_id, true, approximate + 1) + _district_seam_shift(region, city_id, true, approximate + 1, band, local)
		return Vector2i(approximate + 1 if group.x + 1 >= right else approximate, band)
	else:
		var band: int = _sector_for_coordinate(region, city_id, true, group.x)
		var approximate: int = _sector_for_coordinate(region, city_id, false, group.y + 1)
		var local: int = group.x - _sector_boundary(region, city_id, true, band)
		var top: int = _sector_boundary(region, city_id, false, approximate) + _district_seam_shift(region, city_id, false, approximate, band, local)
		if group.y + 1 < top:
			return Vector2i(band, approximate - 1)
		var bottom: int = _sector_boundary(region, city_id, false, approximate + 1) + _district_seam_shift(region, city_id, false, approximate + 1, band, local)
		return Vector2i(band, approximate + 1 if group.y + 1 >= bottom else approximate)


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
	layout.bounds = Geography._bounds(layout.polygon)
	var rotated: Dictionary = GridFamily.continue_chart(region, city_id, sector, layout.polygon, GridFamily.separating_chart(region, city_id, layout.polygon, plan))
	if not rotated.is_empty():
		var clipped: Dictionary = GridFamily.fill(layout, plan, rotated, variant, road_context, region.generation_seed)
		if layout.blocks.is_empty() or layout.edges.is_empty():
			return {"layout": layout, "frontage_id": -1}
		var chart_nodes: Dictionary = clipped["node_ids"]
		var chart_boundary: Dictionary = clipped["boundary_nodes"]
		var chart_access: Dictionary = _find_access(region, layout, chart_nodes, chart_boundary)
		var chart_frontage_id: int = int(chart_access.get("link_id", -1))
		if chart_frontage_id < 0:
			return {"layout": layout, "frontage_id": -1}
		for local_id in chart_access.get("node_ids", []):
			layout.arterial_nodes.append(local_id)
		if chart_access.has("connector_point"):
			var anchor_id: int = layout.nodes.size()
			layout.nodes.append(chart_access["connector_point"])
			layout.arterial_nodes.append(anchor_id)
			LayoutGenerator._append_edge(layout, anchor_id, int(chart_access["near_id"]), Roads.COLLECTOR, 1)
		LayoutGenerator._build_core_paths(layout)
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
	var access: Dictionary = _find_access(region, layout, node_ids, boundary_nodes)
	var frontage_id: int = int(access.get("link_id", -1))
	if frontage_id < 0:
		return {"layout": layout, "frontage_id": -1}
	for local_id in access.get("node_ids", []):
		layout.arterial_nodes.append(local_id)
	if access.has("connector_point"):
		var anchor_id: int = layout.nodes.size()
		layout.nodes.append(access["connector_point"])
		layout.arterial_nodes.append(anchor_id)
		LayoutGenerator._append_edge(layout, anchor_id, int(access["near_id"]), Roads.COLLECTOR, 1)
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
			if _covered_by_access_road(region, layout.nodes[first_id], layout.nodes[last_id]) or LayoutGenerator._near_field_arterial(layout.nodes[first_id], layout.nodes[last_id], road_context, 0.075):
				continue
			var road_class: String = Roads.COLLECTOR if collector else Roads.LOCAL
			LayoutGenerator._append_edge(layout, first_id, last_id, road_class, 1 if collector else 2)
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
		LayoutGenerator._append_block_polygon(layout, block_polygon, access_nodes, 2, block_seed, false, false)
		var block: Dictionary = layout.blocks[-1]
		block["canonical_id"] = "%d:%d:%d:%d" % [city_id, cell.x, cell.y, variant]
		layout.blocks[-1] = block
	LayoutGenerator._build_core_paths(layout)
	LayoutGenerator._mark_canonical_edges(layout)
	return {"layout": layout, "frontage_id": frontage_id}


static func _cell_edge_key(first: Vector2i, last: Vector2i) -> String:
	if first.x > last.x or first.x == last.x and first.y > last.y:
		return "%d:%d|%d:%d" % [last.x, last.y, first.x, first.y]
	return "%d:%d|%d:%d" % [first.x, first.y, last.x, last.y]


static func _find_access(region, layout, node_ids: Dictionary, boundary_nodes: Dictionary) -> Dictionary:
	var best_distance := 0.25
	var best_link_id := -1
	var best_point := Vector2.ZERO
	var best_node := -1
	var exact_nodes: Array[int] = []
	for address in boundary_nodes:
		var local_id: int = node_ids[address]
		var point: Vector2 = layout.nodes[local_id]
		for link_index in Spatial.near_links(region, point):
			var link = region.road_links[link_index]
			if link.road_class not in [Roads.ARTERIAL, Roads.COLLECTOR] or link.managed_neighborhood_id >= 0 and region.neighborhoods[link.managed_neighborhood_id].development_plan != null and region.neighborhoods[link.managed_neighborhood_id].development_plan.completed_phase == 0:
				continue
			var projected: Vector2 = RoadPlanner.closest_point(link.points, point)
			var distance: float = point.distance_to(projected)
			if distance < 0.018:
				exact_nodes.append(local_id)
			if distance < best_distance:
				best_distance = distance
				best_link_id = link.id
				best_point = projected
				best_node = local_id
	if best_link_id < 0:
		return {}
	var result: Dictionary = {"link_id": best_link_id, "node_ids": exact_nodes, "near_id": best_node}
	if best_distance >= 0.018:
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
