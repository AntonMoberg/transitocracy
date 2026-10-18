extends RefCounted


static func adjacency(count: int, edges: PackedVector2Array, enabled: PackedByteArray = PackedByteArray()) -> Array:
	var neighbors: Array = []
	for node_id in range(count):
		neighbors.append([])
	for edge_id in range(edges.size()):
		if not enabled.is_empty() and enabled[edge_id] == 0:
			continue
		var edge: Vector2 = edges[edge_id]
		neighbors[int(edge.x)].append(Vector2i(edge_id, int(edge.y)))
		neighbors[int(edge.y)].append(Vector2i(edge_id, int(edge.x)))
	return neighbors


static func tree(neighbors: Array, costs: PackedFloat32Array, sources: PackedInt32Array, initial_cost: float = 0.0) -> Dictionary:
	var distances := PackedFloat32Array()
	distances.resize(neighbors.size())
	distances.fill(1000000.0)
	var previous := PackedInt32Array()
	previous.resize(neighbors.size())
	previous.fill(-1)
	var previous_edge := previous.duplicate()
	var heap: Array[Vector2] = []
	for source in sources:
		distances[source] = initial_cost
		_push(heap, Vector2(source, initial_cost))
	while not heap.is_empty():
		var nearest: Vector2 = heap[0]
		var tail: Vector2 = heap.pop_back()
		if not heap.is_empty():
			var cursor := 0
			while cursor * 2 + 1 < heap.size():
				var child: int = cursor * 2 + 1
				if child + 1 < heap.size() and heap[child + 1].y < heap[child].y:
					child += 1
				if heap[child].y >= tail.y:
					break
				heap[cursor] = heap[child]
				cursor = child
			heap[cursor] = tail
		var node_id: int = int(nearest.x)
		if nearest.y > distances[node_id] + 0.0001:
			continue
		for connection in neighbors[node_id]:
			var next_cost: float = distances[node_id] + costs[connection.x]
			if next_cost + 0.000001 >= distances[connection.y]:
				continue
			distances[connection.y] = next_cost
			previous[connection.y] = node_id
			previous_edge[connection.y] = connection.x
			_push(heap, Vector2(connection.y, next_cost))
	return {"distances": distances, "previous": previous, "edges": previous_edge}


static func _push(heap: Array[Vector2], entry: Vector2) -> void:
	var cursor: int = heap.size()
	heap.append(entry)
	while cursor > 0:
		var parent: int = (cursor - 1) / 2
		if heap[parent].y <= entry.y:
			break
		heap[cursor] = heap[parent]
		cursor = parent
	heap[cursor] = entry


static func path(tree_result: Dictionary, destination: int, edges: PackedVector2Array) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var cursor: int = destination
	while tree_result["edges"][cursor] >= 0:
		var edge_id: int = tree_result["edges"][cursor]
		var previous: int = tree_result["previous"][cursor]
		result.append(Vector2i(edge_id, 0 if int(edges[edge_id].x) == previous else 1))
		cursor = previous
	result.reverse()
	return result
