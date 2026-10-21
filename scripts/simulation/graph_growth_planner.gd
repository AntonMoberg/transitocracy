extends RefCounted

const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")

const MAX_PROPOSALS_PER_CITY = 4


static func proposals(region) -> Array[Dictionary]:
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var frontier: Dictionary = {}
	for city_id in range(region.cities.size()):
		frontier[city_id] = {}
	for key in region.urban_sector_claims:
		var pieces: PackedStringArray = String(key).split(":")
		if pieces.size() != 3:
			continue
		var city_id: int = int(pieces[0])
		var sector := Vector2i(int(pieces[1]), int(pieces[2]))
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			frontier[city_id][sector + step] = true
	# A player road can seed a city before it has any developed neighborhood.
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		for point in [link.points[0], link.points[-1]]:
			var city_id: int = region.city_id_at_point(point)
			if city_id < 0 or not region.urban_sector_claims.is_empty() and not frontier[city_id].is_empty():
				continue
			var plan: Dictionary = CityPlan.guide(region, city_id, point)
			var sector: Vector2i = UrbanGraph.sector_at(point, plan)
			for step in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				frontier[city_id][sector + step] = true
	var result: Array[Dictionary] = []
	for city_id in range(region.cities.size()):
		var options: Array[Dictionary] = []
		for sector in frontier[city_id]:
			var key: String = UrbanGraph.sector_key(city_id, sector)
			if region.urban_sector_claims.has(key) or not UrbanGraph.is_buildable(region, city_id, sector):
				continue
			var generated: Dictionary = UrbanGraph.make_layout(region, city_id, sector)
			var layout = generated["layout"]
			var frontage_id: int = int(generated["frontage_id"])
			if frontage_id < 0 or layout.core_paths.is_empty() or layout.blocks.is_empty():
				continue
			var link_index: int = RoadGraph.link_index(region, frontage_id)
			if link_index < 0 or rooted[region.road_links[link_index].from_node_id] == 0 or rooted[region.road_links[link_index].to_node_id] == 0:
				continue
			var shared := 0
			for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if region.urban_sector_claims.has(UrbanGraph.sector_key(city_id, sector + step)):
					shared += 1
			var distance: float = layout.bounds.get_center().distance_to(region.cities[city_id]["center_km"])
			var corridor_bias := 0.0
			for corridor in region.urban_corridors:
				if int(corridor["city_id"]) != city_id:
					continue
				var line: PackedVector2Array = corridor["points"]
				corridor_bias = maxf(corridor_bias, 3.0 - layout.bounds.get_center().distance_to(Geometry2D.get_closest_point_to_segment(layout.bounds.get_center(), line[0], line[-1])))
			for corridor in region.rail_reservations:
				if int(corridor["city_id"]) != city_id:
					continue
				var line: PackedVector2Array = corridor["points"]
				corridor_bias = maxf(corridor_bias, 2.0 - layout.bounds.get_center().distance_to(Geometry2D.get_closest_point_to_segment(layout.bounds.get_center(), line[0], line[-1])))
			for station in region.station_sites:
				if int(station["city_id"]) == city_id:
					corridor_bias = maxf(corridor_bias, 2.0 - layout.bounds.get_center().distance_to(station["point"]))
			var policy: Dictionary = region.cities[city_id].get("urban_policy", {})
			var focus: int = int(policy.get("growth_focus", 0))
			var priority: float = float(shared) * 20.0 + corridor_bias * (5.0 if focus == 2 else 2.0) - distance * (0.8 if focus == 1 else 0.2)
			options.append({"layout": layout, "frontage_id": frontage_id, "sector": sector, "priority": priority})
		options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a["priority"]), float(b["priority"])):
				return float(a["priority"]) > float(b["priority"])
			return String(a["layout"].key) < String(b["layout"].key)
		)
		for index in range(mini(MAX_PROPOSALS_PER_CITY, options.size())):
			result.append(options[index])
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["priority"]), float(b["priority"])):
			return float(a["priority"]) > float(b["priority"])
		return String(a["layout"].key) < String(b["layout"].key)
	)
	return result
