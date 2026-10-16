extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")


static func generate(region) -> void:
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.city_hub_node_ids.clear()
	region.neighborhood_spoke_link_ids.clear()
	region.next_road_link_id = 0
	region.next_road_project_id = 0
	if region.is_large_scale:
		_generate_large_network(region)
		return
	for neighborhood in region.neighborhoods:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = neighborhood.position_km
		node.kind = "Neighborhood"
		node.neighborhood_id = neighborhood.id
		node.city_id = neighborhood.city_id
		region.road_nodes.append(node)
		region.neighborhood_gateway_node_ids.append(node.id)
	for city in region.cities:
		var hub = RoadNodeData.new()
		hub.id = region.road_nodes.size()
		hub.position_km = city["center_km"]
		hub.kind = "City"
		hub.city_id = city["id"]
		region.road_nodes.append(hub)
		region.city_hub_node_ids.append(hub.id)
	# A minimum-length spanning tree gives every neighborhood a road route while
	# leaving all redundant links and higher-capacity corridors to the player.
	var connected := PackedByteArray()
	connected.resize(region.road_nodes.size())
	connected[0] = 1
	for _edge in range(region.road_nodes.size() - 1):
		var best_from := -1
		var best_to := -1
		var best_distance := INF
		for from_id in range(region.road_nodes.size()):
			if connected[from_id] == 0:
				continue
			for to_id in range(region.road_nodes.size()):
				if connected[to_id] != 0:
					continue
				var distance: float = region.road_nodes[from_id].position_km.distance_squared_to(region.road_nodes[to_id].position_km)
				if distance < best_distance:
					best_distance = distance
					best_from = from_id
					best_to = to_id
		_add_link(region, best_from, best_to, RoadLinkData.ARTERIAL, 1)
		connected[best_to] = 1


static func _generate_large_network(region) -> void:
	# Neighborhood spokes and a connected city-hub tree avoid the cubic
	# minimum-spanning search used by the small prototype map.
	for neighborhood in region.neighborhoods:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = neighborhood.position_km
		node.kind = "Neighborhood"
		node.neighborhood_id = neighborhood.id
		node.city_id = neighborhood.city_id
		region.road_nodes.append(node)
		region.neighborhood_gateway_node_ids.append(node.id)
	var city_hub_start: int = region.road_nodes.size()
	for city in region.cities:
		var hub = RoadNodeData.new()
		hub.id = region.road_nodes.size()
		hub.position_km = city["center_km"]
		hub.kind = "City"
		hub.city_id = city["id"]
		region.road_nodes.append(hub)
		region.city_hub_node_ids.append(hub.id)
	for neighborhood in region.neighborhoods:
		_add_link(region, neighborhood.id, city_hub_start + neighborhood.city_id, RoadLinkData.ARTERIAL, 1, region.city_jurisdiction_ids[neighborhood.city_id])
		region.neighborhood_spoke_link_ids.append(region.next_road_link_id - 1)
	for city_id in range(1, region.cities.size()):
		var nearest_id: int = 0
		var nearest_distance: float = INF
		for previous_id in range(city_id):
			var distance: float = region.cities[city_id]["center_km"].distance_squared_to(region.cities[previous_id]["center_km"])
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_id = previous_id
		var owner_id: int = region.funded_jurisdiction(region.city_jurisdiction_ids[city_id], region.city_jurisdiction_ids[nearest_id])
		_add_link(region, city_hub_start + nearest_id, city_hub_start + city_id, RoadLinkData.ARTERIAL, 1, owner_id)


static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int, owner_id: int = -1) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = PackedVector2Array([region.road_nodes[from_id].position_km, region.road_nodes[to_id].position_km])
	link.recalculate_length()
	link.owner_jurisdiction_id = owner_id if owner_id >= 0 else region.road_owner_for_points(link.points)
	region.road_links.append(link)
