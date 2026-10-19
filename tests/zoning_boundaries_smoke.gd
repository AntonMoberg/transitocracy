extends SceneTree

const Region = preload("res://scripts/simulation/region_data.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const NodeData = preload("res://scripts/simulation/road_node_data.gd")
const LinkData = preload("res://scripts/simulation/road_link_data.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Region.new()
	region.generation_seed = 1729
	var state = Jurisdiction.new()
	state.id = 0
	state.kind = "State"
	state.polygon_km = PackedVector2Array([Vector2(0, 0), Vector2(7, 0), Vector2(7, 7), Vector2(0, 7)])
	Geography.update_bounds(state)
	region.jurisdictions.append(state)
	var city = Jurisdiction.new()
	city.id = 1
	city.kind = "City"
	city.parent_id = 0
	city.polygon_km = state.polygon_km
	Geography.update_bounds(city)
	region.jurisdictions.append(city)
	region.city_jurisdiction_ids.append(1)
	region.starting_city_ids.append(0)
	region.city_hub_node_ids.append(0)
	for point in [Vector2(1, 3), Vector2(5.8, 3)]:
		var node = NodeData.new()
		node.id = region.road_nodes.size()
		node.city_id = 0
		node.position_km = point
		region.road_nodes.append(node)
	var road = LinkData.new()
	road.id = 0
	road.from_node_id = 0
	road.to_node_id = 1
	road.road_class = LinkData.ARTERIAL
	road.points = PackedVector2Array([region.road_nodes[0].position_km, region.road_nodes[1].position_km])
	road.recalculate_length()
	region.road_links.append(road)
	var started: int = Time.get_ticks_usec()
	Planner.refresh_candidates(region)
	print("Open-road zoning: %d candidates in %.1f ms" % [region.development_candidates.size(), float(Time.get_ticks_usec() - started) / 1000.0])
	var north := 0
	var south := 0
	var irregular := 0
	var collector_access := 0
	var through := 0
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0:
			continue
		var polygon: PackedVector2Array = candidate["polygon"]
		var low := INF
		var high := -INF
		for vertex in polygon:
			low = minf(low, vertex.y)
			high = maxf(high, vertex.y)
		if not candidate["layout_input"]["edge_frontage"]:
			through += 1
		else:
			if low < 2.999 and high > 3.001:
				push_error("An edge-frontage candidate spans both sides of its arterial.")
				quit(1)
				return
			if low >= 2.999:
				north += 1
			else:
				south += 1
		if polygon.size() > 4:
			irregular += 1
		for path in candidate["layout"].core_paths:
			if path.get("road_class", LinkData.COLLECTOR) == LinkData.COLLECTOR and int(path["phase"]) == 1 and (candidate["layout"].arterial_nodes.has(path["from"]) or candidate["layout"].arterial_nodes.has(path["to"])):
				collector_access += 1
	if north == 0 or south == 0 or irregular == 0 or collector_access == 0 or through >= north + south:
		push_error("Both sides need mostly separate irregular candidates with collector access: %d, %d, %d, %d, %d through." % [north, south, irregular, collector_access, through])
		quit(1)
		return
	var occupied = Neighborhood.new()
	occupied.id = 0
	occupied.city_id = 0
	var layout = Layout.new()
	layout.key = "existing"
	layout.city_id = 0
	layout.polygon = PackedVector2Array([Vector2(1.5, 3.7), Vector2(5.2, 3.7), Vector2(5.2, 4.3), Vector2(1.5, 4.3)])
	layout.bounds = Geography._bounds(layout.polygon)
	layout.nodes = PackedVector2Array([Vector2(1.5, 3)])
	layout.arterial_nodes = PackedInt32Array([0])
	occupied.street_layout = layout
	region.neighborhoods.append(occupied)
	Planner.refresh_candidates(region)
	var fitted := false
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0:
			continue
		if not Geometry2D.intersect_polygons(candidate["polygon"], layout.polygon).is_empty():
			push_error("New zoning overlaps a neighboring district.")
			quit(1)
			return
		for vertex in candidate["polygon"]:
			if absf(vertex.y - 3.7) < 0.002 and vertex.x >= 1.5 and vertex.x <= 5.2:
				fitted = true
	if not fitted:
		push_error("New zoning did not fill the strip between the arterial and existing district.")
		quit(1)
		return
	print("One-sided cell boundaries and neighboring-district fit passed.")
	quit(0)
