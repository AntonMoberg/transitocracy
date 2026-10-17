extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")


static func generate(region) -> void:
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.city_hub_node_ids.clear()
	region.city_route_node_ids.clear()
	region.neighborhood_development_connected.clear()
	region.neighborhood_spoke_link_ids.clear()
	region.next_road_link_id = 0
	region.next_road_project_id = 0
	for neighborhood in region.neighborhoods:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = neighborhood.position_km
		node.kind = "Neighborhood"
		node.neighborhood_id = neighborhood.id
		node.city_id = neighborhood.city_id
		region.road_nodes.append(node)
		region.neighborhood_gateway_node_ids.append(node.id)
		region.neighborhood_spoke_link_ids.append(-1)
	for city in region.cities:
		var hub = RoadNodeData.new()
		hub.id = region.road_nodes.size()
		hub.position_km = city["center_km"]
		hub.kind = "City"
		hub.city_id = city["id"]
		hub.is_interchange = region.starting_city_ids.has(city["id"])
		region.road_nodes.append(hub)
		region.city_hub_node_ids.append(hub.id)
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed:
			continue
		_add_link(region, region.neighborhood_gateway_node_ids[neighborhood.id], region.city_hub_node_ids[neighborhood.city_id], RoadLinkData.ARTERIAL, 1)
		region.neighborhood_spoke_link_ids[neighborhood.id] = region.next_road_link_id - 1
	var connected: Array[int] = [region.starting_city_ids[0]]
	while connected.size() < region.starting_city_ids.size():
		var best_from := -1
		var best_to := -1
		var best_distance := INF
		for from_city in connected:
			for to_city in region.starting_city_ids:
				if connected.has(to_city):
					continue
				var distance: float = region.cities[from_city]["center_km"].distance_squared_to(region.cities[to_city]["center_km"])
				if distance < best_distance:
					best_distance = distance
					best_from = from_city
					best_to = to_city
		_add_link(region, region.city_hub_node_ids[best_from], region.city_hub_node_ids[best_to], RoadLinkData.HIGHWAY, 2)
		connected.append(best_to)


static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = StateGeography.land_route(region.jurisdictions[0].polygon_km, region.road_nodes[from_id].position_km, region.road_nodes[to_id].position_km)
	link.recalculate_length()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points)
	region.road_links.append(link)
