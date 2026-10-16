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


static func route_pairs(region, costs: PackedVector2Array, adjacent_links: Array = []) -> Dictionary:
	var count: int = region.neighborhoods.size()
	var node_count: int = region.road_nodes.size()
	var neighbors: Array = adjacent_links if not adjacent_links.is_empty() else adjacency(region)
	var times: Array[PackedFloat32Array] = []
	var paths: Array = []
	for origin_id in range(count):
		var source_node: int = region.neighborhood_gateway_node_ids[origin_id]
		var distances := PackedFloat32Array()
		distances.resize(node_count)
		distances.fill(UNREACHABLE_MINUTES)
		distances[source_node] = 0.0
		var visited := PackedByteArray()
		visited.resize(node_count)
		var previous_node := PackedInt32Array()
		previous_node.resize(node_count)
		previous_node.fill(-1)
		var previous_link := PackedInt32Array()
		previous_link.resize(node_count)
		previous_link.fill(-1)
		for _step in range(node_count):
			var current := -1
			var best := UNREACHABLE_MINUTES
			for node_id in range(node_count):
				if visited[node_id] == 0 and distances[node_id] < best:
					best = distances[node_id]
					current = node_id
			if current < 0:
				break
			visited[current] = 1
			for edge in neighbors[current]:
				var link_index_value: int = edge.x
				var link = region.road_links[link_index_value]
				var next_node: int = link.to_node_id if edge.y == 0 else link.from_node_id
				var edge_time: float = costs[link_index_value].x if edge.y == 0 else costs[link_index_value].y
				if distances[current] + edge_time < distances[next_node]:
					distances[next_node] = distances[current] + edge_time
					previous_node[next_node] = current
					previous_link[next_node] = link_index_value
		var row := PackedFloat32Array()
		row.resize(count)
		var path_row: Array = []
		for destination_id in range(count):
			var destination_node: int = region.neighborhood_gateway_node_ids[destination_id]
			row[destination_id] = LOCAL_ACCESS_MINUTES + distances[destination_node] if distances[destination_node] < UNREACHABLE_MINUTES else UNREACHABLE_MINUTES
			var path: Array[Vector2i] = []
			var cursor: int = destination_node
			while cursor != source_node and previous_link[cursor] >= 0:
				var edge_index: int = previous_link[cursor]
				var prior: int = previous_node[cursor]
				var direction := 0 if region.road_links[edge_index].from_node_id == prior else 1
				path.push_front(Vector2i(edge_index, direction))
				cursor = prior
			path_row.append(path)
		times.append(row)
		paths.append(path_row)
	return {"times": times, "paths": paths}
