extends RefCounted

const RoadGraph = preload("res://scripts/simulation/road_graph.gd")

const ROAD_SPEED_KMH = 35.0
const ACCESS_TIME_DECAY_MINUTES = 30.0
const LOCAL_TRAVEL_MINUTES = 5.0


static func recalculate(region) -> void:
	if region.is_large_scale:
		_recalculate_large(region)
		return
	if not region.road_nodes.is_empty():
		region.neighborhood_development_connected = RoadGraph.neighborhoods_connected_to_start(region)
		region.travel_times = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region), [], false)["times"]
		recalculate_jobs(region)
		return
	region.travel_times.clear()
	region.accessibility = PackedFloat32Array()
	var count: int = region.neighborhoods.size()
	for origin_id in range(count):
		var times := PackedFloat32Array()
		times.resize(count)
		for destination_id in range(count):
			var origin = region.neighborhoods[origin_id]
			var destination = region.neighborhoods[destination_id]
			var distance_km: float = origin.position_km.distance_to(destination.position_km)
			var minutes: float = LOCAL_TRAVEL_MINUTES + distance_km * 60.0 / ROAD_SPEED_KMH
			times[destination_id] = minutes
		region.travel_times.append(times)
	recalculate_jobs(region)


static func recalculate_jobs(region) -> void:
	if region.is_large_scale:
		_recalculate_large_jobs(region)
		return
	region.accessibility = PackedFloat32Array()
	for origin_id in range(region.neighborhoods.size()):
		var reachable_jobs := 0.0
		for destination_id in range(region.neighborhoods.size()):
			var minutes: float = region.travel_times[origin_id][destination_id]
			reachable_jobs += region.neighborhoods[destination_id].jobs * exp(-minutes / ACCESS_TIME_DECAY_MINUTES)
		region.accessibility.append(reachable_jobs)


static func recalculate_large_with_costs(region, costs: PackedVector2Array) -> void:
	_recalculate_large(region, costs)


static func _recalculate_large(region, supplied_costs: PackedVector2Array = PackedVector2Array()) -> void:
	var city_count: int = region.cities.size()
	region.neighborhood_development_connected = RoadGraph.neighborhoods_connected_to_start(region)
	var adjacency: Array = RoadGraph.adjacency(region)
	var rooted_nodes: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	region.city_route_node_ids = region.city_hub_node_ids.duplicate()
	for city in region.cities:
		var hub_id: int = region.city_hub_node_ids[city["id"]]
		if rooted_nodes[hub_id] != 0:
			continue
		for neighborhood_id in city["neighborhood_ids"]:
			var gateway_id: int = region.neighborhood_gateway_node_ids[neighborhood_id]
			if adjacency[gateway_id].is_empty():
				continue
			if adjacency[hub_id].is_empty() or region.neighborhood_development_connected[neighborhood_id] != 0:
				region.city_route_node_ids[city["id"]] = gateway_id
			if region.neighborhood_development_connected[neighborhood_id] != 0:
				break
	region.neighborhood_accessible.resize(region.neighborhoods.size())
	region.neighborhood_accessible.fill(0)
	var costs: PackedVector2Array = supplied_costs if not supplied_costs.is_empty() else RoadGraph.free_flow_costs(region)
	var neighbors: Array = adjacency
	var forest: bool = RoadGraph.is_forest(region)
	var rows: Array = []
	rows.resize(city_count)
	if city_count >= 32 and OS.get_processor_count() > 1:
		var workers: int = mini(8, OS.get_processor_count())
		var task_id: int = WorkerThreadPool.add_group_task(
			func(city_id: int) -> void:
				rows[city_id] = _city_times_row(region, costs, neighbors, forest, city_id),
			city_count, workers, false, "City road accessibility")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for city_id in range(city_count):
			rows[city_id] = _city_times_row(region, costs, neighbors, forest, city_id)
	region.city_travel_times.clear()
	for city_id in range(city_count):
		region.city_travel_times.append(rows[city_id]["times"])
		var neighborhood_ids: Array = region.cities[city_id]["neighborhood_ids"]
		for local_id in range(neighborhood_ids.size()):
			region.neighborhood_accessible[neighborhood_ids[local_id]] = rows[city_id]["accessible"][local_id]
	_recalculate_large_jobs(region)


static func _city_times_row(region, costs: PackedVector2Array, neighbors: Array, forest: bool, city_id: int) -> Dictionary:
	var source_node: int = region.city_route_node_ids[city_id]
	var tree: Dictionary = RoadGraph._shortest_tree(region, costs, neighbors, source_node, false, false, forest)
	var distances: PackedFloat32Array = tree["distances"]
	var row := PackedFloat32Array()
	row.resize(region.cities.size())
	for destination_id in range(row.size()):
		row[destination_id] = RoadGraph.LOCAL_ACCESS_MINUTES + distances[region.city_route_node_ids[destination_id]]
	var accessible := PackedByteArray()
	for neighborhood_id in region.cities[city_id]["neighborhood_ids"]:
		var gateway_id: int = region.neighborhood_gateway_node_ids[neighborhood_id]
		accessible.append(1 if distances[gateway_id] < RoadGraph.UNREACHABLE_MINUTES else 0)
	return {"times": row, "accessible": accessible}


static func _recalculate_large_jobs(region) -> void:
	var city_count: int = region.cities.size()
	var jobs_by_city := PackedFloat32Array()
	jobs_by_city.resize(city_count)
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			continue
		jobs_by_city[neighborhood.city_id] += neighborhood.jobs
	var city_access := PackedFloat32Array()
	city_access.resize(city_count)
	for origin_id in range(city_count):
		var reachable := 0.0
		for destination_id in range(city_count):
			reachable += jobs_by_city[destination_id] * exp(-region.city_travel_times[origin_id][destination_id] / ACCESS_TIME_DECAY_MINUTES)
		city_access[origin_id] = reachable
	region.accessibility.resize(region.neighborhoods.size())
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			region.accessibility[neighborhood.id] = 0.0
			continue
		var local_minutes: float = neighborhood.position_km.distance_to(region.cities[neighborhood.city_id]["center_km"]) * 1.2
		region.accessibility[neighborhood.id] = city_access[neighborhood.city_id] * exp(-local_minutes / ACCESS_TIME_DECAY_MINUTES)
