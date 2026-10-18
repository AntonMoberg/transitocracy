extends RefCounted

const Paths = preload("res://scripts/simulation/street_paths.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Purposes = ["Work", "Commercial", "Social"]


static func prepare(region, costs: PackedVector2Array = PackedVector2Array()) -> void:
	if region.urban_route_revision == region.road_geometry_revision:
		var changed := false
		if not costs.is_empty():
			for graph in region.urban_route_cache.values():
				for local_id in range(graph["links"].size()):
					var cost: Vector2 = costs[graph["links"][local_id]]
					if absf((cost.x + cost.y) * 0.5 - graph["costs"][local_id]) > maxf(0.1, graph["costs"][local_id] * 0.1):
						changed = true
						break
				if changed:
					break
		if not changed:
			return
	var graphs: Dictionary = {}
	for node in region.road_nodes:
		if node.city_id < 0:
			continue
		if not graphs.has(node.city_id):
			graphs[node.city_id] = {"lookup": {}, "ids": PackedInt32Array(), "edges": PackedVector2Array(), "links": PackedInt32Array(), "costs": PackedFloat32Array(), "trees": {}}
		var graph: Dictionary = graphs[node.city_id]
		graph["lookup"][node.id] = graph["ids"].size()
		graph["ids"].append(node.id)
	for link_index in range(region.road_links.size()):
		var link = region.road_links[link_index]
		var city_id: int = region.road_nodes[link.from_node_id].city_id
		if city_id < 0 or link.road_class == Roads.HIGHWAY or region.road_nodes[link.to_node_id].city_id != city_id:
			continue
		var graph: Dictionary = graphs[city_id]
		graph["edges"].append(Vector2(graph["lookup"][link.from_node_id], graph["lookup"][link.to_node_id]))
		graph["links"].append(link_index)
		graph["costs"].append(link.length_km * 60.0 / RoadGraph.free_speed_kmh(link.road_class) if costs.is_empty() else (costs[link_index].x + costs[link_index].y) * 0.5)
	for city_id in graphs:
		var graph: Dictionary = graphs[city_id]
		graph["adjacency"] = Paths.adjacency(graph["ids"].size(), graph["edges"])
	region.urban_route_cache = graphs
	region.urban_route_revision = region.road_geometry_revision


static func _tree(region, neighborhood_id: int) -> Dictionary:
	var neighborhood = region.neighborhoods[neighborhood_id]
	var graph: Dictionary = region.urban_route_cache.get(neighborhood.city_id, {})
	if graph.is_empty():
		return {}
	if graph["trees"].has(neighborhood_id):
		return graph["trees"][neighborhood_id]
	var sources := PackedInt32Array()
	var access_ids: Array = neighborhood.access_node_ids if not neighborhood.access_node_ids.is_empty() else [region.neighborhood_gateway_node_ids[neighborhood_id]]
	for node_id in access_ids:
		if graph["lookup"].has(node_id):
			sources.append(graph["lookup"][node_id])
	var result: Dictionary = Paths.tree(graph["adjacency"], graph["costs"], sources, neighborhood.access_minutes)
	result["base_minutes"] = neighborhood.access_minutes
	graph["trees"][neighborhood_id] = result
	return result


static func route(region, origin_id: int, destination_id: int) -> Dictionary:
	prepare(region)
	var destination = region.neighborhoods[destination_id]
	if region.neighborhoods[origin_id].city_id != destination.city_id:
		return {"minutes": RoadGraph.UNREACHABLE_MINUTES, "path": []}
	var graph: Dictionary = region.urban_route_cache.get(destination.city_id, {})
	var tree_result: Dictionary = _tree(region, origin_id)
	if tree_result.is_empty():
		return {"minutes": RoadGraph.UNREACHABLE_MINUTES, "path": []}
	var best_node := -1
	var best_time: float = RoadGraph.UNREACHABLE_MINUTES
	var access_ids: Array = destination.access_node_ids if not destination.access_node_ids.is_empty() else [region.neighborhood_gateway_node_ids[destination_id]]
	for node_id in access_ids:
		if not graph["lookup"].has(node_id):
			continue
		var local_id: int = graph["lookup"][node_id]
		if tree_result["distances"][local_id] < best_time:
			best_time = tree_result["distances"][local_id]
			best_node = local_id
	var result: Array[Vector2i] = []
	if best_node >= 0:
		for edge in Paths.path(tree_result, best_node, graph["edges"]):
			result.append(Vector2i(graph["links"][edge.x], edge.y))
	return {"minutes": best_time + destination.access_minutes + region.neighborhoods[origin_id].access_minutes - tree_result["base_minutes"], "path": result}


static func hub_route(region, neighborhood_id: int) -> Dictionary:
	prepare(region)
	var neighborhood = region.neighborhoods[neighborhood_id]
	var graph: Dictionary = region.urban_route_cache.get(neighborhood.city_id, {})
	var hub_id: int = region.city_route_node_ids[neighborhood.city_id] if not region.city_route_node_ids.is_empty() else region.city_hub_node_ids[neighborhood.city_id]
	var tree_result: Dictionary = _tree(region, neighborhood_id)
	if tree_result.is_empty() or not graph["lookup"].has(hub_id):
		return {"minutes": RoadGraph.UNREACHABLE_MINUTES, "path": []}
	var destination: int = graph["lookup"][hub_id]
	var result: Array[Vector2i] = []
	for edge in Paths.path(tree_result, destination, graph["edges"]):
		result.append(Vector2i(graph["links"][edge.x], edge.y))
	return {"minutes": tree_result["distances"][destination] + neighborhood.access_minutes - tree_result["base_minutes"], "path": result}


static func assign_local(region, profile, hour: int, volumes: PackedVector2Array) -> void:
	prepare(region)
	for city in region.cities:
		var ids: Array = city["neighborhood_ids"]
		var outward: Dictionary = {}
		var inward: Dictionary = {}
		for neighborhood_id in ids:
			outward[neighborhood_id] = 0.0
			inward[neighborhood_id] = 0.0
		for purpose in Purposes:
			var origin_total := 0.0
			var destination_total := 0.0
			for neighborhood_id in ids:
				origin_total += profile.compact_origin_daily[purpose][neighborhood_id]
				destination_total += profile.compact_destination_daily[purpose][neighborhood_id]
			var internal_daily: float = profile.compact_city_od[purpose][city["id"]][city["id"]]
			var out_curve: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[purpose]["out"][hour]
			var back_curve: float = 1.0 / 24.0 if hour == 24 else profile.compact_curves[purpose]["back"][hour]
			var occupancy: float = {"Work": 1.2, "Commercial": 1.5, "Social": 1.8}[purpose]
			for origin_id in ids:
				var origin_share: float = profile.compact_origin_daily[purpose][origin_id] / maxf(1.0, origin_total)
				var destination_share: float = profile.compact_destination_daily[purpose][origin_id] / maxf(1.0, destination_total)
				outward[origin_id] += maxf(0.0, profile.compact_origin_daily[purpose][origin_id] - internal_daily * origin_share) * out_curve * 0.9 / occupancy
				inward[origin_id] += maxf(0.0, profile.compact_destination_daily[purpose][origin_id] - internal_daily * destination_share) * out_curve * 0.9 / occupancy
				inward[origin_id] += maxf(0.0, profile.compact_origin_daily[purpose][origin_id] - internal_daily * origin_share) * back_curve * 0.9 / occupancy
				outward[origin_id] += maxf(0.0, profile.compact_destination_daily[purpose][origin_id] - internal_daily * destination_share) * back_curve * 0.9 / occupancy
				if origin_share <= 0.0:
					continue
				for destination_id in ids:
					if destination_id == origin_id:
						continue
					var target_share: float = profile.compact_destination_daily[purpose][destination_id] / maxf(1.0, destination_total)
					var cars: float = internal_daily * origin_share * target_share * 0.35 / occupancy
					if cars < 0.001:
						continue
					for edge in route(region, origin_id, destination_id)["path"]:
						volumes[edge.x] += Vector2(cars * out_curve, cars * back_curve) if edge.y == 0 else Vector2(cars * back_curve, cars * out_curve)
		for neighborhood_id in ids:
			for edge in hub_route(region, neighborhood_id)["path"]:
				volumes[edge.x] += Vector2(outward[neighborhood_id], inward[neighborhood_id]) if edge.y == 0 else Vector2(inward[neighborhood_id], outward[neighborhood_id])
