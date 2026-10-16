extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")


static func generate(region) -> void:
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.next_road_link_id = 0
	region.next_road_project_id = 0
	region.treasury = 100000000.0
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


static func _add_link(region, from_id: int, to_id: int, road_class: String, lanes: int) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = PackedVector2Array([region.road_nodes[from_id].position_km, region.road_nodes[to_id].position_km])
	link.recalculate_length()
	region.road_links.append(link)
