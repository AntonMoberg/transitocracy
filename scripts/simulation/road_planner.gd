extends RefCounted

const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadProjectData = preload("res://scripts/simulation/road_project_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")

const INTERCHANGE_COST = 10000000
const INTERCHANGE_UPKEEP = 1000.0
const BUILD_TIME_DIVISOR = 10.0
const DEMOLISH = "Demolish"


static func link_preview(region, from_id: int, to_id: int, road_class: String, waypoints: PackedVector2Array, day_key: int) -> Dictionary:
	if from_id < 0 or to_id < 0 or from_id >= region.road_nodes.size() or to_id >= region.road_nodes.size() or from_id == to_id:
		return {"ok": false, "reason": "Choose two different road nodes."}
	if road_class != RoadLinkData.ARTERIAL and road_class != RoadLinkData.HIGHWAY:
		return {"ok": false, "reason": "Unknown road class."}
	if road_class == RoadLinkData.HIGHWAY and (not region.road_nodes[from_id].is_interchange or not region.road_nodes[to_id].is_interchange):
		return {"ok": false, "reason": "Highways can connect only at active interchanges."}
	for link in region.road_links:
		if link.road_class == road_class and ((link.from_node_id == from_id and link.to_node_id == to_id) or (link.from_node_id == to_id and link.to_node_id == from_id)):
			return {"ok": false, "reason": "This road connection already exists."}
	for point in waypoints:
		if not _inside_map(point, region):
			return {"ok": false, "reason": "Keep road waypoints inside the region."}
	var from_tangent := Vector2.ZERO
	var to_tangent := Vector2.ZERO
	if road_class == RoadLinkData.HIGHWAY:
		from_tangent = -_single_highway_outward(region, from_id)
		to_tangent = _single_highway_outward(region, to_id)
	var points: PackedVector2Array = RoadRouteBuilder.build(region, from_id, to_id, road_class, waypoints, from_tangent, to_tangent)
	if points.size() < 2:
		return {"ok": false, "reason": "Road is too short."}
	if road_class == RoadLinkData.HIGHWAY:
		if RoadRouteBuilder.minimum_curve_radius(points) < RoadRouteBuilder.MIN_HIGHWAY_RADIUS_KM:
			return {"ok": false, "reason": "This highway needs a gentler curve. Adjust its route or interchanges."}
		if from_tangent != Vector2.ZERO and absf(rad_to_deg(from_tangent.angle_to(points[1] - points[0]))) > 0.25:
			return {"ok": false, "reason": "This highway cannot join smoothly at its first interchange. Adjust its route."}
		if to_tangent != Vector2.ZERO and absf(rad_to_deg(to_tangent.angle_to(points[-1] - points[-2]))) > 0.25:
			return {"ok": false, "reason": "This highway cannot join smoothly at its second interchange. Adjust its route."}
	var length := _length(points)
	if length < 0.1:
		return {"ok": false, "reason": "Road is too short."}
	var lanes := 2 if road_class == RoadLinkData.HIGHWAY else 1
	var cost := roundi(length * lanes * (1800000.0 if road_class == RoadLinkData.HIGHWAY else 600000.0))
	var base_days := maxi(45, ceili(20.0 + 4.0 * length)) if road_class == RoadLinkData.HIGHWAY else maxi(14, ceili(7.0 + 2.0 * length))
	var days := _construction_days(base_days)
	return {"ok": true, "kind": RoadProjectData.NEW_LINK, "from": from_id, "to": to_id, "road_class": road_class, "lanes": lanes, "waypoints": waypoints.duplicate(), "points": points, "length_km": length, "cost": cost, "days": days, "open_day_key": day_key + days, "owner_id": region.road_owner_for_points(points, road_class)}


static func widen_preview(region, link_id: int, day_key: int) -> Dictionary:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return {"ok": false, "reason": "Select an open road."}
	var link = region.road_links[index]
	var maximum := 5 if link.road_class == RoadLinkData.HIGHWAY else 3
	if link.lanes_per_direction >= maximum:
		return {"ok": false, "reason": "This road is already at its lane limit."}
	for project in region.road_projects:
		if project.target_link_id == link_id and (project.kind == RoadProjectData.WIDEN or project.kind == RoadProjectData.INTERCHANGE_EXIT):
			return {"ok": false, "reason": "A project is already under construction on this road."}
	var cost := roundi(link.length_km * (1800000.0 if link.road_class == RoadLinkData.HIGHWAY else 600000.0))
	var full_days := maxi(45, ceili(20.0 + 4.0 * link.length_km)) if link.road_class == RoadLinkData.HIGHWAY else maxi(14, ceili(7.0 + 2.0 * link.length_km))
	var days := _construction_days(maxi(7, ceili(float(full_days) * 0.5)))
	return {"ok": true, "kind": RoadProjectData.WIDEN, "target_link_id": link_id, "cost": cost, "days": days, "open_day_key": day_key + days, "lanes": link.lanes_per_direction + 1, "owner_id": link.owner_jurisdiction_id}


static func demolish_preview(region, link_id: int) -> Dictionary:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return {"ok": false, "reason": "Select an open road to demolish."}
	for project in region.road_projects:
		if project.target_link_id == link_id:
			return {"ok": false, "reason": "Finish construction on this road before demolishing it."}
	var link = region.road_links[index]
	return {
		"ok": true,
		"kind": DEMOLISH,
		"target_link_id": link_id,
		"road_class": link.road_class,
		"length_km": link.length_km,
		"upkeep_saved": link.length_km * link.lanes_per_direction * (600.0 if link.road_class == RoadLinkData.HIGHWAY else 200.0),
		"components_after": _neighborhood_components_without(region, link_id),
		"cost": 0,
	}


static func demolish(region, link_id: int) -> Dictionary:
	var preview: Dictionary = demolish_preview(region, link_id)
	if not preview["ok"]:
		return preview
	var index: int = RoadGraph.link_index(region, link_id)
	region.road_links.remove_at(index)
	region.road_geometry_revision += 1
	refresh_upkeep(region)
	return preview


static func interchange_preview(region, node_id: int, link_id: int, point: Vector2, day_key: int) -> Dictionary:
	if node_id >= 0:
		if node_id >= region.road_nodes.size() or region.road_nodes[node_id].is_interchange:
			return {"ok": false, "reason": "Choose a junction without an interchange."}
		for project in region.road_projects:
			if project.target_node_id == node_id and project.kind == RoadProjectData.INTERCHANGE_NODE:
				return {"ok": false, "reason": "An interchange is already being built here."}
		var days := _construction_days(45)
		var node_point: Vector2 = region.road_nodes[node_id].position_km
		var city_id: int = region.city_id_at_point(node_point)
		var owner_id: int = region.city_jurisdiction_ids[city_id] if city_id >= 0 else region.jurisdiction_at_point(node_point)
		return {"ok": true, "kind": RoadProjectData.INTERCHANGE_NODE, "target_node_id": node_id, "cost": INTERCHANGE_COST, "days": days, "open_day_key": day_key + days, "owner_id": owner_id}
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0 or region.road_links[index].road_class != RoadLinkData.HIGHWAY:
		return {"ok": false, "reason": "Choose a highway segment or a junction."}
	for project in region.road_projects:
		if project.target_link_id == link_id and (project.kind == RoadProjectData.WIDEN or project.kind == RoadProjectData.INTERCHANGE_EXIT):
			return {"ok": false, "reason": "A project is already under construction on this road."}
	var projected: Vector2 = closest_point(region.road_links[index].points, point)
	var link = region.road_links[index]
	if projected.distance_to(region.road_nodes[link.from_node_id].position_km) < 0.2 or projected.distance_to(region.road_nodes[link.to_node_id].position_km) < 0.2:
		return {"ok": false, "reason": "Place the exit farther from an existing road node."}
	var days := _construction_days(45)
	return {"ok": true, "kind": RoadProjectData.INTERCHANGE_EXIT, "target_link_id": link_id, "position_km": projected, "cost": INTERCHANGE_COST, "days": days, "open_day_key": day_key + days, "owner_id": link.owner_jurisdiction_id}


static func commit(region, preview: Dictionary, day_key: int) -> Dictionary:
	if not preview.get("ok", false):
		return {"ok": false, "reason": preview.get("reason", "Invalid road project.")}
	match preview["kind"]:
		RoadProjectData.NEW_LINK:
			preview = link_preview(region, preview["from"], preview["to"], preview["road_class"], preview.get("waypoints", PackedVector2Array()), day_key)
		RoadProjectData.WIDEN:
			preview = widen_preview(region, preview["target_link_id"], day_key)
		RoadProjectData.INTERCHANGE_NODE:
			preview = interchange_preview(region, preview["target_node_id"], -1, Vector2.ZERO, day_key)
		RoadProjectData.INTERCHANGE_EXIT:
			preview = interchange_preview(region, -1, preview["target_link_id"], preview["position_km"], day_key)
	if not preview.get("ok", false):
		return {"ok": false, "reason": preview.get("reason", "Road network changed; choose this project again.")}
	var owner_id: int = int(preview["owner_id"])
	if region.jurisdictions[owner_id].treasury < float(preview["cost"]):
		return {"ok": false, "reason": "Insufficient treasury funds."}
	var project = RoadProjectData.new()
	project.id = region.next_road_project_id
	region.next_road_project_id += 1
	project.kind = preview["kind"]
	project.cost = preview["cost"]
	project.start_day_key = day_key
	project.open_day_key = day_key + int(preview["days"])
	project.owner_jurisdiction_id = owner_id
	match project.kind:
		RoadProjectData.NEW_LINK:
			project.from_node_id = preview["from"]
			project.to_node_id = preview["to"]
			project.road_class = preview["road_class"]
			project.lanes_per_direction = preview["lanes"]
			project.points = preview["points"]
		RoadProjectData.WIDEN, RoadProjectData.INTERCHANGE_EXIT:
			project.target_link_id = preview["target_link_id"]
			if project.kind == RoadProjectData.INTERCHANGE_EXIT:
				project.position_km = preview["position_km"]
		RoadProjectData.INTERCHANGE_NODE:
			project.target_node_id = preview["target_node_id"]
	region.jurisdictions[owner_id].treasury -= float(project.cost)
	region.road_projects.append(project)
	return {"ok": true, "project": project}


static func add_junction(region, point: Vector2, split_link_id: int = -1) -> Dictionary:
	if not _inside_map(point, region):
		return {"ok": false, "reason": "Place junctions inside the region."}
	if split_link_id >= 0:
		var index: int = RoadGraph.link_index(region, split_link_id)
		if index < 0 or region.road_links[index].road_class != RoadLinkData.ARTERIAL:
			return {"ok": false, "reason": "Junctions can split arterial roads; use an interchange for highways."}
		for project in region.road_projects:
			if project.target_link_id == split_link_id and project.kind == RoadProjectData.WIDEN:
				return {"ok": false, "reason": "Wait for this road's widening to finish."}
		point = closest_point(region.road_links[index].points, point)
		var old_link = region.road_links[index]
		if point.distance_to(region.road_nodes[old_link.from_node_id].position_km) < 0.2 or point.distance_to(region.road_nodes[old_link.to_node_id].position_km) < 0.2:
			return {"ok": false, "reason": "Place the junction farther from an existing node."}
	else:
		for node in region.road_nodes:
			if node.position_km.distance_to(point) < 0.2:
				return {"ok": false, "reason": "A road node is already here."}
	var junction = RoadNodeData.new()
	junction.id = region.road_nodes.size()
	junction.position_km = point
	junction.city_id = region.city_id_at_point(point)
	region.road_nodes.append(junction)
	region.road_geometry_revision += 1
	if split_link_id >= 0:
		_split_link(region, split_link_id, junction.id, point)
	refresh_upkeep(region)
	return {"ok": true, "node_id": junction.id}


static func advance_day(region, day_key: int) -> bool:
	# Yesterday's tax estimate accrues before today's migration changes households.
	refresh_upkeep(region)
	for area in region.jurisdictions:
		area.last_fiscal_change = area.daily_net()
		area.treasury += area.last_fiscal_change
		area.daily_sales_revenue = 0.0
		area.daily_fee_revenue = 0.0
	var changed := false
	var remaining: Array = []
	for project in region.road_projects:
		if project.open_day_key > day_key:
			remaining.append(project)
			continue
		match project.kind:
			RoadProjectData.NEW_LINK:
				_append_link(region, project.from_node_id, project.to_node_id, project.road_class, project.lanes_per_direction, project.points, project.owner_jurisdiction_id)
			RoadProjectData.WIDEN:
				var index: int = RoadGraph.link_index(region, project.target_link_id)
				if index >= 0:
					region.road_links[index].lanes_per_direction += 1
			RoadProjectData.INTERCHANGE_NODE:
				region.road_nodes[project.target_node_id].is_interchange = true
				region.road_nodes[project.target_node_id].interchange_owner_jurisdiction_id = project.owner_jurisdiction_id
			RoadProjectData.INTERCHANGE_EXIT:
				var exit_node = RoadNodeData.new()
				exit_node.id = region.road_nodes.size()
				exit_node.position_km = project.position_km
				exit_node.city_id = region.city_id_at_point(project.position_km)
				exit_node.is_interchange = true
				exit_node.interchange_owner_jurisdiction_id = project.owner_jurisdiction_id
				region.road_nodes.append(exit_node)
				_split_link(region, project.target_link_id, exit_node.id, project.position_km)
		changed = true
	region.road_projects = remaining
	if changed:
		region.road_geometry_revision += 1
		refresh_upkeep(region)
	return changed


static func refresh_upkeep(region) -> void:
	for area in region.jurisdictions:
		area.daily_road_upkeep = 0.0
	for link in region.road_links:
		region.jurisdictions[link.owner_jurisdiction_id].daily_road_upkeep += link.length_km * link.lanes_per_direction * (600.0 if link.road_class == RoadLinkData.HIGHWAY else 200.0)
	for node in region.road_nodes:
		if node.is_interchange:
			var owner_id: int = node.interchange_owner_jurisdiction_id
			if owner_id < 0:
				var city_id: int = region.city_id_at_point(node.position_km)
				owner_id = region.city_jurisdiction_ids[city_id] if city_id >= 0 else region.jurisdiction_at_point(node.position_km)
			region.jurisdictions[owner_id].daily_road_upkeep += INTERCHANGE_UPKEEP
	refresh_regional_grants(region)


static func refresh_regional_grants(region) -> void:
	var state = region.jurisdictions[0]
	state.daily_transfer_expense = 0.0
	var capital_share: float = maxf(0.0, state.daily_income_revenue) * 0.20 / float(maxi(1, region.region_ids.size()))
	for region_id in region.region_ids:
		var area = region.jurisdictions[region_id]
		area.daily_grant_revenue = area.daily_road_upkeep + capital_share
		state.daily_transfer_expense += area.daily_grant_revenue


static func calculate_upkeep(region) -> float:
	var total := 0.0
	for link in region.road_links:
		total += link.length_km * link.lanes_per_direction * (600.0 if link.road_class == RoadLinkData.HIGHWAY else 200.0)
	for node in region.road_nodes:
		if node.is_interchange:
			total += INTERCHANGE_UPKEEP
	return total


static func closest_point(points: PackedVector2Array, point: Vector2) -> Vector2:
	var best := points[0]
	var best_distance := INF
	for index in range(1, points.size()):
		var candidate: Vector2 = Geometry2D.get_closest_point_to_segment(point, points[index - 1], points[index])
		var distance := candidate.distance_squared_to(point)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


static func _split_link(region, link_id: int, new_node_id: int, point: Vector2) -> void:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return
	var old_link = region.road_links[index]
	var split_segment := 1
	var best_distance := INF
	for segment in range(1, old_link.points.size()):
		var distance: float = Geometry2D.get_closest_point_to_segment(point, old_link.points[segment - 1], old_link.points[segment]).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			split_segment = segment
	var first := PackedVector2Array()
	var second := PackedVector2Array([point])
	for i in range(split_segment):
		first.append(old_link.points[i])
	first.append(point)
	for i in range(split_segment, old_link.points.size()):
		second.append(old_link.points[i])
	var old_to: int = old_link.to_node_id
	old_link.to_node_id = new_node_id
	old_link.points = first
	old_link.recalculate_length()
	_append_link(region, new_node_id, old_to, old_link.road_class, old_link.lanes_per_direction, second, old_link.owner_jurisdiction_id)
	region.road_links[-1].toll_forward = old_link.toll_forward
	region.road_links[-1].toll_reverse = old_link.toll_reverse


static func _append_link(region, from_id: int, to_id: int, road_class: String, lanes: int, points: PackedVector2Array, owner_id: int) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = points
	link.recalculate_length()
	link.owner_jurisdiction_id = owner_id
	region.road_links.append(link)


static func _length(points: PackedVector2Array) -> float:
	var result := 0.0
	for index in range(1, points.size()):
		result += points[index - 1].distance_to(points[index])
	return result


static func _single_highway_outward(region, node_id: int) -> Vector2:
	var count := 0
	var outward := Vector2.ZERO
	for link in region.road_links:
		if link.road_class != RoadLinkData.HIGHWAY:
			continue
		if link.from_node_id == node_id:
			count += 1
			outward = link.points[1] - link.points[0]
		elif link.to_node_id == node_id:
			count += 1
			outward = link.points[-2] - link.points[-1]
	for project in region.road_projects:
		if project.kind != RoadProjectData.NEW_LINK or project.road_class != RoadLinkData.HIGHWAY:
			continue
		if project.from_node_id == node_id:
			count += 1
			outward = project.points[1] - project.points[0]
		elif project.to_node_id == node_id:
			count += 1
			outward = project.points[-2] - project.points[-1]
	return outward.normalized() if count == 1 else Vector2.ZERO


static func _construction_days(base_days: int) -> int:
	return maxi(1, ceili(float(base_days) / BUILD_TIME_DIVISOR))


static func _inside_map(point: Vector2, region) -> bool:
	return region.jurisdictions[0].contains_point(point)


static func _neighborhood_components_without(region, excluded_link_id: int) -> int:
	var neighbors: Array = RoadGraph.adjacency(region)
	var visited := PackedByteArray()
	visited.resize(region.road_nodes.size())
	var components := 0
	for gateway_id in region.neighborhood_gateway_node_ids:
		if visited[gateway_id] != 0:
			continue
		components += 1
		var frontier: Array[int] = [gateway_id]
		visited[gateway_id] = 1
		while not frontier.is_empty():
			var current: int = frontier.pop_back()
			for edge in neighbors[current]:
				var link = region.road_links[edge.x]
				if link.id == excluded_link_id:
					continue
				var neighbor: int = link.to_node_id if edge.y == 0 else link.from_node_id
				if visited[neighbor] == 0:
					visited[neighbor] = 1
					frontier.append(neighbor)
	return components
