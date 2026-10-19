extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const StreetLayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")


static func generate(region) -> void:
	region.road_geometry_revision += 1
	region.street_spatial_cache = {}
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.city_hub_node_ids.clear()
	region.city_highway_access_node_ids.clear()
	region.city_route_node_ids.clear()
	region.neighborhood_development_connected.clear()
	region.neighborhood_spoke_link_ids.clear()
	region.next_road_link_id = 0
	region.next_road_project_id = 0
	for neighborhood in region.neighborhoods:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = neighborhood.position_km
		node.kind = "Neighborhood"
		node.neighborhood_id = neighborhood.id
		node.city_id = neighborhood.city_id
		region.road_nodes.append(node)
		region.neighborhood_gateway_node_ids.append(node.id)
		region.neighborhood_spoke_link_ids.append(-1)
	for city in region.cities:
		var hub = RoadNodeData.new()
		hub.id = region.road_nodes.size()
		hub.position_km = city["center_km"]
		hub.kind = "City"
		hub.city_id = city["id"]
		hub.is_interchange = false
		region.road_nodes.append(hub)
		region.city_hub_node_ids.append(hub.id)
		region.city_highway_access_node_ids.append(-1)
	for city in region.cities:
		_build_city_arterials(region, city)
	_build_starting_highways(region)
	for link in region.road_links:
		if link.road_class != RoadLinkData.COLLECTOR:
			link.owner_jurisdiction_id = region.road_owner_for_points(link.points, link.road_class)
	# Connector arterials and highway exits were appended after the starting
	# city grids. Their indices must be built from the complete graph.
	region.street_spatial_cache = {}


static func _build_starting_highways(region) -> void:
	if region.starting_city_ids.is_empty():
		return
	var centers: Array[Vector2] = []
	var mean := Vector2.ZERO
	for city_id in region.starting_city_ids:
		var center: Vector2 = region.cities[city_id]["center_km"]
		centers.append(center)
		mean += center
	mean /= float(centers.size())
	var axis := Vector2.RIGHT
	var largest_span := -1.0
	for first in range(centers.size()):
		for last in range(first + 1, centers.size()):
			var span: float = centers[first].distance_squared_to(centers[last])
			if span > largest_span:
				largest_span = span
				axis = (centers[last] - centers[first]).normalized()
	if axis.x < 0.0 or (absf(axis.x) < 0.001 and axis.y < 0.0):
		axis = -axis
	var normal := axis.orthogonal()
	var ordered: Array[int] = region.starting_city_ids.duplicate()
	ordered.sort_custom(func(first: int, last: int) -> bool:
		return (region.cities[first]["center_km"] - mean).dot(axis) < (region.cities[last]["center_km"] - mean).dot(axis))
	var options: Array = []
	var intrinsic_costs: Array = []
	for city_index in range(ordered.size()):
		var city_id: int = ordered[city_index]
		var center: Vector2 = region.cities[city_id]["center_km"]
		var before_center: Vector2 = region.cities[ordered[maxi(0, city_index - 1)]]["center_km"]
		var after_center: Vector2 = region.cities[ordered[mini(ordered.size() - 1, city_index + 1)]]["center_km"]
		var local_axis: Vector2 = (after_center - before_center).normalized()
		var local_normal: Vector2 = local_axis.orthogonal() if local_axis != Vector2.ZERO else normal
		var sites: Array[Vector2] = []
		var site_costs: Array[float] = []
		for offset in [-24.0, -16.0, -10.0, -6.0, 6.0, 10.0, 16.0, 24.0]:
			# Each city chooses a nearby side of the regional road independently.
			# This avoids long spurs and lets the corridor go around intervening cores.
			var projection: Vector2 = center + local_normal * float(offset)
			var site: Vector2 = _land_spine_site(region, projection, local_normal, center)
			if not _outside_starter_districts(region, site, 1.5) or sites.has(site):
				continue
			sites.append(site)
			site_costs.append(site.distance_to(projection) * 0.3 + site.distance_to(center) * 0.15)
		if sites.is_empty():
			sites.append(_land_spine_site(region, center + local_normal * 32.0, local_normal, center))
			site_costs.append(100.0)
		options.append(sites)
		intrinsic_costs.append(site_costs)
	var costs: Array = []
	var parents: Array = []
	for city_index in range(ordered.size()):
		var row: Array[float] = []
		var back := PackedInt32Array()
		for site_index in range(options[city_index].size()):
			var cost: float = intrinsic_costs[city_index][site_index]
			var parent := -1
			if city_index > 0:
				var best_edge := INF
				for previous_index in range(options[city_index - 1].size()):
					var first: Vector2 = options[city_index - 1][previous_index]
					var last: Vector2 = options[city_index][site_index]
					var edge_cost: float = costs[city_index - 1][previous_index] + first.distance_to(last)
					if first.distance_to(last) < 0.2 or not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, first, last):
						edge_cost += 100.0
					if _segment_crosses_starter(region, first, last):
						edge_cost += 5000.0
					if edge_cost < best_edge:
						best_edge = edge_cost
						parent = previous_index
				cost += best_edge
			row.append(cost)
			back.append(parent)
		costs.append(row)
		parents.append(back)
	var last_index := 0
	for index in range(1, costs[-1].size()):
		if costs[-1][index] < costs[-1][last_index]:
			last_index = index
	var best_sites: Array[Vector2] = []
	best_sites.resize(ordered.size())
	for city_index in range(ordered.size() - 1, -1, -1):
		best_sites[city_index] = options[city_index][last_index]
		last_index = parents[city_index][last_index]
	var spine_ids: Array[int] = []
	for site in best_sites:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = site
		node.kind = "Highway"
		node.city_id = region.city_id_at_point(site)
		region.road_nodes.append(node)
		spine_ids.append(node.id)
	for index in range(1, spine_ids.size()):
		var before: Vector2 = best_sites[maxi(0, index - 2)]
		var first: Vector2 = best_sites[index - 1]
		var last: Vector2 = best_sites[index]
		var after: Vector2 = best_sites[mini(best_sites.size() - 1, index + 1)]
		var from_tangent: Vector2 = (last - before).normalized()
		var to_tangent: Vector2 = (after - first).normalized()
		_add_link(region, spine_ids[index - 1], spine_ids[index], RoadLinkData.HIGHWAY, 2, from_tangent, to_tangent)
	var arterial_nodes: Dictionary = {}
	for link in region.road_links:
		if link.road_class != RoadLinkData.ARTERIAL:
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			var city_id: int = region.road_nodes[node_id].city_id
			if not arterial_nodes.has(city_id):
				arterial_nodes[city_id] = {}
			arterial_nodes[city_id][node_id] = true
	for index in range(ordered.size()):
		var city_id: int = ordered[index]
		var center: Vector2 = region.cities[city_id]["center_km"]
		var spine_point: Vector2 = best_sites[index]
		var service_point: Vector2 = spine_point
		var connector_node: int = _arterial_connector_node(region, city_id, service_point, arterial_nodes.get(city_id, {}))
		if center.distance_to(spine_point) > 12.0 or connector_node < 0:
			var choice: Dictionary = _service_exit_choice(region, city_id, spine_point, arterial_nodes.get(city_id, {}))
			service_point = choice["point"]
			connector_node = choice["arterial_node"]
		var access_id: int = spine_ids[index]
		if service_point.distance_to(spine_point) > 0.05:
			var exit_node = RoadNodeData.new()
			exit_node.id = region.road_nodes.size()
			exit_node.position_km = service_point
			exit_node.city_id = region.city_id_at_point(service_point)
			exit_node.is_interchange = true
			exit_node.interchange_owner_jurisdiction_id = _highway_owner_at(region, service_point)
			region.road_nodes.append(exit_node)
			access_id = exit_node.id
			region.road_nodes[spine_ids[index]].is_interchange = true
			region.road_nodes[spine_ids[index]].interchange_owner_jurisdiction_id = _highway_owner_at(region, spine_point)
			_add_link(region, spine_ids[index], access_id, RoadLinkData.HIGHWAY, 2)
		else:
			region.road_nodes[access_id].is_interchange = true
			region.road_nodes[access_id].interchange_owner_jurisdiction_id = _highway_owner_at(region, service_point)
		region.city_highway_access_node_ids[city_id] = access_id
		if connector_node < 0:
			connector_node = region.city_hub_node_ids[city_id]
		if connector_node != access_id:
			_add_link(region, connector_node, access_id, RoadLinkData.ARTERIAL, 1)


static func _land_spine_site(region, target: Vector2, normal: Vector2, fallback: Vector2) -> Vector2:
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	if Geometry2D.is_point_in_polygon(target, land) and _outside_starter_districts(region, target, 1.5):
		return target
	var best := Vector2.INF
	var best_score := INF
	for radius in [6.0, 10.0, 16.0, 24.0, 32.0, 48.0]:
		for turn in range(0, 360, 15):
			var trial: Vector2 = fallback + normal.rotated(deg_to_rad(float(turn))) * float(radius)
			if not Geometry2D.is_point_in_polygon(trial, land) or not _outside_starter_districts(region, trial, 1.5):
				continue
			var score: float = trial.distance_to(target) + trial.distance_to(fallback) * 0.05
			if score < best_score:
				best = trial
				best_score = score
	if best.is_finite():
		return best
	return fallback


static func _segment_crosses_starter(region, first: Vector2, last: Vector2) -> bool:
	const clearance := 1.5
	var segment_bounds := Rect2(first, Vector2.ZERO).expand(last).grow(clearance)
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed or neighborhood.street_layout == null:
			continue
		var layout = neighborhood.street_layout
		if not segment_bounds.intersects(layout.bounds.grow(clearance)):
			continue
		var polygon: PackedVector2Array = layout.polygon
		if Geometry2D.is_point_in_polygon(first, polygon) or Geometry2D.is_point_in_polygon(last, polygon):
			return true
		for edge in range(polygon.size()):
			var edge_first: Vector2 = polygon[edge]
			var edge_last: Vector2 = polygon[(edge + 1) % polygon.size()]
			if Geometry2D.segment_intersects_segment(first, last, edge_first, edge_last) != null:
				return true
			if edge_first.distance_to(Geometry2D.get_closest_point_to_segment(edge_first, first, last)) < clearance:
				return true
			if minf(first.distance_to(Geometry2D.get_closest_point_to_segment(first, edge_first, edge_last)), last.distance_to(Geometry2D.get_closest_point_to_segment(last, edge_first, edge_last))) < clearance:
				return true
	return false


static func _service_exit_choice(region, city_id: int, spine_point: Vector2, arterial_nodes: Dictionary) -> Dictionary:
	var center: Vector2 = region.cities[city_id]["center_km"]
	var direction: Vector2 = (spine_point - center).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	var best_point: Vector2 = center
	var best_node := -1
	var best_score := INF
	for radius in [3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0]:
		for turn in [0.0, -15.0, 15.0, -30.0, 30.0, -45.0, 45.0, -60.0, 60.0]:
			var point: Vector2 = center + direction.rotated(deg_to_rad(float(turn))) * float(radius)
			if not Geometry2D.is_point_in_polygon(point, land) or not _outside_starter_districts(region, point, 0.4):
				continue
			var arterial_node: int = _arterial_connector_node(region, city_id, point, arterial_nodes)
			if arterial_node < 0:
				continue
			var score: float = point.distance_to(spine_point) * 0.15 + point.distance_to(region.road_nodes[arterial_node].position_km) + absf(float(turn)) * 0.015
			if score < best_score:
				best_score = score
				best_point = point
				best_node = arterial_node
	if best_node >= 0:
		return {"point": best_point, "arterial_node": best_node}
	return {"point": spine_point, "arterial_node": region.city_hub_node_ids[city_id]}


static func _arterial_connector_node(region, city_id: int, point: Vector2, candidates: Dictionary) -> int:
	var best_id := -1
	var best_distance := INF
	for key in candidates:
		var node_id: int = int(key)
		var from_point: Vector2 = region.road_nodes[node_id].position_km
		var distance: float = from_point.distance_to(point)
		if distance >= best_distance or distance < 0.001 or distance > 16.0:
			continue
		if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, from_point, point):
			continue
		if _connector_crosses_starter(region, from_point, point):
			continue
		best_id = node_id
		best_distance = distance
	return best_id


static func _connector_crosses_starter(region, first: Vector2, last: Vector2) -> bool:
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed or neighborhood.street_layout == null:
			continue
		var polygon: PackedVector2Array = neighborhood.street_layout.polygon
		for fraction in [0.08, 0.2, 0.4, 0.6, 0.8]:
			if Geometry2D.is_point_in_polygon(first.lerp(last, float(fraction)), polygon):
				return true
	return false


static func _outside_starter_districts(region, point: Vector2, clearance: float) -> bool:
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed or neighborhood.street_layout == null:
			continue
		var polygon: PackedVector2Array = neighborhood.street_layout.polygon
		if Geometry2D.is_point_in_polygon(point, polygon):
			return false
		for edge in range(polygon.size()):
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[edge], polygon[(edge + 1) % polygon.size()])) < clearance:
				return false
	return true


static func _highway_owner_at(region, point: Vector2) -> int:
	return region.road_owner_for_points(PackedVector2Array([point, point + Vector2(0.001, 0.0)]), RoadLinkData.HIGHWAY)


static func _build_city_arterials(region, city: Dictionary) -> void:
	var neighborhood_ids: Array[int] = []
	for neighborhood_id in city["neighborhood_ids"]:
		if region.neighborhoods[neighborhood_id].initially_developed:
			neighborhood_ids.append(neighborhood_id)
	if neighborhood_ids.is_empty():
		return
	var city_id: int = city["id"]
	var area = region.jurisdictions[city["jurisdiction_id"]]
	var hub_id: int = region.city_hub_node_ids[city_id]
	var center: Vector2 = region.road_nodes[hub_id].position_km
	if neighborhood_ids.size() > 4:
		center = area.center_km
		city["center_km"] = center
		region.road_nodes[hub_id].position_km = center
		preload("res://scripts/simulation/street_spatial_index.gd").index_node(preload("res://scripts/simulation/street_spatial_index.gd").cache(region), region.road_nodes[hub_id])
	var columns: int = ceili(sqrt(float(neighborhood_ids.size())))
	var rows: int = ceili(float(neighborhood_ids.size()) / columns)
	var district_area: float = StreetLayoutGenerator.FRONTAGE_KM * StreetLayoutGenerator.DEPTH_KM * 2.0
	var aspect: float = 1.35 + float(posmod(hash("%d:district-aspect:%d" % [region.generation_seed, city_id]), 100)) / 100.0 * 0.4
	var span: float = sqrt(district_area * aspect)
	var depth: float = district_area / span
	var axis := Vector2.RIGHT
	var best_score := -1
	for attempt in range(12):
		var trial := Vector2.from_angle(float(attempt) * PI / 12.0 + float(city_id % 7) * 0.1)
		var normal := Vector2(-trial.y, trial.x)
		var score := 0
		for across in [-0.5, 0.5]:
			for along in [-0.5, 0.5]:
				if area.contains_point(center + trial * across * columns * span + normal * along * rows * depth):
					score += 1
		if score > best_score:
			best_score = score
			axis = trial
	var normal := Vector2(-axis.y, axis.x)
	var trunk_column: int = columns / 2
	var trunk_row: int = rows / 2
	var arterial_rows: Array[int] = []
	for row in range(rows + 1):
		if posmod(row - trunk_row, 2) == 0:
			arterial_rows.append(row)
	var shape_rng := RandomNumberGenerator.new()
	shape_rng.seed = hash("%d:city-streets:%d" % [region.generation_seed, city_id])
	var column_offsets: Dictionary = {trunk_column: 0.0}
	for column in range(trunk_column + 1, columns + 2):
		column_offsets[column] = float(column_offsets[column - 1]) + span * shape_rng.randf_range(0.82, 1.18)
	for column in range(trunk_column - 1, -2, -1):
		column_offsets[column] = float(column_offsets[column + 1]) - span * shape_rng.randf_range(0.82, 1.18)
	var row_offsets: Dictionary = {trunk_row: 0.0}
	for row in range(trunk_row + 1, rows + 2):
		row_offsets[row] = float(row_offsets[row - 1]) + depth * shape_rng.randf_range(0.82, 1.18)
	for row in range(trunk_row - 1, -2, -1):
		row_offsets[row] = float(row_offsets[row + 1]) - depth * shape_rng.randf_range(0.82, 1.18)
	var grid: Dictionary = {}
	var positions: Dictionary = {}
	var horizontal: Dictionary = {}
	var vertical: Dictionary = {}
	var built_horizontal: Dictionary = {}
	var built_vertical: Dictionary = {}
	for row in range(-1, rows + 2):
		for column in range(-1, columns + 2):
			var point: Vector2 = center + axis * float(column_offsets[column]) + normal * float(row_offsets[row])
			if column >= 0 and column <= columns and row >= 0 and row <= rows and column != trunk_column and not arterial_rows.has(row):
				# Move only collector-grid junctions. Each district keeps simple, shared
				# straight sides, while the resulting quadrilaterals stay irregular.
				var corner_rng := RandomNumberGenerator.new()
				corner_rng.seed = hash("%d:starter-corner:%d:%d:%d" % [region.generation_seed, city_id, column, row])
				point += axis * span * corner_rng.randf_range(0.07, 0.11) * (-1.0 if corner_rng.randi_range(0, 1) == 0 else 1.0)
				point += normal * depth * corner_rng.randf_range(0.07, 0.11) * (-1.0 if corner_rng.randi_range(0, 1) == 0 else 1.0)
			positions[Vector2i(column, row)] = point
			if column != trunk_column and not arterial_rows.has(row):
				continue
			if not region.jurisdictions[0].contains_point(point):
				continue
			grid[Vector2i(column, row)] = StreetNetwork.ensure_node(region, point, city_id)
	for row in range(-1, rows + 2):
		var corridor_id: int = region.next_road_link_id
		var station := 0.0
		for column in range(-1, columns + 1):
			var first := Vector2i(column, row)
			var second := Vector2i(column + 1, row)
			var first_point: Vector2 = positions[first]
			var second_point: Vector2 = positions[second]
			var points := PackedVector2Array([first_point, second_point])
			horizontal[first] = points
			if not arterial_rows.has(row):
				continue
			if not grid.has(first) or not grid.has(second):
				continue
			if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, first_point, second_point):
				continue
			_add_street_arterial(region, grid[first], grid[second], corridor_id, station, points)
			station += region.road_links[-1].length_km
			built_horizontal[first] = true
	for column in range(-1, columns + 2):
		var corridor_id: int = region.next_road_link_id
		var station := 0.0
		for row in range(-1, rows + 1):
			var first := Vector2i(column, row)
			var second := Vector2i(column, row + 1)
			var first_point: Vector2 = positions[first]
			var second_point: Vector2 = positions[second]
			var points := PackedVector2Array([first_point, second_point])
			vertical[first] = points
			if column != trunk_column:
				continue
			if not grid.has(first) or not grid.has(second):
				continue
			if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, first_point, second_point):
				continue
			_add_street_arterial(region, grid[first], grid[second], corridor_id, station, points)
			station += region.road_links[-1].length_km
			built_vertical[first] = true
	for local_id in range(neighborhood_ids.size()):
		var address := Vector2i(local_id % columns, local_id / columns)
		if not horizontal.has(address) or not horizontal.has(address + Vector2i.DOWN) or not vertical.has(address) or not vertical.has(address + Vector2i.RIGHT):
			continue
		var key: String = "starter:%d:%d" % [city_id, local_id]
		var boundaries: Array = [horizontal[address], vertical[address + Vector2i.RIGHT], horizontal[address + Vector2i.DOWN], vertical[address]]
		var arterial_sides := PackedByteArray([int(built_horizontal.has(address)), int(built_vertical.has(address + Vector2i.RIGHT)), int(built_horizontal.has(address + Vector2i.DOWN)), int(built_vertical.has(address))])
		var layout = StreetLayoutGenerator.generate(region, city_id, horizontal[address], key, [], true, boundaries, arterial_sides)
		if layout.polygon.size() >= 3:
			StreetNetwork.attach(region, region.neighborhoods[neighborhood_ids[local_id]], layout, true)
	if not grid.values().has(hub_id):
		var nearest_id := -1
		var nearest_distance := INF
		for node_id in grid.values():
			var distance: float = region.road_nodes[node_id].position_km.distance_to(center)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_id = node_id
		if nearest_id >= 0:
			_add_link(region, hub_id, nearest_id, RoadLinkData.ARTERIAL, 1)


static func _add_street_arterial(region, first: int, last: int, corridor_id: int, station: float, points: PackedVector2Array) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = first
	link.to_node_id = last
	link.road_class = RoadLinkData.ARTERIAL
	link.points = points
	link.corridor_id = corridor_id
	link.corridor_start_km = station
	link.owner_jurisdiction_id = region.city_jurisdiction_ids[region.road_nodes[first].city_id]
	link.recalculate_length()
	region.road_links.append(link)




static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int, from_tangent: Vector2 = Vector2.ZERO, to_tangent: Vector2 = Vector2.ZERO, land_certified: bool = false) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.corridor_id = link.id
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = RoadRouteBuilder.build(region, from_id, to_id, road_class, PackedVector2Array(), from_tangent, to_tangent, land_certified)
	link.recalculate_length()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points, road_class)
	region.road_links.append(link)
