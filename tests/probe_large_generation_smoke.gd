extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	var cities := 256
	for argument in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if argument.begins_with("cities="):
			cities = int(argument.split("=")[1])
	var started: int = Time.get_ticks_msec()
	var region = RegionGenerator.generate_region(1729) if cities == 32 else RegionGenerator.generate_large_region(1729, cities)
	print("region: %d ms cities=%d" % [Time.get_ticks_msec() - started, region.cities.size()])
	RoadNetworkGenerator.generate(region)
	print("roads: %d ms links=%d nodes=%d" % [Time.get_ticks_msec() - started, region.road_links.size(), region.road_nodes.size()])
	var counts := {}
	var length := 0.0
	for link in region.road_links:
		counts[link.road_class] = int(counts.get(link.road_class, 0)) + 1
		length += link.length_km
	print("class counts: ", counts, " total length=%.0f km" % length)
	var adjacency_view: Dictionary = RoadGraph.adjacency(region)
	var adjacency: Array = adjacency_view["neighbors"]
	var adjacency_edge_from: PackedInt32Array = adjacency_view["edge_from"]
	var adjacency_edge_to: PackedInt32Array = adjacency_view["edge_to"]
	var visited := PackedByteArray()
	visited.resize(region.road_nodes.size())
	var queue := PackedInt32Array([region.city_hub_node_ids[region.starting_city_ids[0]]])
	visited[queue[0]] = 1
	var cursor := 0
	while cursor < queue.size():
		var node_id: int = queue[cursor]
		cursor += 1
		for edge in adjacency[node_id]:
			var next_id: int = adjacency_edge_to[edge.x] if edge.y == 0 else adjacency_edge_from[edge.x]
			if visited[next_id] == 0:
				visited[next_id] = 1
				queue.append(next_id)
	var connected_cities := 0
	for city_id in region.starting_city_ids:
		if visited[region.city_hub_node_ids[city_id]] != 0:
			connected_cities += 1
	print("starting cities connected to first hub: %d / %d" % [connected_cities, region.starting_city_ids.size()])
	quit(0)
