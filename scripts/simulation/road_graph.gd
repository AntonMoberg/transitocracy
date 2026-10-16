extends RefCounted

const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const LOCAL_ACCESS_MINUTES = 5.0
const UNREACHABLE_MINUTES = 1000000.0


static func free_speed_kmh(road_class: String) -> float:
	return 90.0 if road_class == RoadLinkData.HIGHWAY else 50.0


static func capacity_per_lane(road_class: String) -> float:
	return 1800.0 if road_class == RoadLinkData.HIGHWAY else 900.0


static func free_flow_costs(region) -> PackedVector2Array:
	var costs := PackedVector2Array()
	for link in region.road_links:
		var minutes: float = link.length_km * 60.0 / free_speed_kmh(link.road_class)
		costs.append(Vector2(minutes, minutes))
	return costs


static func link_index(region, link_id: int) -> int:
	for index in range(region.road_links.size()):
		if region.road_links[index].id == link_id:
			return index
	return -1


static func adjacency(region) -> Array:
	var neighbors: Array = []
	for node in region.road_nodes:
		neighbors.append([])
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		neighbors[link.from_node_id].append(Vector2i(index, 0))
		neighbors[link.to_node_id].append(Vector2i(index, 1))
	return neighbors


static func route_pairs(region, costs: PackedVector2Array, adjacent_links: Array = [], include_paths: bool = true, parallel_sources: bool = true) -> Dictionary:
	var count: int = region.neighborhoods.size()
	var neighbors: Array = adjacent_links if not adjacent_links.is_empty() else adjacency(region)
	var forest: bool = is_forest(region)
	var times: Array[PackedFloat32Array] = []
	var paths: Array = []
	var results: Array = []
	results.resize(count)
	if parallel_sources and count >= 32 and OS.get_processor_count() > 1:
		var workers: int = mini(8, OS.get_processor_count())
		var task_id: int = WorkerThreadPool.add_group_task(
			func(origin_id: int) -> void:
				results[origin_id] = _route_origin(region, costs, neighbors, forest, origin_id, count, include_paths),
			count, workers, false, "Road routes")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for origin_id in range(count):
			results[origin_id] = _route_origin(region, costs, neighbors, forest, origin_id, count, include_paths)
	for result in results:
		times.append(result["times"])
		if include_paths:
			paths.append(result["paths"])
	return {"times": times, "paths": paths}


static func _route_origin(region, costs: PackedVector2Array, neighbors: Array, forest: bool, origin_id: int, count: int, include_paths: bool) -> Dictionary:
	var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
	var tree: Dictionary = _shortest_tree(region, costs, neighbors, source_node, include_paths, false, forest)
	var distances: PackedFloat32Array = tree["distances"]
	var previous_node: PackedInt32Array = tree["previous_node"]
	var previous_link: PackedInt32Array = tree["previous_link"]
	var row := PackedFloat32Array()
	row.resize(count)
	var path_row: Array = []
	for destination_id in range(count):
		var destination_node: int = region.neighborhood_gateway_node_ids[destination_id]
		row[destination_id] = LOCAL_ACCESS_MINUTES + distances[destination_node] if distances[destination_node] < UNREACHABLE_MINUTES else UNREACHABLE_MINUTES
		if include_paths:
			var path: Array[Vector2i] = []
			var cursor: int = destination_node
			while cursor != source_node and previous_link[cursor] >= 0:
				var edge_index: int = previous_link[cursor]
				var prior: int = previous_node[cursor]
				var direction := 0 if region.road_links[edge_index].from_node_id == prior else 1
				path.append(Vector2i(edge_index, direction))
				cursor = prior
			path.reverse()
			path_row.append(path)
	return {"times": row, "paths": path_row}


static func route_from_node(region, costs: PackedVector2Array, source_node: int, destination_node: int) -> Array[Vector2i]:
	if source_node == destination_node:
		return []
	var tree: Dictionary = _shortest_tree(region, costs, adjacency(region), source_node, true, false, is_forest(region))
	var previous_link: PackedInt32Array = tree["previous_link"]
	var previous_node: PackedInt32Array = tree["previous_node"]
	var path: Array[Vector2i] = []
	var cursor: int = destination_node
	while cursor != source_node and previous_link[cursor] >= 0:
		var link_index_value: int = previous_link[cursor]
		var prior: int = previous_node[cursor]
		path.append(Vector2i(link_index_value, 0 if region.road_links[link_index_value].from_node_id == prior else 1))
		cursor = prior
	if cursor != source_node:
		return []
	path.reverse()
	return path


static func assignment_trees(region, costs: PackedVector2Array, adjacent_links: Array = []) -> Array[Dictionary]:
	var neighbors: Array = adjacent_links if not adjacent_links.is_empty() else adjacency(region)
	var forest: bool = is_forest(region)
	var trees: Array[Dictionary] = []
	for origin_id in range(region.neighborhoods.size()):
		var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
		trees.append(_shortest_tree(region, costs, neighbors, source_node, true, true, forest))
	return trees


static func assign_volumes(region, costs: PackedVector2Array, demand: Array[PackedFloat32Array], adjacent_links: Array = [], cached_trees: Array[Dictionary] = []) -> PackedVector2Array:
	var neighbors: Array = adjacent_links if not adjacent_links.is_empty() else adjacency(region)
	var use_cached_trees: bool = cached_trees.size() == region.neighborhoods.size()
	var forest: bool = is_forest(region) if not use_cached_trees else false
	var volumes := PackedVector2Array()
	volumes.resize(region.road_links.size())
	for origin_id in range(region.neighborhoods.size()):
		var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
		var tree: Dictionary = cached_trees[origin_id] if use_cached_trees else _shortest_tree(region, costs, neighbors, source_node, true, true, forest)
		var distances: PackedFloat32Array = tree["distances"]
		var previous_node: PackedInt32Array = tree["previous_node"]
		var previous_link: PackedInt32Array = tree["previous_link"]
		var visit_order: Array[int] = tree["order"]
		var node_loads := PackedFloat32Array()
		node_loads.resize(region.road_nodes.size())
		for destination_id in range(region.neighborhoods.size()):
			var destination_node: int = region.neighborhood_gateway_node_ids[destination_id]
			if destination_node != source_node and distances[destination_node] < UNREACHABLE_MINUTES:
				node_loads[destination_node] += demand[origin_id][destination_id]
		# Each destination's demand flows back through its parents to the origin.
		for order_index in range(visit_order.size() - 1, -1, -1):
			var node_id: int = visit_order[order_index]
			var link_index_value: int = previous_link[node_id]
			if link_index_value < 0:
				continue
			var vehicles: float = node_loads[node_id]
			if vehicles <= 0.0:
				continue
			var prior: int = previous_node[node_id]
			var link = region.road_links[link_index_value]
			var volume: Vector2 = volumes[link_index_value]
			if link.from_node_id == prior:
				volume.x += vehicles
			else:
				volume.y += vehicles
			volumes[link_index_value] = volume
			node_loads[prior] += vehicles
	return volumes


static func _shortest_tree(region, costs: PackedVector2Array, neighbors: Array, source_node: int, collect_previous: bool, collect_order: bool, forest: bool) -> Dictionary:
	var node_count: int = region.road_nodes.size()
	var distances := PackedFloat32Array()
	distances.resize(node_count)
	distances.fill(UNREACHABLE_MINUTES)
	distances[source_node] = 0.0
	var visited := PackedByteArray()
	visited.resize(node_count)
	var previous_node := PackedInt32Array()
	var previous_link := PackedInt32Array()
	if collect_previous:
		previous_node.resize(node_count)
		previous_node.fill(-1)
		previous_link.resize(node_count)
		previous_link.fill(-1)
	var visit_order: Array[int] = []
	if forest:
		var stack: Array[int] = [source_node]
		visited[source_node] = 1
		while not stack.is_empty():
			var current: int = stack.pop_back()
			if collect_order:
				visit_order.append(current)
			for edge in neighbors[current]:
				var link_index_value: int = edge.x
				var link = region.road_links[link_index_value]
				var next_node: int = link.to_node_id if edge.y == 0 else link.from_node_id
				if visited[next_node] != 0:
					continue
				visited[next_node] = 1
				var edge_time: float = costs[link_index_value].x if edge.y == 0 else costs[link_index_value].y
				distances[next_node] = distances[current] + edge_time
				if collect_previous:
					previous_node[next_node] = current
					previous_link[next_node] = link_index_value
				stack.append(next_node)
		return {"distances": distances, "previous_node": previous_node, "previous_link": previous_link, "order": visit_order}
	var heap_nodes: Array[int] = [source_node]
	var heap_costs: Array[float] = [0.0]
	while not heap_nodes.is_empty():
		var current: int = heap_nodes[0]
		var last_node: int = heap_nodes.pop_back()
		var last_cost: float = heap_costs.pop_back()
		if not heap_nodes.is_empty():
			var sift_index := 0
			while true:
				var left := sift_index * 2 + 1
				if left >= heap_nodes.size():
					break
				var right := left + 1
				var smaller := right if right < heap_nodes.size() and heap_costs[right] < heap_costs[left] else left
				if heap_costs[smaller] >= last_cost:
					break
				heap_nodes[sift_index] = heap_nodes[smaller]
				heap_costs[sift_index] = heap_costs[smaller]
				sift_index = smaller
			heap_nodes[sift_index] = last_node
			heap_costs[sift_index] = last_cost
		if visited[current] != 0:
			continue
		visited[current] = 1
		if collect_order:
			visit_order.append(current)
		for edge in neighbors[current]:
			var link_index_value: int = edge.x
			var link = region.road_links[link_index_value]
			var next_node: int = link.to_node_id if edge.y == 0 else link.from_node_id
			var edge_time: float = costs[link_index_value].x if edge.y == 0 else costs[link_index_value].y
			var next_distance: float = distances[current] + edge_time
			if next_distance >= distances[next_node]:
				continue
			distances[next_node] = next_distance
			if collect_previous:
				previous_node[next_node] = current
				previous_link[next_node] = link_index_value
			var heap_index := heap_nodes.size()
			heap_nodes.append(next_node)
			heap_costs.append(next_distance)
			while heap_index > 0:
				var parent_index: int = (heap_index - 1) / 2
				if heap_costs[parent_index] <= next_distance:
					break
				heap_nodes[heap_index] = heap_nodes[parent_index]
				heap_costs[heap_index] = heap_costs[parent_index]
				heap_index = parent_index
			heap_nodes[heap_index] = next_node
			heap_costs[heap_index] = next_distance
	return {"distances": distances, "previous_node": previous_node, "previous_link": previous_link, "order": visit_order}


static func is_forest(region) -> bool:
	var parents := PackedInt32Array()
	parents.resize(region.road_nodes.size())
	for node_id in range(parents.size()):
		parents[node_id] = node_id
	for link in region.road_links:
		var from_root: int = link.from_node_id
		var to_root: int = link.to_node_id
		while parents[from_root] != from_root:
			from_root = parents[from_root]
		while parents[to_root] != to_root:
			to_root = parents[to_root]
		if from_root == to_root:
			return false
		parents[to_root] = from_root
	return true
