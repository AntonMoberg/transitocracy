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
	var arterial_nodes: Dictionary = {}
	for link in region.road_links:
		if link.road_class != RoadLinkData.ARTERIAL:
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			var city_id: int = region.road_nodes[node_id].city_id
			if not arterial_nodes.has(city_id):
				arterial_nodes[city_id] = {}
			arterial_nodes[city_id][node_id] = true
	var state_bounds: Rect2 = region.jurisdictions[0].bounds_km
	var first_x: float = maxf(state_bounds.position.x + 10.0, _starting_x_limit(region, true))
	var last_x: float = minf(state_bounds.end.x - 10.0, _starting_x_limit(region, false))
	var ordered: Array[int] = region.starting_city_ids.duplicate()
	ordered.sort_custom(func(a: int, b: int) -> bool: return region.cities[a]["center_km"].y < region.cities[b]["center_km"].y)
	# Balance the cities between two trunks. A largest-gap split can strand
	# nearly all cities on one highway and require very long arterial feeders.
	var split_index: int = clampi(roundi(float(ordered.size()) * 0.5), 2, ordered.size() - 2)
	var bands: Array = [ordered.slice(0, split_index), ordered.slice(split_index)]
	var trunk_nodes: Array = []
	var access_options: Dictionary = {}
	for band_index in range(bands.size()):
		var band: Array = bands[band_index]
		var target_y: float = region.cities[band[band.size() / 2]]["center_km"].y
		var stations: Array = []
		for station in range(ceili((last_x - first_x) / 35.0) + 1):
			stations.append({"x": lerpf(first_x, last_x, float(station) / float(maxi(1, ceili((last_x - first_x) / 35.0)))), "city": -1, "cross": -1})
		# Both trunks offer city-longitude exits where useful. Avoid inserting
		# nearly coincident stations for cities assigned to the other trunk.
		for city_id in region.starting_city_ids:
			if not band.has(city_id):
				var adjacent_access := false
				for band_city_id in band:
					if absf(region.cities[city_id]["center_km"].x - region.cities[band_city_id]["center_km"].x) < 18.0:
						adjacent_access = true
						break
				if adjacent_access:
					continue
			stations.append({"x": region.cities[city_id]["center_km"].x, "city": city_id if band.has(city_id) else -1, "access_city": city_id})
		stations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["x"] < b["x"])
		var sparse_stations: Array = []
		for entry in stations:
			if int(entry.get("access_city", -1)) < 0:
				var near_access := false
				for other in stations:
					if int(other.get("access_city", -1)) >= 0 and absf(float(other["x"]) - float(entry["x"])) < 18.0:
						near_access = true
						break
				if near_access:
					continue
			sparse_stations.append(entry)
		stations = sparse_stations
		var sites: Array[Vector2] = _corridor_sites(region, stations, target_y, band)
		var ids: Array[int] = []
		for station_index in range(stations.size()):
			var entry: Dictionary = stations[station_index]
			var site: Vector2 = sites[station_index]
			var node = RoadNodeData.new()
			node.id = region.road_nodes.size()
			node.position_km = site
			node.kind = "Highway"
			node.city_id = region.city_id_at_point(site)
			region.road_nodes.append(node)
			ids.append(node.id)
			if int(entry.get("access_city", -1)) >= 0:
				var access_city: int = entry["access_city"]
				if not access_options.has(access_city):
					access_options[access_city] = []
				access_options[access_city].append(node.id)
		for index in range(1, ids.size()):
			var trunk_corridor_id: int = region.next_road_link_id if index == 1 else region.road_links[-1].corridor_id
			var first: Vector2 = sites[index - 1]
			var last: Vector2 = sites[index]
			if first.distance_to(last) < 0.2:
				continue
			var before: Vector2 = sites[maxi(0, index - 2)]
			var after: Vector2 = sites[mini(sites.size() - 1, index + 1)]
			_add_link(region, ids[index - 1], ids[index], RoadLinkData.HIGHWAY, 2, (last - before).normalized(), (after - first).normalized())
			region.road_links[-1].corridor_id = trunk_corridor_id
		trunk_nodes.append(ids)
	_connect_highway_bands(region, trunk_nodes[0], trunk_nodes[1], first_x, last_x)
	for city_id in region.starting_city_ids:
		var center: Vector2 = region.cities[city_id]["center_km"]
		var access_id := -1
		var shortest := INF
		for option_id in access_options.get(city_id, []):
			var site: Vector2 = region.road_nodes[option_id].position_km
			var distance: float = center.distance_to(site)
			if distance < shortest:
				shortest = distance
				access_id = option_id
		region.city_highway_access_node_ids[city_id] = access_id
		region.road_nodes[access_id].is_interchange = true
		region.road_nodes[access_id].interchange_owner_jurisdiction_id = _highway_owner_at(region, region.road_nodes[access_id].position_km)
		var connector_node: int = _arterial_connector_node(region, city_id, region.road_nodes[access_id].position_km, arterial_nodes.get(city_id, {}))
		if connector_node < 0:
			connector_node = region.city_hub_node_ids[city_id]
		_add_link(region, connector_node, access_id, RoadLinkData.ARTERIAL, 1)


static func _connect_highway_bands(region, north_nodes: Array, south_nodes: Array, first_x: float, last_x: float) -> void:
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	var span: float = last_x - first_x
	var candidates: Array[Dictionary] = []
	for north_id in north_nodes:
		var north: Vector2 = region.road_nodes[north_id].position_km
		for south_id in south_nodes:
			var south: Vector2 = region.road_nodes[south_id].position_km
			var run: float = south.x - north.x
			if run < span * 0.06 or run > span * 0.32:
				continue
			var rise: float = south.y - north.y
			if rise < 30.0 or rise < run * 1.3:
				continue
			var cross_direction: Vector2 = (south - north).normalized()
			if absf(cross_direction.cross(_trunk_tangent(region, north_nodes, north_id))) < 0.57 or absf(cross_direction.cross(_trunk_tangent(region, south_nodes, south_id))) < 0.57:
				continue
			if not StateGeography.segment_on_land(land, north, south) or _segment_crosses_starter(region, north, south):
				continue
			var middle_x: float = (north.x + south.x) * 0.5
			var score: float = absf(run - rise * 1.1) + absf(middle_x - (first_x + last_x) * 0.5) * 0.3 + north.distance_to(south) * 0.03
			candidates.append({"north": north_id, "south": south_id, "score": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] < b["score"])
	for candidate in candidates:
		var first_id: int = candidate["north"]
		var last_id: int = candidate["south"]
		var direction: Vector2 = (region.road_nodes[last_id].position_km - region.road_nodes[first_id].position_km).normalized()
		_add_link(region, first_id, last_id, RoadLinkData.HIGHWAY, 2, direction, direction, true)
		var link = region.road_links[-1]
		var clear := true
		for segment in range(1, link.points.size()):
			if _segment_crosses_starter(region, link.points[segment - 1], link.points[segment]):
				clear = false
				break
		if not clear:
			region.road_links.pop_back()
			region.next_road_link_id -= 1
			continue
		for node_id in [first_id, last_id]:
			region.road_nodes[node_id].is_interchange = true
			region.road_nodes[node_id].interchange_owner_jurisdiction_id = _highway_owner_at(region, region.road_nodes[node_id].position_km)
		return
	assert(false, "The two starter highways need one clear diagonal connection.")


static func _trunk_tangent(region, node_ids: Array, node_id: int) -> Vector2:
	var index: int = node_ids.find(node_id)
	var before: Vector2 = region.road_nodes[node_ids[maxi(0, index - 1)]].position_km
	var after: Vector2 = region.road_nodes[node_ids[mini(node_ids.size() - 1, index + 1)]].position_km
	return (after - before).normalized()


static func _starting_x_limit(region, first: bool) -> float:
	var limit: float = INF if first else -INF
	for city_id in region.starting_city_ids:
		var x: float = region.cities[city_id]["center_km"].x
		limit = minf(limit, x) if first else maxf(limit, x)
	return limit


static func _corridor_sites(region, stations: Array, target_y: float, band: Array) -> Array[Vector2]:
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	# At each eastward station, keep several inland alternatives. The cheapest
	# connected sequence favors gentle bends and passes near its assigned cities.
	var candidates: Array = []
	var costs: Array = []
	var parents: Array = []
	var previous_x := -INF
	for station_index in range(stations.size()):
		var entry: Dictionary = stations[station_index]
		var x: float = maxf(float(entry["x"]), previous_x + 5.0)
		entry["x"] = x
		previous_x = x
		var city_id: int = entry["city"]
		var city_y: float = region.cities[city_id]["center_km"].y if city_id >= 0 else target_y
		var local_y := target_y
		var influence := 0.0
		for nearby_id in band:
			var nearby: Vector2 = region.cities[nearby_id]["center_km"]
			var weight: float = maxf(0.0, 1.0 - absf(x - nearby.x) / 115.0)
			local_y += (nearby.y - target_y) * weight
			influence += weight
		if influence > 1.0:
			local_y = target_y + (local_y - target_y) / influence
		var ys: Array[float] = [target_y]
		for offset in [8.0, 16.0, 24.0, 36.0, 48.0, 64.0, 80.0, 104.0, 136.0, 176.0, 224.0, 280.0]:
			ys.append(target_y - offset)
			ys.append(target_y + offset)
		if city_id >= 0:
			for offset in [-32.0, -20.0, -12.0, -6.0, 6.0, 12.0, 20.0, 32.0]:
				ys.append(city_y + offset)
		var row: Array[Vector2] = []
		for y in ys:
			var point := Vector2(x, y)
			if Geometry2D.is_point_in_polygon(point, land) and RoadRouteBuilder.clearance_to_coast(land, point) >= 2.0 and _outside_starter_districts(region, point, 1.5):
				row.append(point)
		if row.is_empty():
			row.append(_land_spine_site(region, Vector2(x, target_y), Vector2.DOWN, Vector2(x, target_y)))
		candidates.append(row)
		var row_costs: Array[float] = []
		var row_parents := PackedInt32Array()
		for point in row:
			var intrinsic: float = absf(point.y - target_y) * 0.04 + absf(point.y - local_y) * 1.2 + (absf(point.y - city_y) * 1.5 if city_id >= 0 else 0.0)
			var best_cost := intrinsic
			var best_parent := -1
			if station_index > 0:
				best_cost = INF
				for previous_index in range(candidates[station_index - 1].size()):
					var before: Vector2 = candidates[station_index - 1][previous_index]
					if not StateGeography.segment_on_land(land, before, point) or _segment_crosses_starter(region, before, point):
						continue
					var change: float = absf(point.y - before.y)
					var cost: float = costs[station_index - 1][previous_index] + intrinsic + change * 0.25 + change * change / maxf(20.0, point.x - before.x) * 0.4
					if cost < best_cost:
						best_cost = cost
						best_parent = previous_index
			row_costs.append(best_cost)
			row_parents.append(best_parent)
		costs.append(row_costs)
		parents.append(row_parents)
	var choice := -1
	var lowest := INF
	for index in range(costs[-1].size()):
		if costs[-1][index] < lowest:
			lowest = costs[-1][index]
			choice = index
	assert(choice >= 0, "A highway corridor must have a continuous land route.")
	var result: Array[Vector2] = []
	result.resize(stations.size())
	for station_index in range(stations.size() - 1, -1, -1):
		result[station_index] = candidates[station_index][choice]
		choice = parents[station_index][choice]
	return result


static func _land_spine_site(region, target: Vector2, normal: Vector2, fallback: Vector2) -> Vector2:
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	if Geometry2D.is_point_in_polygon(target, land) and RoadRouteBuilder.clearance_to_coast(land, target) >= 2.0 and _outside_starter_districts(region, target, 1.5):
		return target
	var best := Vector2.INF
	var best_score := INF
	for radius in [6.0, 10.0, 16.0, 24.0, 32.0, 48.0]:
		for turn in range(0, 360, 15):
			var trial: Vector2 = fallback + normal.rotated(deg_to_rad(float(turn))) * float(radius)
			if not Geometry2D.is_point_in_polygon(trial, land) or RoadRouteBuilder.clearance_to_coast(land, trial) < 2.0 or not _outside_starter_districts(region, trial, 1.5):
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


static func _arterial_connector_node(region, city_id: int, point: Vector2, candidates: Dictionary) -> int:
	var best_id := -1
	var best_score := INF
	for key in candidates:
		var node_id: int = int(key)
		if node_id == region.city_hub_node_ids[city_id]:
			continue
		var from_point: Vector2 = region.road_nodes[node_id].position_km
		var distance: float = from_point.distance_to(point)
		var score: float = distance + absf(from_point.x - point.x) * 1.5
		if distance < 0.001 or distance > 250.0:
			continue
		if not StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, from_point, point):
			score += 200.0
		if _connector_crosses_starter(region, from_point, point):
			score += 1000.0
		if score >= best_score:
			continue
		best_id = node_id
		best_score = score
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
