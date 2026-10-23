extends RefCounted

const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")

const PIECE_KM = 0.5
const FRONTAGE_REACH_KM = 0.36
const BUILD_FRONTAGE_REACH_KM = 0.22


static func plan(region, layout) -> void:
	if not layout.border_seams.is_empty() or layout.core_paths.is_empty():
		return
	var city_id: int = layout.city_id
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var joined: Dictionary = {}
	for other_id in range(region.cities.size()):
		if other_id == city_id:
			continue
		var other = region.jurisdictions[region.city_jurisdiction_ids[other_id]]
		if not city.bounds_km.grow(FRONTAGE_REACH_KM).intersects(other.bounds_km):
			continue
		if not layout.bounds.grow(FRONTAGE_REACH_KM).intersects(other.bounds_km):
			continue
		var first_id: int = mini(city_id, other_id)
		var first = region.jurisdictions[region.city_jurisdiction_ids[first_id]]
		var second = region.jurisdictions[region.city_jurisdiction_ids[maxi(city_id, other_id)]]
		for edge_id in range(first.polygon_km.size()):
			var a: Vector2 = first.polygon_km[edge_id]
			var b: Vector2 = first.polygon_km[(edge_id + 1) % first.polygon_km.size()]
			var length: float = a.distance_to(b)
			if length < 0.25:
				continue
			var direction: Vector2 = (b - a) / length
			for second_edge in range(second.polygon_km.size()):
				var c: Vector2 = second.polygon_km[second_edge]
				var d: Vector2 = second.polygon_km[(second_edge + 1) % second.polygon_km.size()]
				var other_direction: Vector2 = (d - c).normalized()
				if absf(direction.cross(other_direction)) > 0.002 or absf(direction.cross(c - a)) > 0.006 or absf(direction.cross(d - a)) > 0.006:
					continue
				var overlap_low: float = maxf(0.0, minf((c - a).dot(direction), (d - a).dot(direction)))
				var overlap_high: float = minf(length, maxf((c - a).dot(direction), (d - a).dot(direction)))
				if overlap_high - overlap_low < 0.25:
					continue
				var near_low := INF
				var near_high := -INF
				for vertex in layout.polygon:
					var projection: Vector2 = Geometry2D.get_closest_point_to_segment(vertex, a + direction * overlap_low, a + direction * overlap_high)
					if vertex.distance_to(projection) < FRONTAGE_REACH_KM:
						var distance: float = (projection - a).dot(direction)
						near_low = minf(near_low, distance)
						near_high = maxf(near_high, distance)
				if near_low == INF:
					continue
				var start_piece: int = maxi(ceili(overlap_low / PIECE_KM), floori((near_low - 0.12) / PIECE_KM))
				var end_piece: int = mini(floori(overlap_high / PIECE_KM) - 1, floori((near_high + 0.12) / PIECE_KM))
				for piece in range(start_piece, end_piece + 1):
					var start: Vector2 = a + direction * float(piece) * PIECE_KM
					var finish: Vector2 = start + direction * PIECE_KM
					if not _piece_reaches_district(start, finish, layout.polygon):
						continue
					var key: String = "%d:%d:%d:%d" % [first_id, maxi(city_id, other_id), edge_id, piece]
					if joined.has(key):
						continue
					joined[key] = true
					var costed: bool = not region.city_border_seams.has(key)
					layout.border_seams.append({"key": key, "cities": Vector2i(first_id, maxi(city_id, other_id)), "from": start, "to": finish, "anchor": -1, "costed": costed})
					if costed:
						layout.phase_costs[0] += roundi(PIECE_KM * Roads.construction_cost(Roads.COLLECTOR))
						layout.phase_upkeep[0] += PIECE_KM * Roads.upkeep(Roads.COLLECTOR)
	if layout.border_seams.is_empty():
		return
	_assign_anchor(region, layout)


# A proposed border street must have developed land alongside it after the
# clipped fringe is added. The broad planning reach is only used to find cells
# that may be able to meet the municipal line.
static func finalize(region, layout) -> void:
	if layout.border_seams.is_empty():
		return
	var city = region.jurisdictions[region.city_jurisdiction_ids[layout.city_id]]
	for seam in layout.border_seams:
		var anchor: int = int(seam["anchor"])
		if anchor >= 0:
			var distance: float = layout.nodes[anchor].distance_to((seam["from"] + seam["to"]) * 0.5)
			layout.phase_costs[0] -= roundi(distance * Roads.construction_cost(Roads.COLLECTOR))
			layout.phase_upkeep[0] -= distance * Roads.upkeep(Roads.COLLECTOR)
	var retained: Array[Dictionary] = []
	for seam in layout.border_seams:
		if _developed_frontage(city, layout.polygon, seam):
			seam["anchor"] = -1
			retained.append(seam)
		elif seam["costed"]:
			layout.phase_costs[0] -= roundi(PIECE_KM * Roads.construction_cost(Roads.COLLECTOR))
			layout.phase_upkeep[0] -= PIECE_KM * Roads.upkeep(Roads.COLLECTOR)
	layout.border_seams = retained
	if not retained.is_empty():
		_assign_anchor(region, layout)
		for index in range(layout.border_seams.size()):
			var seam: Dictionary = layout.border_seams[index]
			if int(seam["anchor"]) < 0 or not region.city_border_seams.has(seam["key"]):
				continue
			var opposite: Dictionary = _opposite_approach(region, layout.city_id, seam)
			if opposite.is_empty() or float(opposite["distance"]) < 0.005:
				continue
			seam["opposite_node"] = opposite["node"]
			seam["opposite_neighborhood"] = opposite["neighborhood"]
			layout.border_seams[index] = seam
			layout.phase_costs[0] += roundi(float(opposite["distance"]) * Roads.construction_cost(Roads.LOCAL))
			layout.phase_upkeep[0] += float(opposite["distance"]) * Roads.upkeep(Roads.LOCAL)


static func _developed_frontage(city, outline: PackedVector2Array, seam: Dictionary) -> bool:
	var normal: Vector2 = (seam["to"] - seam["from"]).normalized().orthogonal() * 0.05
	var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
	if not city.contains_point(middle + normal):
		normal = -normal
	var covered := 0
	for fraction in [0.25, 0.5, 0.75]:
		if Geometry2D.is_point_in_polygon(seam["from"].lerp(seam["to"], fraction) + normal, outline):
			covered += 1
	return covered >= 2


static func _opposite_approach(region, city_id: int, seam: Dictionary) -> Dictionary:
	var other_id: int = seam["cities"].y if seam["cities"].x == city_id else seam["cities"].x
	var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
	for link in region.road_links:
		if link.managed_neighborhood_id < 0 or region.neighborhoods[link.managed_neighborhood_id].city_id != other_id:
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			if region.road_nodes[node_id].position_km.distance_to(middle) < 0.005:
				return {"node": node_id, "neighborhood": link.managed_neighborhood_id, "distance": 0.0}
	var best: Dictionary = {}
	var nearest := 0.48
	var other_city = region.jurisdictions[region.city_jurisdiction_ids[other_id]]
	for neighborhood_id in region.cities[other_id]["neighborhood_ids"]:
		var neighborhood = region.neighborhoods[neighborhood_id]
		if neighborhood.development_plan == null or neighborhood.development_plan.completed_phase < 1:
			continue
		for node_id in neighborhood.development_plan.core_node_ids.values():
			var from: Vector2 = region.road_nodes[int(node_id)].position_km
			var distance: float = from.distance_to(middle)
			if distance < nearest and other_city.contains_point(from.lerp(middle, 0.5)):
				nearest = distance
				best = {"node": int(node_id), "neighborhood": neighborhood_id, "distance": distance}
	return best


static func _assign_anchor(region, layout) -> void:
	var best_index := -1
	var best_anchor := -1
	var best_distance := 0.0
	var best_score := INF
	for index in range(layout.border_seams.size()):
		var seam: Dictionary = layout.border_seams[index]
		var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
		var existing: bool = region.city_border_seams.has(seam["key"])
		for path in layout.core_paths:
			if int(path["phase"]) > 1:
				continue
			for local_id in [int(path["from"]), int(path["to"])]:
				var distance: float = layout.nodes[local_id].distance_to(middle)
				var score: float = distance - (0.20 if existing else 0.0)
				if distance < 0.48 and score < best_score:
					best_score = score
					best_distance = distance
					best_anchor = local_id
					best_index = index
	if best_index < 0:
		# A border frontage without a street approach cannot be activated.
		for seam in layout.border_seams:
			if seam["costed"]:
				layout.phase_costs[0] -= roundi(PIECE_KM * Roads.construction_cost(Roads.COLLECTOR))
				layout.phase_upkeep[0] -= PIECE_KM * Roads.upkeep(Roads.COLLECTOR)
		layout.border_seams.clear()
		return
	var selected: Dictionary = layout.border_seams[best_index]
	selected["anchor"] = best_anchor
	layout.border_seams[best_index] = selected
	layout.phase_costs[0] += roundi(best_distance * Roads.construction_cost(Roads.COLLECTOR))
	layout.phase_upkeep[0] += best_distance * Roads.upkeep(Roads.COLLECTOR)


static func _piece_reaches_district(first: Vector2, last: Vector2, outline: PackedVector2Array) -> bool:
	var near_samples := 0
	for fraction in [0.2, 0.5, 0.8]:
		var sample: Vector2 = first.lerp(last, fraction)
		for index in range(outline.size()):
			if sample.distance_to(Geometry2D.get_closest_point_to_segment(sample, outline[index], outline[(index + 1) % outline.size()])) <= BUILD_FRONTAGE_REACH_KM:
				near_samples += 1
				break
	return near_samples >= 2


static func install(region, neighborhood, ensure_node: Callable) -> void:
	var layout = neighborhood.street_layout
	if layout == null or layout.border_seams.is_empty():
		return
	var plan = neighborhood.development_plan
	for seam in layout.border_seams:
		var key: String = seam["key"]
		if region.city_border_seams.has(key):
			if seam["costed"] and plan.constructing_phase == 1:
				var refund: int = roundi(PIECE_KM * Roads.construction_cost(Roads.COLLECTOR) * plan.capacity_multiplier)
				plan.spent = maxi(0, plan.spent - refund)
				if not region.dev_mode:
					plan.reserved += refund
			continue
		var first: int = ensure_node.call(seam["from"], neighborhood.city_id)
		var last: int = ensure_node.call(seam["to"], neighborhood.city_id)
		if first == last:
			continue
		var link = Roads.new()
		link.id = region.next_road_link_id
		region.next_road_link_id += 1
		link.from_node_id = first
		link.to_node_id = last
		link.road_class = Roads.COLLECTOR
		link.points = PackedVector2Array([seam["from"], seam["to"]])
		link.owner_jurisdiction_id = region.lowest_common_jurisdiction(region.city_jurisdiction_ids[seam["cities"].x], region.city_jurisdiction_ids[seam["cities"].y])
		link.border_city_ids = seam["cities"]
		link.border_seam_key = key
		link.recalculate_length()
		region.road_links.append(link)
		region.city_border_seams[key] = link.id
	for seam in layout.border_seams:
		var anchor: int = int(seam["anchor"])
		if anchor < 0 or not plan.core_node_ids.has(anchor):
			continue
		var first: int = plan.core_node_ids[anchor]
		var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
		var last: int = ensure_node.call(middle, neighborhood.city_id)
		if first == last or Spatial.cache(region)["pairs"].has(Spatial.pair_key(first, last, Roads.COLLECTOR)):
			continue
		var connector = Roads.new()
		connector.id = region.next_road_link_id
		region.next_road_link_id += 1
		connector.from_node_id = first
		connector.to_node_id = last
		connector.road_class = Roads.COLLECTOR
		connector.points = PackedVector2Array([region.road_nodes[first].position_km, region.road_nodes[last].position_km])
		connector.owner_jurisdiction_id = region.city_jurisdiction_ids[neighborhood.city_id]
		connector.managed_neighborhood_id = neighborhood.id
		connector.recalculate_length()
		region.road_links.append(connector)
		var opposite_node: int = int(seam.get("opposite_node", -1))
		if opposite_node < 0 or opposite_node == last or Spatial.cache(region)["pairs"].has(Spatial.pair_key(opposite_node, last, Roads.LOCAL)):
			continue
		var crossing = Roads.new()
		crossing.id = region.next_road_link_id
		region.next_road_link_id += 1
		crossing.from_node_id = opposite_node
		crossing.to_node_id = last
		crossing.road_class = Roads.LOCAL
		crossing.points = PackedVector2Array([region.road_nodes[opposite_node].position_km, region.road_nodes[last].position_km])
		crossing.owner_jurisdiction_id = region.lowest_common_jurisdiction(region.city_jurisdiction_ids[seam["cities"].x], region.city_jurisdiction_ids[seam["cities"].y])
		crossing.managed_neighborhood_id = int(seam["opposite_neighborhood"])
		crossing.recalculate_length()
		region.road_links.append(crossing)
