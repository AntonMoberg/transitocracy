extends RefCounted

const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const LOCAL_ACCESS_MINUTES = 5.0
const UNREACHABLE_MINUTES = 1000000.0
const FREE_SPEEDS_KMH = {RoadLinkData.HIGHWAY: 90.0, RoadLinkData.ARTERIAL: 50.0, RoadLinkData.COLLECTOR: 50.0, RoadLinkData.LOCAL: 20.0}
const CAPACITY_PER_LANE = {RoadLinkData.HIGHWAY: 1800.0, RoadLinkData.ARTERIAL: 900.0, RoadLinkData.COLLECTOR: 600.0, RoadLinkData.LOCAL: 300.0}


static func free_speed_kmh(road_class: String) -> float:
	return FREE_SPEEDS_KMH.get(road_class, 50.0)


static func capacity_per_lane(road_class: String) -> float:
	return CAPACITY_PER_LANE.get(road_class, 900.0)


# Costs stay per link: one (forward, reverse) minute pair for each whole road.
# Sub-edge fractions of junction chains scale these inside the tree search,
# so congestion-weighted cost arrays keep working unchanged.
static func free_flow_costs(region) -> PackedVector2Array:
	var costs := PackedVector2Array()
	for link in region.road_links:
		var minutes: float = link.length_km * 60.0 / free_speed_kmh(link.road_class)
		costs.append(Vector2(minutes, minutes))
	return costs


static func link_index(region, link_id: int) -> int:
	var cached_index: int = region.street_spatial_cache.get("id_indices", {}).get(link_id, -1)
	if cached_index >= 0 and cached_index < region.road_links.size() and region.road_links[cached_index].id == link_id:
		return cached_index
	for index in range(region.road_links.size()):
		if region.road_links[index].id == link_id:
			return index
	return -1


# The routing view. A road is one edge between its endpoint junctions; a link
# with interior junctions contributes a chain of sub-edges (endpoint ->
# junctions -> endpoint) instead of being split. Every neighbor entry is
# Vector2i(edge_index, direction) where direction 0 traverses edge_from ->
# edge_to. edge_link maps each edge back to its parent link for costs, tolls
# and volumes; edge_fraction is the sub-edge's share of the parent's cost.
static func edge_view(region, strategic: bool = false) -> Dictionary:
	var neighbors: Array = []
	neighbors.resize(region.road_nodes.size())
	for node_id in range(neighbors.size()):
		neighbors[node_id] = []
	var edge_from := PackedInt32Array()
	var edge_to := PackedInt32Array()
	var edge_link := PackedInt32Array()
	var edge_fraction := PackedFloat32Array()
	var portals: Dictionary = {}
	if strategic:
		var route_nodes: Array[int] = region.city_route_node_ids if not region.city_route_node_ids.is_empty() else region.city_hub_node_ids
		for node_id in route_nodes:
			var city_id: int = region.road_nodes[node_id].city_id
			if not portals.has(city_id):
				portals[city_id] = {}
			portals[city_id][node_id] = true
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var first = region.road_nodes[link.from_node_id]
		var last = region.road_nodes[link.to_node_id]
		if strategic:
			if link.road_class != RoadLinkData.HIGHWAY and first.city_id == last.city_id:
				for node in [first, last]:
					if not portals.has(node.city_id):
						portals[node.city_id] = {}
					portals[node.city_id][node.id] = true
				if portals.get(first.city_id, {}).size() <= 1:
					continue
		var chain: Array[int] = [link.from_node_id]
		var stations: Array[float] = [0.0]
		var junctions: Array[Dictionary] = link.junctions
		var length: float = maxf(link.length_km, 0.0001)
		for junction in junctions:
			chain.append(int(junction["node_id"]))
			stations.append(clampf(float(junction["station_km"]), 0.0, length))
		chain.append(link.to_node_id)
		stations.append(length)
		for chain_index in range(chain.size() - 1):
			var from_id: int = chain[chain_index]
			var to_id: int = chain[chain_index + 1]
			if from_id == to_id:
				continue
			var edge_index: int = edge_from.size()
			edge_from.append(from_id)
			edge_to.append(to_id)
			edge_link.append(index)
			edge_fraction.append((stations[chain_index + 1] - stations[chain_index]) / length)
			neighbors[from_id].append(Vector2i(edge_index, 0))
			neighbors[to_id].append(Vector2i(edge_index, 1))
	return {"neighbors": neighbors, "edge_from": edge_from, "edge_to": edge_to, "edge_link": edge_link, "edge_fraction": edge_fraction}


static func adjacency(region) -> Dictionary:
	return edge_view(region, false)


static func strategic_adjacency(region) -> Dictionary:
	return edge_view(region, true)


static func _view_or_build(region, adjacent_links) -> Dictionary:
	if typeof(adjacent_links) == TYPE_DICTIONARY and adjacent_links.has("neighbors"):
		return adjacent_links
	return adjacency(region)


# Map a traversal (edge, entered from prior_node) back onto its parent link
# with the direction along that link, for consumers that think in roads.
static func _parent_edge(view: Dictionary, edge_index: int, prior_node: int) -> Vector2i:
	return Vector2i(view["edge_link"][edge_index], 0 if view["edge_from"][edge_index] == prior_node else 1)


static func neighborhoods_connected_to_hubs(region) -> PackedByteArray:
	return _neighborhoods_connected_to_nodes(region, region.city_route_node_ids if not region.city_route_node_ids.is_empty() else region.city_hub_node_ids)


static func neighborhoods_connected_to_start(region) -> PackedByteArray:
	var visited: PackedByteArray = nodes_connected_to_start(region)
	var connected := PackedByteArray()
	connected.resize(region.neighborhoods.size())
	for neighborhood_id in range(connected.size()):
		connected[neighborhood_id] = visited[region.neighborhood_gateway_node_ids[neighborhood_id]]
		for node_id in region.neighborhoods[neighborhood_id].access_node_ids:
			connected[neighborhood_id] = maxi(connected[neighborhood_id], visited[node_id])
	return connected


static func nodes_connected_to_start(region) -> PackedByteArray:
	var roots: Array[int] = []
	for city_id in region.starting_city_ids:
		roots.append(region.city_hub_node_ids[city_id])
	return _nodes_connected_to(region, roots)


static func _neighborhoods_connected_to_nodes(region, roots: Array[int]) -> PackedByteArray:
	var visited: PackedByteArray = _nodes_connected_to(region, roots)
	var connected := PackedByteArray()
	connected.resize(region.neighborhoods.size())
	for neighborhood_id in range(connected.size()):
		connected[neighborhood_id] = visited[region.neighborhood_gateway_node_ids[neighborhood_id]]
		for node_id in region.neighborhoods[neighborhood_id].access_node_ids:
			connected[neighborhood_id] = maxi(connected[neighborhood_id], visited[node_id])
	return connected


static func _nodes_connected_to(region, roots: Array[int]) -> PackedByteArray:
	var view: Dictionary = adjacency(region)
	var neighbors: Array = view["neighbors"]
	var edge_from: PackedInt32Array = view["edge_from"]
	var edge_to: PackedInt32Array = view["edge_to"]
	var visited := PackedByteArray()
	visited.resize(region.road_nodes.size())
	var queue := PackedInt32Array()
	for hub_node_id in roots:
		if visited[hub_node_id] == 0:
			visited[hub_node_id] = 1
			queue.append(hub_node_id)
	var cursor := 0
	while cursor < queue.size():
		var node_id: int = queue[cursor]
		cursor += 1
		for edge in neighbors[node_id]:
			var next_id: int = edge_to[edge.x] if edge.y == 0 else edge_from[edge.x]
			if visited[next_id] == 0:
				visited[next_id] = 1
				queue.append(next_id)
	return visited


static func route_pairs(region, costs: PackedVector2Array, adjacent_links = [], include_paths: bool = true, parallel_sources: bool = true) -> Dictionary:
	var count: int = region.neighborhoods.size()
	var view: Dictionary = _view_or_build(region, adjacent_links)
	var forest: bool = is_forest(region)
	var times: Array[PackedFloat32Array] = []
	var paths: Array = []
	var results: Array = []
	results.resize(count)
	if parallel_sources and count >= 32 and OS.get_processor_count() > 1:
		var workers: int = mini(8, OS.get_processor_count())
		var task_id: int = WorkerThreadPool.add_group_task(
			func(origin_id: int) -> void:
				results[origin_id] = _route_origin(region, costs, view, forest, origin_id, count, include_paths),
			count, workers, false, "Road routes")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for origin_id in range(count):
			results[origin_id] = _route_origin(region, costs, view, forest, origin_id, count, include_paths)
	for result in results:
		times.append(result["times"])
		if include_paths:
			paths.append(result["paths"])
	return {"times": times, "paths": paths}


static func _route_origin(region, costs: PackedVector2Array, view: Dictionary, forest: bool, origin_id: int, count: int, include_paths: bool) -> Dictionary:
	var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
	var tree: Dictionary = _shortest_tree(region, costs, view, source_node, include_paths, false, forest, _access_nodes(region, origin_id))
	var distances: PackedFloat32Array = tree["distances"]
	var previous_node: PackedInt32Array = tree["previous_node"]
	var previous_link: PackedInt32Array = tree["previous_link"]
	var row := PackedFloat32Array()
	row.resize(count)
	var path_row: Array = []
	for destination_id in range(count):
		var destination_node: int = _destination_node(region, destination_id, distances)
		var local_minutes: float = region.neighborhoods[origin_id].access_minutes + region.neighborhoods[destination_id].access_minutes if region.neighborhoods[origin_id].street_layout != null else LOCAL_ACCESS_MINUTES
		row[destination_id] = local_minutes + distances[destination_node] if distances[destination_node] < UNREACHABLE_MINUTES else UNREACHABLE_MINUTES
		if include_paths:
			var path: Array[Vector2i] = []
			var cursor: int = destination_node
			while previous_link[cursor] >= 0:
				var edge_index: int = previous_link[cursor]
				var prior: int = previous_node[cursor]
				path.append(_parent_edge(view, edge_index, prior))
				cursor = prior
			path.reverse()
			path_row.append(path)
	return {"times": row, "paths": path_row}


static func _access_nodes(region, neighborhood_id: int) -> PackedInt32Array:
	var ids: Array = region.neighborhoods[neighborhood_id].access_node_ids
	return PackedInt32Array(ids) if not ids.is_empty() else PackedInt32Array([region.neighborhood_gateway_node_ids[neighborhood_id]])


static func _destination_node(region, neighborhood_id: int, distances: PackedFloat32Array) -> int:
	var best: int = region.neighborhood_gateway_node_ids[neighborhood_id]
	for node_id in region.neighborhoods[neighborhood_id].access_node_ids:
		if distances[node_id] < distances[best]:
			best = node_id
	return best


static func route_from_node(region, costs: PackedVector2Array, source_node: int, destination_node: int) -> Array[Vector2i]:
	if source_node == destination_node:
		return []
	var view: Dictionary = adjacency(region)
	var tree: Dictionary = _shortest_tree(region, costs, view, source_node, true, false, is_forest(region))
	var previous_link: PackedInt32Array = tree["previous_link"]
	var previous_node: PackedInt32Array = tree["previous_node"]
	var path: Array[Vector2i] = []
	var cursor: int = destination_node
	while cursor != source_node and previous_link[cursor] >= 0:
		var edge_index: int = previous_link[cursor]
		var prior: int = previous_node[cursor]
		path.append(_parent_edge(view, edge_index, prior))
		cursor = prior
	if cursor != source_node:
		return []
	path.reverse()
	return path


static func assignment_trees(region, costs: PackedVector2Array, adjacent_links = []) -> Array[Dictionary]:
	var view: Dictionary = _view_or_build(region, adjacent_links)
	var forest: bool = is_forest(region)
	var trees: Array[Dictionary] = []
	for origin_id in range(region.neighborhoods.size()):
		var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
		trees.append(_shortest_tree(region, costs, view, source_node, true, true, forest, _access_nodes(region, origin_id)))
	return trees


static func assign_volumes(region, costs: PackedVector2Array, demand: Array[PackedFloat32Array], adjacent_links = [], cached_trees: Array[Dictionary] = []) -> PackedVector2Array:
	var view: Dictionary = _view_or_build(region, adjacent_links)
	var use_cached_trees: bool = cached_trees.size() == region.neighborhoods.size()
	var forest: bool = is_forest(region) if not use_cached_trees else false
	var volumes := PackedVector2Array()
	volumes.resize(region.road_links.size())
	for origin_id in range(region.neighborhoods.size()):
		var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
		var tree: Dictionary = cached_trees[origin_id] if use_cached_trees else _shortest_tree(region, costs, view, source_node, true, true, forest, _access_nodes(region, origin_id))
		var distances: PackedFloat32Array = tree["distances"]
		var previous_node: PackedInt32Array = tree["previous_node"]
		var previous_link: PackedInt32Array = tree["previous_link"]
		var visit_order: Array[int] = tree["order"]
		var node_loads := PackedFloat32Array()
		node_loads.resize(region.road_nodes.size())
		for destination_id in range(region.neighborhoods.size()):
			var destination_node: int = _destination_node(region, destination_id, distances)
			if destination_node != source_node and distances[destination_node] < UNREACHABLE_MINUTES:
				node_loads[destination_node] += demand[origin_id][destination_id]
		# Each destination's demand flows back through its parents to the origin.
		for order_index in range(visit_order.size() - 1, -1, -1):
			var node_id: int = visit_order[order_index]
			var edge_index: int = previous_link[node_id]
			if edge_index < 0:
				continue
			var vehicles: float = node_loads[node_id]
			if vehicles <= 0.0:
				continue
			var prior: int = previous_node[node_id]
			var link_index_value: int = view["edge_link"][edge_index]
			var volume: Vector2 = volumes[link_index_value]
			if view["edge_from"][edge_index] == prior:
				volume.x += vehicles
			else:
				volume.y += vehicles
			volumes[link_index_value] = volume
			node_loads[prior] += vehicles
	return volumes


static func group_route_trees(region, costs: PackedVector2Array, group_nodes: PackedInt32Array) -> Array[Dictionary]:
	var view: Dictionary = strategic_adjacency(region) if region.is_large_scale else adjacency(region)
	var forest: bool = is_forest(region)
	var results: Array = []
	results.resize(group_nodes.size())
	if group_nodes.size() >= 32 and OS.get_processor_count() > 1:
		var workers: int = mini(8, OS.get_processor_count())
		var task_id: int = WorkerThreadPool.add_group_task(
			func(index: int) -> void:
				results[index] = _shortest_tree(region, costs, view, group_nodes[index], true, true, forest),
			group_nodes.size(), workers, false, "Group road routes")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for index in range(group_nodes.size()):
			results[index] = _shortest_tree(region, costs, view, group_nodes[index], true, true, forest)
	var trees: Array[Dictionary] = []
	for result in results:
		trees.append(result)
	return trees


static func assign_group_volumes(region, group_nodes: PackedInt32Array, demand: Array[PackedFloat32Array], trees: Array[Dictionary]) -> PackedVector2Array:
	var view: Dictionary = strategic_adjacency(region) if region.is_large_scale else adjacency(region)
	var volumes := PackedVector2Array()
	volumes.resize(region.road_links.size())
	for origin_id in range(group_nodes.size()):
		var tree: Dictionary = trees[origin_id]
		var distances: PackedFloat32Array = tree["distances"]
		var previous_node: PackedInt32Array = tree["previous_node"]
		var previous_link: PackedInt32Array = tree["previous_link"]
		var order: Array[int] = tree["order"]
		var node_load := PackedFloat32Array()
		node_load.resize(region.road_nodes.size())
		for destination_id in range(group_nodes.size()):
			var destination_node: int = group_nodes[destination_id]
			if destination_node != origin_id and distances[destination_node] < UNREACHABLE_MINUTES:
				node_load[destination_node] += demand[origin_id][destination_id]
		for order_index in range(order.size() - 1, -1, -1):
			var node_id: int = order[order_index]
			var edge_index: int = previous_link[node_id]
			if edge_index < 0 or node_load[node_id] <= 0.0:
				continue
			var prior: int = previous_node[node_id]
			var link_index_value: int = view["edge_link"][edge_index]
			var volume: Vector2 = volumes[link_index_value]
			if view["edge_from"][edge_index] == prior:
				volume.x += node_load[node_id]
			else:
				volume.y += node_load[node_id]
			volumes[link_index_value] = volume
			node_load[prior] += node_load[node_id]
	return volumes


static func _shortest_tree(region, costs: PackedVector2Array, view: Dictionary, source_node: int, collect_previous: bool, collect_order: bool, forest: bool, source_nodes: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var node_count: int = region.road_nodes.size()
	var neighbors: Array = view["neighbors"]
	var edge_from: PackedInt32Array = view["edge_from"]
	var edge_to: PackedInt32Array = view["edge_to"]
	var edge_link: PackedInt32Array = view["edge_link"]
	var edge_fraction: PackedFloat32Array = view["edge_fraction"]
	var distances := PackedFloat32Array()
	distances.resize(node_count)
	distances.fill(UNREACHABLE_MINUTES)
	distances[source_node] = 0.0
	for node_id in source_nodes:
		distances[node_id] = 0.0
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
	if forest and source_nodes.size() <= 1:
		var stack: Array[int] = [source_node]
		visited[source_node] = 1
		while not stack.is_empty():
			var current: int = stack.pop_back()
			if collect_order:
				visit_order.append(current)
			for edge in neighbors[current]:
				var edge_index: int = edge.x
				var next_node: int = edge_to[edge_index] if edge.y == 0 else edge_from[edge_index]
				if visited[next_node] != 0:
					continue
				visited[next_node] = 1
				var parent_cost: Vector2 = costs[edge_link[edge_index]]
				var edge_time: float = (parent_cost.x if edge.y == 0 else parent_cost.y) * edge_fraction[edge_index]
				distances[next_node] = distances[current] + edge_time
				if collect_previous:
					previous_node[next_node] = current
					previous_link[next_node] = edge_index
				stack.append(next_node)
		return {"distances": distances, "previous_node": previous_node, "previous_link": previous_link, "order": visit_order}
	var heap_nodes: Array[int] = [source_node]
	var heap_costs: Array[float] = [0.0]
	if not source_nodes.is_empty():
		heap_nodes.assign(source_nodes)
		heap_costs.resize(source_nodes.size())
		heap_costs.fill(0.0)
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
			var edge_index: int = edge.x
			var next_node: int = edge_to[edge_index] if edge.y == 0 else edge_from[edge_index]
			var parent_cost: Vector2 = costs[edge_link[edge_index]]
			var edge_time: float = (parent_cost.x if edge.y == 0 else parent_cost.y) * edge_fraction[edge_index]
			var next_distance: float = distances[current] + edge_time
			if next_distance >= distances[next_node]:
				continue
			distances[next_node] = next_distance
			if collect_previous:
				previous_node[next_node] = current
				previous_link[next_node] = edge_index
			var heap_index := heap_nodes.size()
			heap_nodes.append(next_node)
			heap_costs.append(next_distance)
			while heap_index > 0:
				var parent_index: int = floori(float(heap_index - 1) / 2.0)
				if heap_costs[parent_index] <= next_distance:
					break
				heap_nodes[heap_index] = heap_nodes[parent_index]
				heap_costs[heap_index] = heap_costs[parent_index]
				heap_index = parent_index
			heap_nodes[heap_index] = next_node
			heap_costs[heap_index] = next_distance
	return {"distances": distances, "previous_node": previous_node, "previous_link": previous_link, "order": visit_order}


static func is_forest(region) -> bool:
	for link in region.road_links:
		if not link.junctions.is_empty():
			return false
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
