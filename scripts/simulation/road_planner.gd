extends RefCounted

const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadProjectData = preload("res://scripts/simulation/road_project_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const RoadTerrain = preload("res://scripts/simulation/road_terrain.gd")
const StreetSpatial = preload("res://scripts/simulation/street_spatial_index.gd")

const INTERCHANGE_COST = 10000000
const INTERCHANGE_UPKEEP = 1000.0
const BUILD_TIME_DIVISOR = 10.0
const DEMOLISH = "Demolish"

static var surface_phase_us: Dictionary = {}


static func link_preview(region, from_id: int, to_id: int, road_class: String, waypoints: PackedVector2Array, day_key: int, draw_mode: String = RoadRouteBuilder.AUTO, end_position: Vector2 = Vector2.ZERO, crossing_choices: Dictionary = {}) -> Dictionary:
	if from_id < 0 or from_id >= region.road_nodes.size() or to_id < -1 or to_id >= region.road_nodes.size() or from_id == to_id or (to_id < 0 and (road_class == RoadLinkData.HIGHWAY or draw_mode == RoadRouteBuilder.AUTO)):
		return {"ok": false, "reason": "Choose two different road nodes."}
	if road_class != RoadLinkData.ARTERIAL and road_class != RoadLinkData.HIGHWAY:
		return {"ok": false, "reason": "Unknown road class."}
	if road_class == RoadLinkData.HIGHWAY and (not region.road_nodes[from_id].is_interchange or not region.road_nodes[to_id].is_interchange):
		return {"ok": false, "reason": "Highways can connect only at active interchanges."}
	if to_id < 0 and not _inside_map(end_position, region):
		return {"ok": false, "reason": "Keep the end junction inside the region."}
	if to_id < 0:
		for node in region.road_nodes:
			if node.position_km.distance_to(end_position) < 0.2:
				return {"ok": false, "reason": "Use the nearby existing node to finish this road."}
	for link in region.road_links:
		if link.road_class == road_class and ((link.from_node_id == from_id and link.to_node_id == to_id) or (link.from_node_id == to_id and link.to_node_id == from_id)):
			return {"ok": false, "reason": "This road connection already exists."}
	for point in waypoints:
		if draw_mode == RoadRouteBuilder.AUTO and not _inside_map(point, region):
			return {"ok": false, "reason": "Keep road waypoints inside the region."}
	var finish: Vector2 = region.road_nodes[to_id].position_km if to_id >= 0 else end_position
	var from_tangent := Vector2.ZERO
	var to_tangent := Vector2.ZERO
	if road_class == RoadLinkData.HIGHWAY:
		from_tangent = -_single_highway_outward(region, from_id)
		to_tangent = _single_highway_outward(region, to_id)
	elif draw_mode in [RoadRouteBuilder.CURVED, RoadRouteBuilder.MULTIPOINT]:
		from_tangent = arterial_continuation(region, from_id, waypoints[0] if not waypoints.is_empty() else finish)
	var points: PackedVector2Array = RoadRouteBuilder.build(region, from_id, to_id, road_class, waypoints, from_tangent, to_tangent) if draw_mode == RoadRouteBuilder.AUTO else player_route(region, from_id, finish, road_class, waypoints, draw_mode, to_id)
	if points.size() < 2:
		return {"ok": false, "reason": "This route needs valid guide points and must stay on land."}
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
	var terrain_impact: Dictionary = RoadTerrain.preview(region, points, road_class)
	if not terrain_impact["ok"]:
		return terrain_impact
	var construction_cost := roundi(length * lanes * RoadLinkData.construction_cost(road_class))
	var crossings: Array[Dictionary] = _crossings_for_route(region, points, road_class, crossing_choices)
	var structure_cost := 0
	for crossing in crossings:
		structure_cost += 3000000 if crossing["above"] else 5000000
	var land_impact: Dictionary = RoadLand.preview(region, points, road_class, terrain_impact["surface_paths"])
	var cost: int = construction_cost + structure_cost + int(terrain_impact["cost"]) + int(land_impact["cost"])
	var base_days := maxi(45, ceili(20.0 + 4.0 * length)) if road_class == RoadLinkData.HIGHWAY else maxi(14, ceili(7.0 + 2.0 * length))
	var days := _construction_days(base_days)
	return {"ok": true, "kind": RoadProjectData.NEW_LINK, "from": from_id, "to": to_id, "end_position": end_position, "draw_mode": draw_mode, "road_class": road_class, "lanes": lanes, "waypoints": waypoints.duplicate(), "points": points, "length_km": length, "construction_cost": construction_cost, "structure_cost": structure_cost, "terrain_impact": terrain_impact, "land_impact": land_impact, "crossings": crossings, "cost": cost, "days": days, "open_day_key": day_key + days, "owner_id": region.road_owner_for_points(points, road_class)}


static func widen_preview(region, link_id: int, day_key: int) -> Dictionary:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return {"ok": false, "reason": "Select an open road."}
	var link = region.road_links[index]
	if link.managed_neighborhood_id >= 0:
		return {"ok": false, "reason": "This street is managed by its neighborhood development plan."}
	var maximum := 5 if link.road_class == RoadLinkData.HIGHWAY else 3
	if link.lanes_per_direction >= maximum:
		return {"ok": false, "reason": "This road is already at its lane limit."}
	for project in region.road_projects:
		if project.target_link_id == link_id and (project.kind == RoadProjectData.WIDEN or project.kind == RoadProjectData.INTERCHANGE_EXIT):
			return {"ok": false, "reason": "A project is already under construction on this road."}
	var cost := roundi(link.length_km * RoadLinkData.construction_cost(link.road_class))
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
	if link.managed_neighborhood_id >= 0:
		return {"ok": false, "reason": "This street is managed by its neighborhood development plan."}
	return {
		"ok": true,
		"kind": DEMOLISH,
		"target_link_id": link_id,
		"road_class": link.road_class,
		"length_km": link.length_km,
		"upkeep_saved": link.length_km * link.lanes_per_direction * RoadLinkData.upkeep(link.road_class),
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
	RoadLand.release_link(region, link_id)
	refresh_upkeep(region)
	return preview


static func interchange_preview(region, node_id: int, link_id: int, point: Vector2, day_key: int) -> Dictionary:
	if node_id >= 0:
		if node_id >= region.road_nodes.size() or region.road_nodes[node_id].is_interchange:
			return {"ok": false, "reason": "Choose a junction without an interchange."}
		for project in region.road_projects:
			if project.target_node_id == node_id and project.kind == RoadProjectData.INTERCHANGE_NODE:
				return {"ok": false, "reason": "An interchange is already being built here."}
		var node_days := _construction_days(45)
		var node_point: Vector2 = region.road_nodes[node_id].position_km
		var city_id: int = region.city_id_at_point(node_point)
		var owner_id: int = region.city_jurisdiction_ids[city_id] if city_id >= 0 else region.jurisdiction_at_point(node_point)
		return {"ok": true, "kind": RoadProjectData.INTERCHANGE_NODE, "target_node_id": node_id, "cost": INTERCHANGE_COST, "days": node_days, "open_day_key": day_key + node_days, "owner_id": owner_id}
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
	if nearest_junction_gap_km(link, station_for(link.points, projected)) < 0.2:
		return {"ok": false, "reason": "Place the exit farther from an existing exit."}
	var days := _construction_days(45)
	return {"ok": true, "kind": RoadProjectData.INTERCHANGE_EXIT, "target_link_id": link_id, "position_km": projected, "cost": INTERCHANGE_COST, "days": days, "open_day_key": day_key + days, "owner_id": link.owner_jurisdiction_id}


static func commit(region, preview: Dictionary, day_key: int) -> Dictionary:
	if not preview.get("ok", false):
		return {"ok": false, "reason": preview.get("reason", "Invalid road project.")}
	match preview["kind"]:
		RoadProjectData.NEW_LINK:
			var choices: Dictionary = {}
			for crossing in preview.get("crossings", []):
				choices[crossing["key"]] = crossing["above"]
			preview = link_preview(region, preview["from"], preview["to"], preview["road_class"], preview.get("waypoints", PackedVector2Array()), day_key, preview.get("draw_mode", RoadRouteBuilder.AUTO), preview.get("end_position", Vector2.ZERO), choices)
		RoadProjectData.WIDEN:
			preview = widen_preview(region, preview["target_link_id"], day_key)
		RoadProjectData.INTERCHANGE_NODE:
			preview = interchange_preview(region, preview["target_node_id"], -1, Vector2.ZERO, day_key)
		RoadProjectData.INTERCHANGE_EXIT:
			preview = interchange_preview(region, -1, preview["target_link_id"], preview["position_km"], day_key)
	if not preview.get("ok", false):
		return {"ok": false, "reason": preview.get("reason", "Road network changed; choose this project again.")}
	var owner_id: int = int(preview["owner_id"])
	if not region.dev_mode and region.jurisdictions[owner_id].treasury < float(preview["cost"]):
		return {"ok": false, "reason": "Insufficient treasury funds."}
	if preview["kind"] == RoadProjectData.NEW_LINK and int(preview["to"]) < 0:
		var end_node = RoadNodeData.new()
		end_node.id = region.road_nodes.size()
		end_node.position_km = preview["end_position"]
		end_node.city_id = region.city_id_at_point(end_node.position_km)
		region.road_nodes.append(end_node)
		preview["to"] = end_node.id
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
			project.crossings.assign(preview.get("crossings", []).duplicate(true))
			project.terrain_spans.assign(preview["terrain_impact"]["spans"].duplicate(true))
			project.terrain_surface_paths.assign(preview["terrain_impact"]["surface_paths"].duplicate(true))
			project.redevelopment_impact.assign(preview["land_impact"]["neighborhoods"].duplicate(true))
		RoadProjectData.WIDEN, RoadProjectData.INTERCHANGE_EXIT:
			project.target_link_id = preview["target_link_id"]
			if project.kind == RoadProjectData.INTERCHANGE_EXIT:
				project.position_km = preview["position_km"]
		RoadProjectData.INTERCHANGE_NODE:
			project.target_node_id = preview["target_node_id"]
	if not region.dev_mode:
		region.jurisdictions[owner_id].treasury -= float(project.cost)
	region.road_projects.append(project)
	if project.kind == RoadProjectData.NEW_LINK:
		RoadLand.apply(region, project.points, project.road_class, project.id, preview["land_impact"])
		region.road_geometry_revision += 1
	return {"ok": true, "project": project}


static func add_junction(region, point: Vector2, split_link_id: int = -1) -> Dictionary:
	if not _inside_map(point, region):
		return {"ok": false, "reason": "Place junctions inside the region."}
	if region.terrain != null and region.terrain.water_at(point):
		return {"ok": false, "reason": "Place junctions on dry land."}
	if split_link_id >= 0:
		var index: int = RoadGraph.link_index(region, split_link_id)
		if index < 0 or region.road_links[index].road_class not in [RoadLinkData.ARTERIAL, RoadLinkData.COLLECTOR]:
			return {"ok": false, "reason": "Junctions can split arterial roads; use an interchange for highways."}
		for project in region.road_projects:
			if project.target_link_id == split_link_id and project.kind == RoadProjectData.WIDEN:
				return {"ok": false, "reason": "Wait for this road's widening to finish."}
		point = closest_point(region.road_links[index].points, point)
		var old_link = region.road_links[index]
		if point.distance_to(region.road_nodes[old_link.from_node_id].position_km) < 0.025 or point.distance_to(region.road_nodes[old_link.to_node_id].position_km) < 0.025:
			return {"ok": false, "reason": "Place the junction farther from an existing node."}
		if nearest_junction_gap_km(old_link, station_for(old_link.points, point)) < 0.025:
			return {"ok": false, "reason": "Place the junction farther from an existing junction."}
	else:
		for node in region.road_nodes:
			if node.position_km.distance_to(point) < 0.025:
				return {"ok": false, "reason": "A road node is already here."}
	var junction = RoadNodeData.new()
	junction.id = region.road_nodes.size()
	junction.position_km = point
	junction.city_id = region.city_id_at_point(point)
	region.road_nodes.append(junction)
	region.road_geometry_revision += 1
	if split_link_id >= 0:
		attach_junction(region, split_link_id, junction.id)
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
				region.road_links[-1].crossings = project.crossings.duplicate(true)
				region.road_links[-1].terrain_spans = project.terrain_spans.duplicate(true)
				RoadLand.mark_open(region, project.id, region.road_links[-1].id)
				RoadLand.rebuild_project(region, project)
				if project.road_class == RoadLinkData.ARTERIAL:
					_connect_surface_crossings(region, region.road_links[-1].corridor_id)
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
				attach_junction(region, project.target_link_id, exit_node.id)
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
		region.jurisdictions[link.owner_jurisdiction_id].daily_road_upkeep += link.length_km * link.lanes_per_direction * RoadLinkData.upkeep(link.road_class)
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout != null and neighborhood.development_plan != null:
			region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]].daily_road_upkeep += neighborhood.street_layout.local_upkeep(neighborhood.development_plan.completed_phase, neighborhood.development_plan.installed_multiplier)
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
		total += link.length_km * link.lanes_per_direction * RoadLinkData.upkeep(link.road_class)
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout != null and neighborhood.development_plan != null:
			total += neighborhood.street_layout.local_upkeep(neighborhood.development_plan.completed_phase, neighborhood.development_plan.installed_multiplier)
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


# Distance along a polyline to the point where the given position projects.
static func station_for(points: PackedVector2Array, point: Vector2) -> float:
	var station := 0.0
	var best := INF
	var best_station := 0.0
	for index in range(1, points.size()):
		var candidate: Vector2 = Geometry2D.get_closest_point_to_segment(point, points[index - 1], points[index])
		var distance := candidate.distance_squared_to(point)
		if distance < best:
			best = distance
			best_station = station + points[index - 1].distance_to(candidate)
		station += points[index - 1].distance_to(points[index])
	return best_station


# A junction node can live in the interior of a road without splitting it:
# the link keeps one multipoint curve and routing walks its junction chain.
static func attach_junction(region, link_id: int, node_id: int) -> void:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return
	var link = region.road_links[index]
	var node = region.road_nodes[node_id]
	var point: Vector2 = closest_point(link.points, node.position_km)
	var station: float = station_for(link.points, point)
	if station <= 0.002 or station >= link.length_km - 0.002:
		station = clampf(station, 0.002, maxf(0.002, link.length_km - 0.002))
	node.position_km = point
	for junction in link.junctions:
		if int(junction["node_id"]) == node_id:
			junction["station_km"] = station
			return
	var junctions: Array[Dictionary] = []
	var inserted := false
	for junction in link.junctions:
		if not inserted and station < float(junction["station_km"]):
			junctions.append({"node_id": node_id, "station_km": station})
			inserted = true
		junctions.append(junction)
	if not inserted:
		junctions.append({"node_id": node_id, "station_km": station})
	link.junctions = junctions


# Smallest gap between a candidate station and the road's existing junctions.
static func nearest_junction_gap_km(link, station: float) -> float:
	var gap := INF
	for junction in link.junctions:
		gap = minf(gap, absf(station - float(junction["station_km"])))
	return gap


static func _split_link(region, link_id: int, new_node_id: int, point: Vector2) -> void:
	var index: int = RoadGraph.link_index(region, link_id)
	if index < 0:
		return
	var old_link = region.road_links[index]
	var original_points: PackedVector2Array = old_link.points
	var original_profile: PackedFloat32Array = old_link.elevation_profile_m
	var original_spans: Array[Dictionary] = old_link.terrain_spans
	var split_segment := 1
	var best_distance := INF
	for segment in range(1, old_link.points.size()):
		var distance: float = Geometry2D.get_closest_point_to_segment(point, old_link.points[segment - 1], old_link.points[segment]).distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			split_segment = segment
	var first := PackedVector2Array()
	var second := PackedVector2Array([point])
	# A mid-chord insertion shortens the legs of the adjacent arc samples,
	# which halves their measured curve radius. Dropping the two nearest
	# samples on each side keeps every vertex on full-length chords.
	var near_start: bool = point.distance_to(original_points[split_segment - 1]) < 0.01
	var near_end: bool = point.distance_to(original_points[split_segment]) < 0.01
	var drop_neighbors: bool = not near_start and not near_end
	for i in range(split_segment):
		if drop_neighbors and i >= split_segment - 2 and i > 0:
			continue
		first.append(original_points[i])
	first.append(point)
	for i in range(split_segment, original_points.size()):
		if drop_neighbors and i <= split_segment + 1 and i < original_points.size() - 1:
			continue
		second.append(original_points[i])
	first = _clean_polyline(first)
	second = _clean_polyline(second)
	if first.size() < 2 or second.size() < 2:
		return
	var old_to: int = old_link.to_node_id
	var split_station: float = station_for(original_points, point)
	var first_junctions: Array[Dictionary] = []
	var second_junctions: Array[Dictionary] = []
	for junction in old_link.junctions:
		if float(junction["station_km"]) < split_station:
			first_junctions.append(junction)
		else:
			second_junctions.append(junction)
	if not region.street_spatial_cache.is_empty():
		region.street_spatial_cache["pairs"].erase(StreetSpatial.pair_key(old_link.from_node_id, old_to, old_link.road_class))
		region.street_spatial_cache["pairs"][StreetSpatial.pair_key(old_link.from_node_id, new_node_id, old_link.road_class)] = index
	old_link.to_node_id = new_node_id
	old_link.points = first
	var moved_crossings: Array[Dictionary] = []
	var kept_crossings: Array[Dictionary] = []
	for crossing in old_link.crossings:
		if _point_near_polyline(first, crossing["point"]):
			kept_crossings.append(crossing)
		else:
			moved_crossings.append(crossing)
	old_link.crossings = kept_crossings
	old_link.elevation_profile_m = RoadTerrain.slice_profile(original_points, original_profile, first)
	old_link.terrain_spans = RoadTerrain.clip_spans(original_spans, first, old_link.elevation_profile_m) if not original_profile.is_empty() else RoadTerrain.spans(region, first, old_link.road_class)
	old_link.recalculate_length()
	old_link.junctions = _rebased_junctions(region, first_junctions, first)
	_append_link(region, new_node_id, old_to, old_link.road_class, old_link.lanes_per_direction, second, old_link.owner_jurisdiction_id)
	region.road_links[-1].crossings = moved_crossings
	region.road_links[-1].elevation_profile_m = RoadTerrain.slice_profile(original_points, original_profile, second)
	region.road_links[-1].terrain_spans = RoadTerrain.clip_spans(original_spans, second, region.road_links[-1].elevation_profile_m) if not original_profile.is_empty() else RoadTerrain.spans(region, second, old_link.road_class)
	region.road_links[-1].junctions = _rebased_junctions(region, second_junctions, second)
	RoadLand.split_link_reservation(region, link_id, region.road_links[-1].id, first, second)
	region.road_links[-1].toll_forward = old_link.toll_forward
	region.road_links[-1].toll_reverse = old_link.toll_reverse
	region.road_links[-1].corridor_id = old_link.corridor_id if old_link.corridor_id >= 0 else old_link.id
	region.road_links[-1].corridor_start_km = old_link.corridor_start_km + old_link.length_km
	region.road_links[-1].managed_neighborhood_id = old_link.managed_neighborhood_id
	region.road_links[-1].border_city_ids = old_link.border_city_ids
	region.road_links[-1].border_seam_key = old_link.border_seam_key


# Junction stations after a split are measured against the half's own
# polyline; entries keep their node ids so cross-road connections survive.
static func _rebased_junctions(region, junctions: Array[Dictionary], points: PackedVector2Array) -> Array[Dictionary]:
	if junctions.is_empty():
		return []
	var length: float = _length(points)
	var result: Array[Dictionary] = []
	for junction in junctions:
		var node_point: Vector2 = region.road_nodes[int(junction["node_id"])].position_km
		var station: float = clampf(station_for(points, node_point), 0.002, maxf(0.002, length - 0.002))
		result.append({"node_id": junction["node_id"], "station_km": station})
	return result


static func _append_link(region, from_id: int, to_id: int, road_class: String, lanes: int, points: PackedVector2Array, owner_id: int) -> void:
	var link = RoadLinkData.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.corridor_id = link.id
	link.from_node_id = from_id
	link.to_node_id = to_id
	link.road_class = road_class
	link.lanes_per_direction = lanes
	link.points = points
	link.recalculate_length()
	link.owner_jurisdiction_id = owner_id
	region.road_links.append(link)


static func _connect_surface_crossings(region, corridor_id: int) -> void:
	var scan_started: int = Time.get_ticks_usec()
	var corridor_links: Dictionary = {}
	for link_index in range(region.road_links.size()):
		var corridor_link = region.road_links[link_index]
		if corridor_link.corridor_id == corridor_id and corridor_link.road_class in [RoadLinkData.ARTERIAL, RoadLinkData.COLLECTOR]:
			corridor_links[link_index] = true
	var index: Dictionary = StreetSpatial.cache(region)
	# Map each touched cell to the corridor segments inside it so every
	# cell's entry list is read once per corridor instead of once per segment.
	var corridor_cells: Dictionary = {}
	for link_index in corridor_links:
		var link = region.road_links[link_index]
		for segment in range(1, link.points.size()):
			var first: Vector2 = link.points[segment - 1]
			var last: Vector2 = link.points[segment]
			for cell in StreetSpatial.segment_cell_keys(region, first, last):
				if not corridor_cells.has(cell):
					corridor_cells[cell] = []
				var probes: Array = corridor_cells[cell]
				probes.append(link_index)
				probes.append(first)
				probes.append(last)
	var iterate_started: int = Time.get_ticks_usec()
	# Attachments never move road geometry, so the spatial cache built above
	# stays valid for the whole pass; only node bookkeeping changes per fix.
	var phase_mark: int = iterate_started
	for attempt in range(4096):
		var crossing: Dictionary = {}
		for cell in corridor_cells:
			var entries: PackedInt32Array = index["segments"][cell]
			var bounds: PackedFloat32Array = index["segment_bounds"][cell]
			var probes: Array = corridor_cells[cell]
			for pair in range(0, entries.size(), 2):
				var base: int = pair * 2
				var other_index: int = entries[pair]
				if corridor_links.has(other_index):
					continue
				var other = region.road_links[other_index]
				if other.road_class == RoadLinkData.HIGHWAY:
					continue
				var other_segment: int = entries[pair + 1]
				if other_segment < 1 or other_segment >= other.points.size():
					continue
				var other_first: Vector2 = other.points[other_segment - 1]
				var other_last: Vector2 = other.points[other_segment]
				for probe in range(0, probes.size(), 3):
					var probe_link: int = probes[probe]
					var first: Vector2 = probes[probe + 1]
					var last: Vector2 = probes[probe + 2]
					if bounds[base] > maxf(first.x, last.x) or bounds[base + 1] > maxf(first.y, last.y) or bounds[base + 2] < minf(first.x, last.x) or bounds[base + 3] < minf(first.y, last.y):
						continue
					var point = Geometry2D.segment_intersects_segment(first, last, other_first, other_last)
					if point == null:
						continue
					var link = region.road_links[probe_link]
					var first_node: int = _node_at(region, link, point)
					var second_node: int = _node_at(region, other, point)
					if first_node >= 0 and first_node == second_node:
						continue
					crossing = {"first": link, "second": other, "point": point, "first_node": first_node, "second_node": second_node}
					break
				if not crossing.is_empty():
					break
			if not crossing.is_empty():
				break
		if crossing.is_empty():
			surface_phase_us["scan"] = int(surface_phase_us.get("scan", 0)) + iterate_started - scan_started
			surface_phase_us["iterate"] = int(surface_phase_us.get("iterate", 0)) + Time.get_ticks_usec() - phase_mark
			return
		var fix_started: int = Time.get_ticks_usec()
		var node_id: int = crossing["second_node"] if crossing["second_node"] >= 0 else crossing["first_node"]
		if node_id < 0:
			var node = RoadNodeData.new()
			node.id = region.road_nodes.size()
			node.position_km = crossing["point"]
			node.city_id = region.city_id_at_point(node.position_km)
			region.road_nodes.append(node)
			node_id = node.id
		for side in ["first", "second"]:
			var link = crossing[side]
			var endpoint: int = crossing["%s_node" % side]
			if endpoint < 0:
				attach_junction(region, link.id, node_id)
			elif endpoint != node_id:
				if link.from_node_id == endpoint:
					link.from_node_id = node_id
				elif link.to_node_id == endpoint:
					link.to_node_id = node_id
				else:
					for junction in link.junctions:
						if int(junction["node_id"]) == endpoint:
							junction["node_id"] = node_id
							break
		surface_phase_us["iterate"] = int(surface_phase_us.get("iterate", 0)) + fix_started - phase_mark
		surface_phase_us["fix"] = int(surface_phase_us.get("fix", 0)) + Time.get_ticks_usec() - fix_started
		phase_mark = Time.get_ticks_usec()


# Node already serving a link at this position: a true endpoint or an
# interior junction attachment.
static func _node_at(region, link, point: Vector2) -> int:
	var endpoint: int = _endpoint_at(region, link, point)
	if endpoint >= 0:
		return endpoint
	for junction in link.junctions:
		if region.road_nodes[int(junction["node_id"])].position_km.distance_to(point) < 0.002:
			return int(junction["node_id"])
	return -1


static func _endpoint_at(region, link, point: Vector2) -> int:
	for node_id in [link.from_node_id, link.to_node_id]:
		if region.road_nodes[node_id].position_km.distance_to(point) < 0.002:
			return node_id
	return -1


static func _length(points: PackedVector2Array) -> float:
	var result := 0.0
	for index in range(1, points.size()):
		result += points[index - 1].distance_to(points[index])
	return result


static func _clean_polyline(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		if result.is_empty() or result[-1].distance_to(point) > 0.00005:
			result.append(point)
	return result


static func _crossings_for_route(region, points: PackedVector2Array, road_class: String, choices: Dictionary) -> Array[Dictionary]:
	var crossings: Array[Dictionary] = []
	if points.size() < 2:
		return crossings
	var highway_route: bool = road_class == RoadLinkData.HIGHWAY
	for a in range(1, points.size()):
		var first: Vector2 = points[a - 1]
		var last: Vector2 = points[a]
		var pairs: PackedInt32Array = StreetSpatial.segment_candidates(region, first, last)
		for pair in range(0, pairs.size(), 2):
			var link_index: int = pairs[pair]
			var link = region.road_links[link_index]
			if link.road_class != RoadLinkData.HIGHWAY and not highway_route:
				continue
			var b: int = pairs[pair + 1]
			if b < 1 or b >= link.points.size():
				continue
			var hit = Geometry2D.segment_intersects_segment(first, last, link.points[b - 1], link.points[b])
			if hit == null:
				continue
			var point: Vector2 = hit
			if point.distance_to(points[0]) < 0.05 or point.distance_to(points[-1]) < 0.05:
				continue
			var shared_junction := false
			for node_id in [link.from_node_id, link.to_node_id]:
				if region.road_nodes[node_id].position_km.distance_to(point) < 0.01 and (region.road_nodes[node_id].position_km.distance_to(points[0]) < 0.01 or region.road_nodes[node_id].position_km.distance_to(points[-1]) < 0.01):
					shared_junction = true
					break
			if shared_junction:
				continue
			var key: String = "%d:%d:%d" % [link.id, roundi(point.x * 1000.0), roundi(point.y * 1000.0)]
			var duplicate := false
			for crossing in crossings:
				if crossing["key"] == key:
					duplicate = true
					break
			if duplicate:
				continue
			crossings.append({"key": key, "link_id": link.id, "point": point, "above": bool(choices.get(key, true))})
	return crossings


static func _point_near_polyline(points: PackedVector2Array, point: Vector2) -> bool:
	for index in range(1, points.size()):
		if Geometry2D.get_closest_point_to_segment(point, points[index - 1], points[index]).distance_to(point) < 0.002:
			return true
	return false


static func snap_position(region, start_id: int, anchors: PackedVector2Array, point: Vector2, road_class: String, mode: String = RoadRouteBuilder.STRAIGHT, snap_angle: bool = true, snap_length: bool = false) -> Vector2:
	return snap_guidance(region, start_id, anchors, point, road_class, mode, snap_angle, snap_length)["position"]


static func snap_guidance(region, start_id: int, anchors: PackedVector2Array, point: Vector2, road_class: String, mode: String = RoadRouteBuilder.STRAIGHT, snap_angle: bool = true, snap_length: bool = false) -> Dictionary:
	if start_id < 0 or start_id >= region.road_nodes.size():
		return {"position": point, "reference": Vector2.RIGHT, "has_reference": false, "label": ""}
	var origin: Vector2 = anchors[-1] if not anchors.is_empty() else region.road_nodes[start_id].position_km
	var delta: Vector2 = point - origin
	if delta.length_squared() < 0.000001:
		return {"position": point, "reference": Vector2.RIGHT, "has_reference": false, "label": ""}
	var connection := Vector2.ZERO
	var reference_axis := Vector2.RIGHT
	if mode == RoadRouteBuilder.MULTIPOINT and anchors.size() >= 2:
		var last_end_index: int = anchors.size() - 1 if anchors.size() % 2 == 0 else anchors.size() - 2
		reference_axis = (anchors[last_end_index] - anchors[last_end_index - 1]).normalized()
	elif mode == RoadRouteBuilder.MULTIPOINT and anchors.size() == 1:
		connection = road_connection_reference(region, start_id, anchors[0], road_class)
		reference_axis = connection if connection != Vector2.ZERO else (anchors[0] - region.road_nodes[start_id].position_km).normalized()
	elif not anchors.is_empty():
		var previous: Vector2 = anchors[-2] if anchors.size() > 1 else region.road_nodes[start_id].position_km
		reference_axis = (anchors[-1] - previous).normalized()
	else:
		connection = road_connection_reference(region, start_id, point, road_class)
		if connection != Vector2.ZERO:
			reference_axis = connection
	if reference_axis.length_squared() < 0.000001:
		reference_axis = Vector2.RIGHT
	var relative: float = reference_axis.angle_to(delta)
	var direction: Vector2 = reference_axis.rotated(roundf(relative / deg_to_rad(5.0)) * deg_to_rad(5.0)) if snap_angle else delta.normalized()
	var length_km: float = roundf(delta.length() / 0.005) * 0.005 if snap_length else delta.length()
	var position: Vector2 = origin + direction * length_km
	var has_reference: bool = not anchors.is_empty() or connection != Vector2.ZERO
	var display_angle: int = roundi(rad_to_deg(reference_axis.angle_to(direction)) / 5.0) * 5
	var label: String = "Bearing %d°" % (roundi(rad_to_deg(direction.angle()) / 5.0) * 5)
	if has_reference:
		label = "%+d°" % display_angle if display_angle != 0 else "0°"
	if snap_length:
		label = "%s  ·  %d m" % [label, roundi(length_km * 1000.0)] if snap_angle else "%d m" % roundi(length_km * 1000.0)
	return {"position": position, "reference": reference_axis, "has_reference": has_reference, "label": label, "length_m": roundi(length_km * 1000.0)}


static func frozen_multi_curve(region, start_id: int, anchors: PackedVector2Array, road_class: String) -> PackedVector2Array:
	var completed_count: int = anchors.size() - anchors.size() % 2
	if completed_count < 2:
		return PackedVector2Array()
	var guides: PackedVector2Array = anchors.slice(0, completed_count)
	var last: Vector2 = guides[-1]
	guides.remove_at(guides.size() - 1)
	return player_route(region, start_id, last, road_class, guides, RoadRouteBuilder.MULTIPOINT)


static func multi_curve_preview(region, start_id: int, anchors: PackedVector2Array, end: Vector2, road_class: String, frozen: PackedVector2Array) -> PackedVector2Array:
	if anchors.is_empty() or anchors.size() % 2 == 0:
		return PackedVector2Array()
	if anchors.size() == 1:
		return player_route(region, start_id, end, road_class, anchors, RoadRouteBuilder.MULTIPOINT)
	if frozen.is_empty():
		return PackedVector2Array()
	var incoming: Vector2 = (anchors[-2] - anchors[-3]).normalized()
	var segment: PackedVector2Array = RoadRouteBuilder.build_player(region, anchors[-2], end, road_class, PackedVector2Array([anchors[-1]]), RoadRouteBuilder.CURVED, incoming)
	if segment.is_empty():
		return PackedVector2Array()
	var route: PackedVector2Array = frozen.duplicate()
	for index in range(1, segment.size()):
		route.append(segment[index])
	return route


static func snap_reference(region, start_id: int, anchors: PackedVector2Array, point: Vector2, road_class: String, mode: String = RoadRouteBuilder.STRAIGHT) -> Vector2:
	return snap_guidance(region, start_id, anchors, point, road_class, mode)["reference"]


static func road_connection_reference(region, node_id: int, toward: Vector2, road_class: String) -> Vector2:
	if node_id < 0 or node_id >= region.road_nodes.size():
		return Vector2.ZERO
	var preferred: Vector2 = toward - region.road_nodes[node_id].position_km
	if preferred.length_squared() < 0.000001:
		return Vector2.ZERO
	preferred = preferred.normalized()
	var best := Vector2.ZERO
	var best_class_match := false
	var best_score := -INF
	var best_id := 2147483647
	for link in region.road_links:
		if link.points.size() < 2:
			continue
		var direction := Vector2.ZERO
		if link.from_node_id == node_id:
			direction = (link.points[0] - link.points[1]).normalized()
		elif link.to_node_id == node_id:
			direction = (link.points[-1] - link.points[-2]).normalized()
		if direction == Vector2.ZERO:
			continue
		var class_match: bool = link.road_class == road_class
		var score: float = direction.dot(preferred)
		if best == Vector2.ZERO or (class_match and not best_class_match) or (class_match == best_class_match and (score > best_score + 0.000001 or (absf(score - best_score) <= 0.000001 and link.id < best_id))):
			best = direction
			best_class_match = class_match
			best_score = score
			best_id = link.id
	return best


static func arterial_continuation(region, node_id: int, toward: Vector2) -> Vector2:
	if node_id < 0 or node_id >= region.road_nodes.size():
		return Vector2.ZERO
	var preferred: Vector2 = toward - region.road_nodes[node_id].position_km
	if preferred.length_squared() < 0.000001:
		return Vector2.ZERO
	preferred = preferred.normalized()
	var best := Vector2.ZERO
	var best_score := -INF
	var best_id := 2147483647
	for link in region.road_links:
		if link.road_class != RoadLinkData.ARTERIAL or link.points.size() < 2:
			continue
		var direction := Vector2.ZERO
		if link.from_node_id == node_id:
			direction = (link.points[0] - link.points[1]).normalized()
		elif link.to_node_id == node_id:
			direction = (link.points[-1] - link.points[-2]).normalized()
		if direction == Vector2.ZERO:
			continue
		var score: float = direction.dot(preferred)
		if score > best_score + 0.000001 or (absf(score - best_score) <= 0.000001 and link.id < best_id):
			best = direction
			best_score = score
			best_id = link.id
	return best


static func player_route(region, start_id: int, end: Vector2, road_class: String, guides: PackedVector2Array, mode: String, end_id: int = -1) -> PackedVector2Array:
	var tangent := Vector2.ZERO
	var final_tangent := Vector2.ZERO
	if road_class == RoadLinkData.HIGHWAY:
		tangent = -_single_highway_outward(region, start_id)
		if end_id >= 0:
			final_tangent = _single_highway_outward(region, end_id)
	elif mode in [RoadRouteBuilder.CURVED, RoadRouteBuilder.MULTIPOINT]:
		tangent = arterial_continuation(region, start_id, guides[0] if not guides.is_empty() else end)
	return RoadRouteBuilder.build_player(region, region.road_nodes[start_id].position_km, end, road_class, guides, mode, tangent, final_tangent)


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
	var view: Dictionary = RoadGraph.adjacency(region)
	var neighbors: Array = view["neighbors"]
	var edge_from: PackedInt32Array = view["edge_from"]
	var edge_to: PackedInt32Array = view["edge_to"]
	var edge_link: PackedInt32Array = view["edge_link"]
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
				if region.road_links[edge_link[edge.x]].id == excluded_link_id:
					continue
				var neighbor: int = edge_to[edge.x] if edge.y == 0 else edge_from[edge.x]
				if visited[neighbor] == 0:
					visited[neighbor] = 1
					frontier.append(neighbor)
	return components
