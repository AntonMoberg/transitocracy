extends RefCounted

const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const Planner = preload("res://scripts/simulation/road_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")


static func attach(region, neighborhood, layout, completed: bool = false) -> void:
	neighborhood.street_layout = layout
	var plan = Plan.new()
	plan.target_housing = neighborhood.housing_capacity
	plan.target_jobs = neighborhood.job_capacity
	plan.design_demand = maxf(1.0, float(plan.target_housing) * 2.0 + float(plan.target_jobs))
	plan.target_jobs_by_skill = neighborhood.development_jobs_by_skill.duplicate()
	plan.target_retail_share = neighborhood.development_retail_share
	neighborhood.development_plan = plan
	var area = region.jurisdictions[neighborhood.jurisdiction_id]
	area.polygon_km = layout.polygon
	Geography.update_bounds(area)
	neighborhood.position_km = area.center_km
	neighborhood.land_area_ha = Geography.polygon_area(layout.polygon) * 100.0
	neighborhood.developable_area_ha = minf(neighborhood.developable_area_ha, neighborhood.land_area_ha)
	if completed:
		open_phase(region, neighborhood, 3)
		plan.status = "Completed"
		LayoutGenerator.update_buildings(neighborhood)


static func ensure_node(region, point: Vector2, city_id: int, preferred_id: int = -1) -> int:
	var nearest_id := -1
	var nearest_distance := 0.001
	for node_id in Spatial.near_nodes(region, point):
		var node = region.road_nodes[node_id]
		var distance: float = node.position_km.distance_to(point)
		if distance < nearest_distance:
			nearest_id = node.id
			nearest_distance = distance
	if nearest_id >= 0:
		return nearest_id
	var arterial_id := -1
	var nearest: Vector2 = point
	for link_index in Spatial.near_links(region, point):
		var link = region.road_links[link_index]
		if link.road_class not in [Roads.ARTERIAL, Roads.COLLECTOR]:
			continue
		var trial: Vector2 = Planner.closest_point(link.points, point)
		if trial.distance_to(point) < 0.002:
			for endpoint_id in [link.from_node_id, link.to_node_id]:
				if region.road_nodes[endpoint_id].position_km.distance_to(trial) < 0.005:
					return endpoint_id
			arterial_id = link.id
			nearest = trial
			break
	if preferred_id >= 0 and Spatial.cache(region)["used_nodes"].has(preferred_id):
		preferred_id = -1
	var node = region.road_nodes[preferred_id] if preferred_id >= 0 else RoadNode.new()
	if preferred_id < 0:
		node.id = region.road_nodes.size()
		region.road_nodes.append(node)
	node.position_km = nearest
	node.city_id = city_id
	Spatial.index_node(Spatial.cache(region), node)
	if arterial_id >= 0:
		Planner._split_link(region, arterial_id, node.id, nearest)
	return node.id


static func open_phase(region, neighborhood, phase: int) -> bool:
	var layout = neighborhood.street_layout
	var plan = neighborhood.development_plan
	if layout == null or plan == null:
		return false
	var reused_gateway: bool = not plan.core_node_ids.is_empty()
	var paid_multiplier: float = maxf(plan.installed_multiplier, plan.constructing_multiplier) if plan.constructing_phase > 0 else plan.installed_multiplier
	for path_index in range(layout.core_paths.size()):
		var path: Dictionary = layout.core_paths[path_index]
		if int(path["phase"]) > phase or plan.core_link_ids.has(path_index):
			continue
		for local_id in [int(path["from"]), int(path["to"])]:
			if plan.core_node_ids.has(local_id):
				continue
			var preferred := -1
			if not reused_gateway and not layout.arterial_nodes.has(local_id):
				preferred = region.neighborhood_gateway_node_ids[neighborhood.id]
				reused_gateway = true
			var global_id: int = ensure_node(region, layout.nodes[local_id], neighborhood.city_id, preferred)
			plan.core_node_ids[local_id] = global_id
			if not layout.arterial_nodes.has(local_id) and not neighborhood.access_node_ids.has(global_id):
				neighborhood.access_node_ids.append(global_id)
				if not region.road_nodes[global_id].is_interchange and region.road_nodes[global_id].kind != "City":
					region.road_nodes[global_id].managed_neighborhood_id = neighborhood.id
		var first: int = plan.core_node_ids[path["from"]]
		var last: int = plan.core_node_ids[path["to"]]
		if first == last:
			continue
		var existing_index: int = Spatial.cache(region)["pairs"].get(Spatial.pair_key(first, last, Roads.COLLECTOR), -1)
		var existing_id: int = region.road_links[existing_index].id if existing_index >= 0 else -1
		if existing_id >= 0:
			plan.core_link_ids[path_index] = existing_id
			continue
		var link = Roads.new()
		link.id = region.next_road_link_id
		region.next_road_link_id += 1
		link.from_node_id = first
		link.to_node_id = last
		link.road_class = Roads.COLLECTOR
		link.lanes_per_direction = ceili(paid_multiplier)
		link.points = path["points"]
		link.owner_jurisdiction_id = region.city_jurisdiction_ids[neighborhood.city_id]
		link.managed_neighborhood_id = neighborhood.id
		link.recalculate_length()
		region.road_links.append(link)
		plan.core_link_ids[path_index] = link.id
	if neighborhood.access_node_ids.size() < 2:
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.COLLECTOR or layout.phases[edge_id] > phase:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			for local_id in [int(edge.x), int(edge.y)]:
				if plan.core_node_ids.has(local_id) or layout.arterial_nodes.has(local_id):
					continue
				var node_id: int = ensure_node(region, layout.nodes[local_id], neighborhood.city_id)
				plan.core_node_ids[local_id] = node_id
				if not neighborhood.access_node_ids.has(node_id):
					neighborhood.access_node_ids.append(node_id)
					if not region.road_nodes[node_id].is_interchange and region.road_nodes[node_id].kind != "City":
						region.road_nodes[node_id].managed_neighborhood_id = neighborhood.id
				if neighborhood.access_node_ids.size() >= 2:
					break
			if neighborhood.access_node_ids.size() >= 2:
				break
	plan.installed_multiplier = paid_multiplier
	plan.completed_phase = phase
	plan.constructing_phase = 0
	plan.open_day = -1
	if not neighborhood.access_node_ids.is_empty():
		region.neighborhood_gateway_node_ids[neighborhood.id] = neighborhood.access_node_ids[0]
	region.neighborhood_spoke_link_ids[neighborhood.id] = -1
	region.road_geometry_revision += 1
	return true
