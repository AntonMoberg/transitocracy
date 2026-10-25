extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")


func _initialize() -> void:
	var started: int = Time.get_ticks_msec()
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	print("generated: %d ms links=%d" % [Time.get_ticks_msec() - started, region.road_links.size()])
	var counts := {}
	for link in region.road_links:
		counts[link.road_class] = int(counts.get(link.road_class, 0)) + 1
	print("class counts: ", counts)
	AccessibilityCalculator.recalculate(region)
	print("accessibility: %d ms" % [Time.get_ticks_msec() - started])
	NeighborhoodDynamics.initialize(region)
	print("dynamics: %d ms" % [Time.get_ticks_msec() - started])
	var clock = CalendarClock.new()
	var day_key: int = clock.unix_seconds / 86400
	var interchange: Dictionary = RoadPlanner.interchange_preview(region, region.neighborhood_gateway_node_ids[0], -1, Vector2.ZERO, day_key)
	print("interchange ok=%s: %d ms" % [interchange.get("ok", false), Time.get_ticks_msec() - started])
	var upkeep: float = RoadPlanner.calculate_upkeep(region)
	print("upkeep=%f: %d ms" % [upkeep, Time.get_ticks_msec() - started])
	var adjacency_view: Dictionary = RoadGraph.adjacency(region)
	var adjacency: Array = adjacency_view["neighbors"]
	var adjacency_edge_from: PackedInt32Array = adjacency_view["edge_from"]
	var adjacency_edge_to: PackedInt32Array = adjacency_view["edge_to"]
	print("adjacency: %d ms" % [Time.get_ticks_msec() - started])
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
