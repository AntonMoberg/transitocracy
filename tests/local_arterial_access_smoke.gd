extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionData.new()
	region.city_jurisdiction_ids.assign([0])
	region.starting_city_ids.assign([0])
	region.city_hub_node_ids.assign([0])
	region.neighborhood_gateway_node_ids.assign([-1])
	region.neighborhood_spoke_link_ids.assign([-1])
	for position in [Vector2(0.0, 0.0), Vector2(2.0, 0.0)]:
		var node = NodeData.new()
		node.id = region.road_nodes.size()
		node.city_id = 0
		node.position_km = position
		region.road_nodes.append(node)
	var arterial = Roads.new()
	arterial.id = 0
	arterial.from_node_id = 0
	arterial.to_node_id = 1
	arterial.road_class = Roads.ARTERIAL
	arterial.points = PackedVector2Array([Vector2(0.0, 0.0), Vector2(2.0, 0.0)])
	arterial.recalculate_length()
	region.road_links.append(arterial)
	region.next_road_link_id = 1
	var layout = Layout.new()
	layout.city_id = 0
	layout.nodes = PackedVector2Array([Vector2(1.0, -0.1), Vector2(1.0, 0.1)])
	LayoutGenerator._append_edge(layout, 0, 1, Roads.LOCAL, 2)
	UrbanGraph._connect_local_arterials(region, layout, {})
	if layout.edges.size() != 2 or layout.arterial_nodes.size() != 1:
		_fail("A local road crossing an arterial was not split at the intersection.")
		return
	var crossing_id: int = layout.arterial_nodes[0]
	if layout.nodes[crossing_id].distance_to(Vector2(1.0, 0.0)) > 0.0001:
		_fail("The local road junction missed the arterial.")
		return
	var neighborhood = Neighborhood.new()
	neighborhood.id = 0
	neighborhood.city_id = 0
	neighborhood.street_layout = layout
	neighborhood.development_plan = Plan.new()
	region.neighborhoods.append(neighborhood)
	StreetNetwork.open_phase(region, neighborhood, 2)
	if not neighborhood.development_plan.core_node_ids.has(crossing_id) or region.road_links.size() != 2:
		_fail("The local crossing did not split the arterial road graph.")
		return
	var node_id: int = neighborhood.development_plan.core_node_ids[crossing_id]
	if RoadGraph.nodes_connected_to_start(region)[node_id] == 0:
		_fail("The local road junction is not routed onto the arterial.")
		return
	print("Local road crossings form real arterial junctions and traffic portals.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
