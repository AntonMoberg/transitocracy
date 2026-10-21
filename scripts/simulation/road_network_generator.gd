extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const StreetLayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")
const Streamlines = preload("res://scripts/simulation/street_streamline_tracer.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")


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
	var bands: Array = _choose_highway_bands(region, ordered, last_x - first_x)
	var trunk_nodes: Array = []
	var access_options: Dictionary = {}
	for band_index in range(bands.size()):
		var band: Array = bands[band_index]
		var target_y: float = region.cities[band[floori(float(band.size()) / 2.0)]]["center_km"].y
		var stations: Array = []
		for station in range(ceili((last_x - first_x) / 35.0) + 1):
			stations.append({"x": lerpf(first_x, last_x, float(station) / float(maxi(1, ceili((last_x - first_x) / 35.0)))), "city": -1, "cross": -1})
		# Place exits on the corridor actually assigned to each city.
		for city_id in band:
			stations.append({"x": region.cities[city_id]["center_km"].x, "city": city_id, "access_city": city_id})
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
		stations = []
		for entry in sparse_stations:
			if not stations.is_empty() and absf(float(entry["x"]) - float(stations[-1]["x"])) < 5.0:
				var access_city: int = int(entry.get("access_city", -1))
				if access_city >= 0:
					var merged: Dictionary = stations[-1]
					merged["access_cities"].append(access_city)
					if int(merged["city"]) < 0:
						merged["city"] = access_city
				continue
			var station_entry: Dictionary = entry.duplicate()
			station_entry["access_cities"] = []
			if int(entry.get("access_city", -1)) >= 0:
				station_entry["access_cities"].append(int(entry["access_city"]))
			stations.append(station_entry)
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
			for access_city in entry["access_cities"]:
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
			_add_traced_highway(region, ids[index - 1], ids[index], (last - before).normalized(), (after - first).normalized(), band_index)
			region.road_links[-1].corridor_id = trunk_corridor_id
		trunk_nodes.append(ids)
	for band_index in range(1, trunk_nodes.size()):
		_connect_highway_bands(region, trunk_nodes[band_index - 1], trunk_nodes[band_index], last_x - first_x)
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


static func _choose_highway_bands(region, ordered: Array[int], span: float) -> Array:
	var costs: Array = _highway_band_costs(region, ordered)
	var count: int = ordered.size()
	var best: Array = [ordered]
	var best_score: float = span + costs[0][count]
	for cut in range(2, count - 1):
		var trial: Array = [ordered.slice(0, cut), ordered.slice(cut)]
		var score: float = span * 2.0 + 35.0 + costs[0][cut] + costs[cut][count]
		if score < best_score:
			best = trial
			best_score = score
		for second_cut in range(cut + 2, count - 1):
			trial = [ordered.slice(0, cut), ordered.slice(cut, second_cut), ordered.slice(second_cut)]
			score = span * 3.0 + 70.0 + costs[0][cut] + costs[cut][second_cut] + costs[second_cut][count]
			if score < best_score:
				best = trial
				best_score = score
	return best


static func _highway_band_costs(region, ordered: Array[int]) -> Array:
	var ys := PackedFloat64Array()
	var sums := PackedFloat64Array([0.0])
	for city_id in ordered:
		var y: float = region.cities[city_id]["center_km"].y
		ys.append(y)
		sums.append(sums[-1] + y)
	var costs: Array = []
	for start in range(ordered.size()):
		var row := PackedFloat64Array()
		row.resize(ordered.size() + 1)
		for finish in range(start + 1, ordered.size() + 1):
			var middle_index: int = start + floori(float(finish - start) / 2.0)
			var middle: float = ys[middle_index]
			var feeder: float = middle * float(middle_index - start) - (sums[middle_index] - sums[start])
			feeder += sums[finish] - sums[middle_index + 1] - middle * float(finish - middle_index - 1)
			var left := start
			var right := middle_index
			while left < right:
				var probe: int = floori(float(left + right) / 2.0)
				if ys[probe] < middle - 36.0:
					left = probe + 1
				else:
					right = probe
			var remote: float = (middle - 36.0) * float(left - start) - (sums[left] - sums[start])
			left = middle_index + 1
			right = finish
			while left < right:
				var probe: int = floori(float(left + right) / 2.0)
				if ys[probe] <= middle + 36.0:
					left = probe + 1
				else:
					right = probe
			remote += sums[finish] - sums[left] - (middle + 36.0) * float(finish - left)
			row[finish] = feeder * 5.0 + remote * 50.0
		costs.append(row)
	return costs


static func _connect_highway_bands(region, north_nodes: Array, south_nodes: Array, span: float) -> void:
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	var candidates: Array[Dictionary] = []
	for north_id in north_nodes:
		var north: Vector2 = region.road_nodes[north_id].position_km
		for south_id in south_nodes:
			var south: Vector2 = region.road_nodes[south_id].position_km
			var run: float = south.x - north.x
			if run < span * 0.035 or run > span * 0.35:
				continue
			var rise: float = south.y - north.y
			if rise < 12.0 or rise < run * 0.35:
				continue
			var cross_direction: Vector2 = (south - north).normalized()
			if absf(cross_direction.cross(_trunk_tangent(region, north_nodes, north_id))) < 0.4 or absf(cross_direction.cross(_trunk_tangent(region, south_nodes, south_id))) < 0.4:
				continue
			if not StateGeography.segment_on_land(land, north, south) or _segment_crosses_starter(region, north, south):
				continue
			var middle_x: float = (north.x + south.x) * 0.5
			var score: float = absf(run - rise * 0.9) + absf(middle_x - (region.jurisdictions[0].bounds_km.position.x + region.jurisdictions[0].bounds_km.end.x) * 0.5) * 0.25 + north.distance_to(south) * 0.03
			candidates.append({"north": north_id, "south": south_id, "score": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] < b["score"])
	for candidate in candidates:
		var first_id: int = candidate["north"]
		var last_id: int = candidate["south"]
		var direction: Vector2 = (region.road_nodes[last_id].position_km - region.road_nodes[first_id].position_km).normalized()
		_add_traced_highway(region, first_id, last_id, direction, direction, north_nodes.size() + south_nodes.size(), true)
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
	assert(false, "Starter highway corridors need a clear diagonal connection.")


static func _trunk_tangent(region, node_ids: Array, node_id: int) -> Vector2:
	var index: int = node_ids.find(node_id)
	var before: Vector2 = region.road_nodes[node_ids[maxi(0, index - 1)]].position_km
	var after: Vector2 = region.road_nodes[node_ids[mini(node_ids.size() - 1, index + 1)]].position_km
	return (after - before).normalized()


static func _add_traced_highway(region, first_id: int, last_id: int, start_tangent: Vector2, end_tangent: Vector2, corridor_index: int, land_certified: bool = false) -> void:
	var first: Vector2 = region.road_nodes[first_id].position_km
	var last: Vector2 = region.road_nodes[last_id].position_km
	var lead: float = minf(1.0, first.distance_to(last) * 0.12)
	var trace_start: Vector2 = first + start_tangent.normalized() * lead
	var trace_end: Vector2 = last - end_tangent.normalized() * lead
	if trace_start.distance_to(trace_end) < lead * 0.5:
		_add_link(region, first_id, last_id, RoadLinkData.HIGHWAY, 2, start_tangent, end_tangent, land_certified)
		return
	var traced: PackedVector2Array = PackedVector2Array([first])
	traced.append_array(DirectionField.trace_regional(trace_start, trace_end, start_tangent, end_tangent, region.generation_seed, corridor_index))
	traced.append(last)
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	var valid := true
	for segment in range(1, traced.size()):
		if not StateGeography.segment_on_land(land, traced[segment - 1], traced[segment]) or _segment_crosses_starter(region, traced[segment - 1], traced[segment]):
			valid = false
			break
	if not valid or RoadRouteBuilder.minimum_curve_radius(traced) < RoadRouteBuilder.MIN_HIGHWAY_RADIUS_KM:
		_add_link(region, first_id, last_id, RoadLinkData.HIGHWAY, 2, start_tangent, end_tangent, land_certified)
		return
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.corridor_id = link.id
	link.from_node_id = first_id
	link.to_node_id = last_id
	link.road_class = RoadLinkData.HIGHWAY
	link.lanes_per_direction = 2
	link.points = traced
	link.recalculate_length()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points, RoadLinkData.HIGHWAY)
	region.road_links.append(link)


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
	UrbanGraph.build_starting_city(region, city)


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
