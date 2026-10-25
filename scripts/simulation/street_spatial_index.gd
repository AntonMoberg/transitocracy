extends RefCounted


static func cache(region) -> Dictionary:
	var data: Dictionary = region.street_spatial_cache
	var count: int = data.get("link_count", 0)
	if data.get("revision", -1) != region.road_geometry_revision or count > region.road_links.size() or (count > 0 and region.road_links[count - 1].id != data.get("last_link", -1)):
		data = {}
		region.street_spatial_cache = data
	if data.is_empty():
		data.assign({"revision": region.road_geometry_revision, "nodes": {}, "links": {}, "arterials": {}, "pairs": {}, "id_indices": {}, "used_nodes": {}, "node_count": 0, "link_count": 0, "last_link": -1, "segments": {}, "segment_bounds": {}})
	for node_id in range(data["node_count"], region.road_nodes.size()):
		index_node(data, region.road_nodes[node_id])
	data["node_count"] = region.road_nodes.size()
	for link_index in range(data["link_count"], region.road_links.size()):
		var link = region.road_links[link_index]
		data["id_indices"][link.id] = link_index
		data["used_nodes"][link.from_node_id] = true
		data["used_nodes"][link.to_node_id] = true
		data["pairs"][pair_key(link.from_node_id, link.to_node_id, link.road_class)] = link_index
		for segment in range(1, link.points.size()):
			var low: Vector2 = link.points[segment - 1].min(link.points[segment]) - Vector2.ONE * 0.01
			var high: Vector2 = link.points[segment - 1].max(link.points[segment]) + Vector2.ONE * 0.01
			for grid_y in range(floori(low.y), floori(high.y) + 1):
				for grid_x in range(floori(low.x), floori(high.x) + 1):
					var cell := Vector2i(grid_x, grid_y)
					var pairs: PackedInt32Array = data["segments"].get(cell, PackedInt32Array())
					pairs.append(link_index)
					pairs.append(segment)
					data["segments"][cell] = pairs
					var bounds: PackedFloat32Array = data["segment_bounds"].get(cell, PackedFloat32Array())
					bounds.append(low.x)
					bounds.append(low.y)
					bounds.append(high.x)
					bounds.append(high.y)
					data["segment_bounds"][cell] = bounds
					if link.road_class not in ["Arterial", "Collector"]:
						continue
					if not data["links"].has(cell):
						data["links"][cell] = []
					if not data["links"][cell].has(link_index):
						data["links"][cell].append(link_index)
					if link.road_class == "Arterial":
						if not data["arterials"].has(cell):
							data["arterials"][cell] = []
						if not data["arterials"][cell].has(link_index):
							data["arterials"][cell].append(link_index)
	data["link_count"] = region.road_links.size()
	data["last_link"] = region.road_links[-1].id if not region.road_links.is_empty() else -1
	return data


# Cell keys with indexed entries overlapping a query segment. Callers map a
# whole corridor's segments to cells so each cell list is read once.
static func segment_cell_keys(region, first: Vector2, last: Vector2) -> Array:
	var data: Dictionary = cache(region)
	var result: Array = []
	var low: Vector2 = first.min(last) - Vector2.ONE * 0.01
	var high: Vector2 = first.max(last) + Vector2.ONE * 0.01
	for grid_y in range(floori(low.y), floori(high.y) + 1):
		for grid_x in range(floori(low.x), floori(high.x) + 1):
			var cell := Vector2i(grid_x, grid_y)
			if data["segments"].has(cell):
				result.append(cell)
	return result


# Cell entry lists overlapping a query segment, paired with per-entry bounds
# arrays so callers can reject with four compares before fetching objects.
# Iterated in place (no copies).
static func segment_cells(region, first: Vector2, last: Vector2) -> Array:
	var data: Dictionary = cache(region)
	var result: Array = []
	var low: Vector2 = first.min(last) - Vector2.ONE * 0.01
	var high: Vector2 = first.max(last) + Vector2.ONE * 0.01
	for grid_y in range(floori(low.y), floori(high.y) + 1):
		for grid_x in range(floori(low.x), floori(high.x) + 1):
			var cell := Vector2i(grid_x, grid_y)
			if data["segments"].has(cell):
				result.append([data["segments"][cell], data["segment_bounds"][cell]])
	return result


# Per-segment candidates near a query segment. Intersecting segments always
# share the cell of their intersection point, so this finds every crossing.
# Splits leave stale entries; callers must guard segment indices and retest
# with current link geometry.
static func segment_candidates(region, first: Vector2, last: Vector2) -> PackedInt32Array:
	var data: Dictionary = cache(region)
	var result := PackedInt32Array()
	var low: Vector2 = first.min(last) - Vector2.ONE * 0.01
	var high: Vector2 = first.max(last) + Vector2.ONE * 0.01
	for grid_y in range(floori(low.y), floori(high.y) + 1):
		for grid_x in range(floori(low.x), floori(high.x) + 1):
			var cell := Vector2i(grid_x, grid_y)
			if data["segments"].has(cell):
				result.append_array(data["segments"][cell])
	return result


static func index_node(data: Dictionary, node) -> void:
	var cell := Vector2i(floori(node.position_km.x / 0.02), floori(node.position_km.y / 0.02))
	if not data["nodes"].has(cell):
		data["nodes"][cell] = []
	data["nodes"][cell].append(node.id)


static func near_nodes(region, point: Vector2) -> Array:
	var data: Dictionary = cache(region)
	var cell := Vector2i(floori(point.x / 0.02), floori(point.y / 0.02))
	var result: Array = []
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			result.append_array(data["nodes"].get(cell + Vector2i(offset_x, offset_y), []))
	return result


static func near_links(region, point: Vector2) -> Array:
	return cache(region)["links"].get(Vector2i(floori(point.x), floori(point.y)), [])


static func pair_key(first: int, last: int, road_class: String) -> String:
	return "%d:%d:%s" % [mini(first, last), maxi(first, last), road_class]
