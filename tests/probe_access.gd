extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	var regional_arterials := 0
	for link in region.road_links:
		if link.road_class == "Arterial" and region.road_nodes[link.from_node_id].city_id != region.road_nodes[link.to_node_id].city_id:
			regional_arterials += 1
	print("regional cross-city arterials: ", regional_arterials)
	var highway_ids := {}
	for link in region.road_links:
		if link.road_class == "Highway":
			highway_ids[link.from_node_id] = true
			highway_ids[link.to_node_id] = true
	for city_id in region.starting_city_ids:
		var hub_id: int = region.city_hub_node_ids[city_id]
		var access_id: int = region.city_highway_access_node_ids[city_id]
		if access_id < 0:
			print("city ", city_id, ": NO ACCESS")
			continue
		var classes := {}
		for link in region.road_links:
			if link.from_node_id == access_id or link.to_node_id == access_id:
				classes[link.road_class] = classes.get(link.road_class, 0) + 1
		var flag := "ok"
		if access_id == hub_id or not region.road_nodes[access_id].is_interchange or classes.get("Arterial", 0) < 1:
			flag = "FAIL"
		print("city %d: access=%d %s classes=%s" % [city_id, access_id, flag, str(classes)])
		if flag == "FAIL":
			var node = region.road_nodes[access_id]
			print("  access node city_id=%d pos=%s is_interchange=%s" % [node.city_id, node.position_km, node.is_interchange])
			for link in region.road_links:
				if link.from_node_id == access_id or link.to_node_id == access_id:
					var other: int = link.to_node_id if link.from_node_id == access_id else link.from_node_id
					var other_classes := {}
					for probe_link in region.road_links:
						if (probe_link.from_node_id == other or probe_link.to_node_id == other) and probe_link.road_class == "Arterial":
							other_classes[other] = other_classes.get(other, 0) + 1
					print("  link %d: %s to node %d (city %d, %s) len %.1f km arterial_deg=%d" % [link.id, link.road_class, other, region.road_nodes[other].city_id, region.road_nodes[other].position_km, link.length_km, other_classes.get(other, 0)])
					if link.road_class == "Rural":
						var rural_other: int = other
						for probe_link in region.road_links:
							if (probe_link.from_node_id == rural_other or probe_link.to_node_id == rural_other) and probe_link.id != link.id:
								var third: int = probe_link.to_node_id if probe_link.from_node_id == rural_other else probe_link.from_node_id
								print("    node %d also has: %s to %d (city %d) len %.1f" % [rural_other, probe_link.road_class, third, region.road_nodes[third].city_id, probe_link.length_km])
			var costs = RoadGraph.free_flow_costs(region)
			var route: Array[Vector2i] = RoadGraph.route_from_node(region, costs, hub_id, access_id)
			var path_classes := {}
			for edge in route:
				var link = region.road_links[edge.x]
				path_classes[link.road_class] = path_classes.get(link.road_class, 0) + 1
			print("  hub->access route: %d edges, classes=%s" % [route.size(), str(path_classes)])
	quit(0)
