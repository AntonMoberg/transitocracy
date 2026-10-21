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

# Addresses, rather than development boundaries, own every junction and block.
# All three designs have the same two-cell perimeter and the same through
# collectors. Choosing a design can therefore never move a future connection.
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
	var best_plan: Dictionary = {}
	var best_score := -1
	for trial in range(12):
		var axis: Vector2 = Vector2.from_angle(float(trial) * PI / 12.0 + float(city_id % 5) * 0.04)
		var proposed: Dictionary = {"axis": axis, "origin": center, "column_spacing": 0.16, "row_spacing": 0.09}
		var score := 0
		for index in range(neighborhood_ids.size()):
			var sector := Vector2i(start_x + index % count_x, start_y + floori(float(index) / float(count_x)))
			for point in sector_outline(proposed, sector):
				if region.jurisdictions[region.city_jurisdiction_ids[city_id]].contains_point(point) and region.jurisdictions[0].contains_point(point):
					score += 1
		if score > best_score:
			best_score = score
			best_plan = proposed
	region.cities[city_id]["street_plan"] = best_plan
	region.cities[city_id]["street_axis"] = best_plan["axis"]
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
		StreetNetwork.attach(region, region.neighborhoods[neighborhood_ids[index]], layout, true)
		register_layout(region, layout, neighborhood_ids[index], 3)


static func register_layout(region, layout, neighborhood_id: int, built_phase: int = 0) -> void:
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


static func sector_at(point: Vector2, plan: Dictionary) -> Vector2i:
	var address: Vector2i = CityPlan.address(point, plan)
	return Vector2i(floori(float(address.x) / float(COLUMNS)), floori(float(address.y) / float(ROWS)))


static func sector_outline(plan: Dictionary, sector: Vector2i) -> PackedVector2Array:
	var first := Vector2i(sector.x * COLUMNS, sector.y * ROWS)
	return PackedVector2Array([
		CityPlan.base_junction(plan, first),
		CityPlan.base_junction(plan, first + Vector2i(COLUMNS, 0)),
		CityPlan.base_junction(plan, first + Vector2i(COLUMNS, ROWS)),
		CityPlan.base_junction(plan, first + Vector2i(0, ROWS)),
	])


static func is_buildable(region, city_id: int, sector: Vector2i) -> bool:
	var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	var outline: PackedVector2Array = sector_outline(plan, sector)
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	for corner in outline:
		if not city.contains_point(corner) or not region.jurisdictions[0].contains_point(corner):
			return false
	return true


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
	layout.polygon = sector_outline(plan, sector)
	layout.bounds = Geography._bounds(layout.polygon)
	var first := Vector2i(sector.x * COLUMNS, sector.y * ROWS)
	var road_context: Dictionary = DirectionField.city_context(region, city_id, layout.bounds)
	var columns: Array[int] = []
	var rows: Array[int] = []
	for x in range(COLUMNS + 1):
		if _keep_line(x, COLUMNS, first.x + x, variant == 1):
			columns.append(x)
	for y in range(ROWS + 1):
		if _keep_line(y, ROWS, first.y + y, variant == 2):
			rows.append(y)
	var node_ids: Dictionary = {}
	for y in rows:
		for x in columns:
			var address := first + Vector2i(x, y)
			var id: int = layout.nodes.size()
			node_ids[Vector2i(x, y)] = id
			layout.nodes.append(CityPlan.base_junction(plan, address))
			layout.canonical_nodes[id] = "%d:%d:%d" % [city_id, address.x, address.y]
	var access: Dictionary = _find_access(region, layout, node_ids, columns, rows)
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
	for y in rows:
		for index in range(columns.size() - 1):
			var x0: int = columns[index]
			var x1: int = columns[index + 1]
			var left: int = node_ids[Vector2i(x0, y)]
			var right: int = node_ids[Vector2i(x1, y)]
			if _covered_by_access_road(region, layout.nodes[left], layout.nodes[right]) or LayoutGenerator._near_field_arterial(layout.nodes[left], layout.nodes[right], road_context, 0.075):
				continue
			var road_class: String = Roads.COLLECTOR if posmod(first.y + y, 4) == 0 else Roads.LOCAL
			LayoutGenerator._append_edge(layout, left, right, road_class, 1 if road_class == Roads.COLLECTOR else 2)
	for x in columns:
		for index in range(rows.size() - 1):
			var y0: int = rows[index]
			var y1: int = rows[index + 1]
			var top: int = node_ids[Vector2i(x, y0)]
			var bottom: int = node_ids[Vector2i(x, y1)]
			if _covered_by_access_road(region, layout.nodes[top], layout.nodes[bottom]) or LayoutGenerator._near_field_arterial(layout.nodes[top], layout.nodes[bottom], road_context, 0.075):
				continue
			var road_class: String = Roads.COLLECTOR if posmod(first.x + x, 4) == 0 else Roads.LOCAL
			LayoutGenerator._append_edge(layout, top, bottom, road_class, 1 if road_class == Roads.COLLECTOR else 2)
	for yi in range(rows.size() - 1):
		for xi in range(columns.size() - 1):
			var a: Vector2i = Vector2i(columns[xi], rows[yi])
			var b: Vector2i = Vector2i(columns[xi + 1], rows[yi + 1])
			var corners := PackedInt32Array([node_ids[a], node_ids[Vector2i(b.x, a.y)], node_ids[b], node_ids[Vector2i(a.x, b.y)]])
			var seed_value: int = hash("%d:graph-block:%d:%d:%d:%d" % [region.generation_seed, city_id, first.x + a.x, first.y + a.y, variant])
			LayoutGenerator._append_block(layout, corners, 2, seed_value, false)
			var block: Dictionary = layout.blocks[-1]
			block["canonical_id"] = "%d:%d:%d:%d:%d" % [city_id, first.x + a.x, first.y + a.y, b.x - a.x, b.y - a.y]
			layout.blocks[-1] = block
	LayoutGenerator._build_core_paths(layout)
	LayoutGenerator._mark_canonical_edges(layout)
	return {"layout": layout, "frontage_id": frontage_id}


static func _keep_line(local: int, maximum: int, absolute: int, skip_inner: bool) -> bool:
	if local <= 2 or local >= maximum - 2 or posmod(absolute, 4) == 0:
		return true
	return not skip_inner or posmod(local, 2) == 0


static func _find_access(region, layout, node_ids: Dictionary, columns: Array[int], rows: Array[int]) -> Dictionary:
	var best_distance := 0.25
	var best_link_id := -1
	var best_point := Vector2.ZERO
	var best_node := -1
	var exact_nodes: Array[int] = []
	for y in rows:
		for x in columns:
			if x != 0 and x != COLUMNS and y != 0 and y != ROWS:
				continue
			var local_id: int = node_ids[Vector2i(x, y)]
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
