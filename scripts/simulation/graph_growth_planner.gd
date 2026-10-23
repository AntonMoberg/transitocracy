extends RefCounted

const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")

const MAX_PROPOSALS_PER_CITY = 4


static func proposals(region, city_filter: Array[int] = []) -> Array[Dictionary]:
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var frontier: Dictionary = {}
	var border_frontier: Dictionary = {}
	var road_frontier: Dictionary = {}
	var target_cities: Array[int] = city_filter.duplicate()
	if target_cities.is_empty():
		for city_id in range(region.cities.size()):
			target_cities.append(city_id)
	for city_id in target_cities:
		frontier[city_id] = {}
		border_frontier[city_id] = {}
		road_frontier[city_id] = {}
	for key in region.urban_sector_claims:
		var pieces: PackedStringArray = String(key).split(":")
		if pieces.size() != 3:
			continue
		var city_id: int = int(pieces[0])
		if not frontier.has(city_id):
			continue
		var sector := Vector2i(int(pieces[1]), int(pieces[2]))
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			frontier[city_id][sector + step] = true
	# A player road can seed a city before it has any developed neighborhood.
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		for point in [link.points[0], link.points[-1]]:
			var city_id := -1
			if city_filter.is_empty():
				city_id = region.city_id_at_point(point)
			else:
				for target_id in target_cities:
					if region.jurisdictions[region.city_jurisdiction_ids[target_id]].contains_point(point):
						city_id = target_id
						break
			if city_id < 0 or not frontier[city_id].is_empty() and (not _near_city_border(region, city_id, point) or not _near_approved_land(region, point)):
				continue
			var plan: Dictionary = CityPlan.guide(region, city_id, point)
			var sector: Vector2i = UrbanGraph.sector_at(point, plan, region, city_id)
			for step in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				frontier[city_id][sector + step] = true
				road_frontier[city_id][sector + step] = true
	# A collector on a shared municipal border can seed the neighboring city
	# without requiring a new arterial or an unrelated isolated grid.
	for link in region.road_links:
		if link.border_city_ids.x < 0 or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		var middle: Vector2 = (link.points[0] + link.points[-1]) * 0.5
		var tangent: Vector2 = (link.points[-1] - link.points[0]).normalized()
		for city_id in [link.border_city_ids.x, link.border_city_ids.y]:
			if not frontier.has(city_id):
				continue
			var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
			var inward: Vector2 = tangent.orthogonal() * 0.16
			var point: Vector2 = middle + inward
			if not city.contains_point(point):
				point = middle - inward
			if not city.contains_point(point):
				continue
			var plan: Dictionary = CityPlan.guide(region, city_id, point)
			var sector: Vector2i = UrbanGraph.sector_at(point, plan, region, city_id)
			for step in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				frontier[city_id][sector + step] = true
				border_frontier[city_id][sector + step] = true
	# Once that first district opens, its collectors can carry the frontier
	# farther into the neighboring city without touching its original hub.
	for link in region.road_links:
		if link.road_class != Roads.COLLECTOR or link.managed_neighborhood_id < 0 or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		var city_id: int = region.neighborhoods[link.managed_neighborhood_id].city_id
		if not frontier.has(city_id) or region.starting_city_ids.has(city_id):
			continue
		var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
		var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
		for point in [link.points[0], (link.points[0] + link.points[-1]) * 0.5, link.points[-1]]:
			if not city.contains_point(point):
				continue
			var sector: Vector2i = UrbanGraph.sector_at(point, plan, region, city_id)
			for step in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				frontier[city_id][sector + step] = true
				road_frontier[city_id][sector + step] = true
	var result: Array[Dictionary] = []
	for city_id in target_cities:
		var ranked: Array[Dictionary] = []
		var city_plan: Dictionary = CityPlan.guide(region, city_id, region.cities[city_id]["center_km"])
		for sector in frontier[city_id]:
			var key: String = UrbanGraph.sector_key(city_id, sector)
			if region.urban_sector_claims.has(key):
				continue
			var cells: Array[Vector2i] = UrbanGraph.district_cells(region, city_id, sector)
			if cells.size() < 8:
				continue
			var overlaps := false
			for cell in cells:
				if region.urban_block_claims.has(UrbanGraph.block_key(city_id, cell)):
					overlaps = true
					break
			if overlaps:
				continue
			var outline: PackedVector2Array = UrbanGraph.sector_outline(city_plan, sector, region, city_id)
			if outline.size() < 3:
				continue
			var center: Vector2 = Geography._bounds(outline).get_center()
			var shared := 0
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if region.urban_sector_claims.has(UrbanGraph.sector_key(city_id, sector + step)):
					shared += 1
			var distance: float = center.distance_to(region.cities[city_id]["center_km"])
			var corridor_bias := 0.0
			for corridor in region.urban_corridors:
				if int(corridor["city_id"]) != city_id:
					continue
				var line: PackedVector2Array = corridor["points"]
				corridor_bias = maxf(corridor_bias, 3.0 - center.distance_to(Geometry2D.get_closest_point_to_segment(center, line[0], line[-1])))
			for corridor in region.rail_reservations:
				if int(corridor["city_id"]) != city_id:
					continue
				var line: PackedVector2Array = corridor["points"]
				corridor_bias = maxf(corridor_bias, 2.0 - center.distance_to(Geometry2D.get_closest_point_to_segment(center, line[0], line[-1])))
			for station in region.station_sites:
				if int(station["city_id"]) == city_id:
					corridor_bias = maxf(corridor_bias, 2.0 - center.distance_to(station["point"]))
			var policy: Dictionary = region.cities[city_id].get("urban_policy", {})
			var focus: int = int(policy.get("growth_focus", 0))
			var priority: float = float(shared) * 20.0 + corridor_bias * (5.0 if focus == 2 else 2.0) - distance * (0.8 if focus == 1 else 0.2)
			if border_frontier[city_id].has(sector):
				priority += 35.0
			elif road_frontier[city_id].has(sector):
				priority += 25.0
			ranked.append({"sector": sector, "priority": priority, "key": key})
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a["priority"]), float(b["priority"])):
				return float(a["priority"]) > float(b["priority"])
			return String(a["key"]) < String(b["key"])
		)
		var accepted := 0
		for option in ranked:
			var generated: Dictionary = UrbanGraph.make_layout(region, city_id, option["sector"])
			var layout = generated["layout"]
			var frontage_id: int = int(generated["frontage_id"])
			if frontage_id < 0 or layout.core_paths.is_empty() or layout.blocks.is_empty():
				continue
			var developable_blocks := 0
			for block in layout.blocks:
				if not block["park"]:
					developable_blocks += 1
			if developable_blocks < 4:
				continue
			var link_index: int = RoadGraph.link_index(region, frontage_id)
			if link_index < 0 or rooted[region.road_links[link_index].from_node_id] == 0 or rooted[region.road_links[link_index].to_node_id] == 0:
				continue
			result.append({"layout": layout, "frontage_id": frontage_id, "sector": option["sector"], "priority": option["priority"]})
			accepted += 1
			if accepted >= MAX_PROPOSALS_PER_CITY:
				break
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["priority"]), float(b["priority"])):
			return float(a["priority"]) > float(b["priority"])
		return String(a["layout"].key) < String(b["layout"].key)
	)
	return result


static func _near_approved_land(region, point: Vector2) -> bool:
	for neighborhood in region.neighborhoods:
		if not neighborhood.development_approved:
			continue
		var bounds: Rect2 = region.jurisdictions[neighborhood.jurisdiction_id].bounds_km
		var closest := Vector2(clampf(point.x, bounds.position.x, bounds.end.x), clampf(point.y, bounds.position.y, bounds.end.y))
		if point.distance_to(closest) <= 1.2:
			return true
	return false


static func _near_city_border(region, city_id: int, point: Vector2) -> bool:
	var outline: PackedVector2Array = region.jurisdictions[region.city_jurisdiction_ids[city_id]].polygon_km
	for index in range(outline.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[index], outline[(index + 1) % outline.size()])) <= 1.2:
			return true
	return false
