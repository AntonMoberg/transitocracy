extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")

const COUNTRYSIDE_SPACING_KM = 28.0

static var install_phase_us: Dictionary = {}


static func generate(region) -> void:
	region.road_geometry_revision += 1
	region.street_spatial_cache = {}
	region.road_nodes.clear()
	region.road_links.clear()
	region.road_projects.clear()
	region.neighborhood_gateway_node_ids.clear()
	region.city_hub_node_ids.clear()
	region.city_highway_access_node_ids.clear()
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
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = city["center_km"]
		node.kind = "City"
		node.city_id = city["id"]
		region.road_nodes.append(node)
		region.city_hub_node_ids.append(node.id)
		region.city_highway_access_node_ids.append(-1)
	for city in region.cities:
		UrbanGraph.build_starting_city(region, city)
	var planner = Planner.new(region)
	var sites: Array[Dictionary] = _sites(region)
	var generation_started: int = Time.get_ticks_msec()
	print("Regional road sites: ", sites.size())
	if sites.size() >= 2:
		# Layered phases: trunk corridors first, then the rural web spreads
		# from their interchanges and the city gates, avoiding trunk valleys.
		var candidates: Array[Dictionary] = _proximity_edges(region, sites)
		var highways: Dictionary = _build_highways(region, planner, sites)
		if not highways.is_empty():
			planner.set_avoidance(highways["avoid_costs"], highways["avoid_origin"], highways["avoid_step"], highways["avoid_size"])
		_build_countryside(region, planner, sites, candidates, highways)
		print("Countryside roads: %d links in %d ms" % [region.road_links.size(), Time.get_ticks_msec() - generation_started])
		_assign_highway_access(region, planner, highways.get("gate_cities", {}), highways.get("attached_targets", {}))
		_promote_access_spurs(region)
		print("Regional roads complete: %d ms" % (Time.get_ticks_msec() - generation_started))
	for link in region.road_links:
		if link.road_class != Roads.COLLECTOR:
			link.owner_jurisdiction_id = region.road_owner_for_points(link.points, link.road_class)
	region.street_spatial_cache = {}


static func _sites(region) -> Array[Dictionary]:
	var sites: Array[Dictionary] = []
	var degrees: Dictionary = {}
	var directions: Dictionary = {}
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL:
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			degrees[node_id] = int(degrees.get(node_id, 0)) + 1
		directions[link.from_node_id] = (link.points[0] - link.points[1]).normalized()
		directions[link.to_node_id] = (link.points[-1] - link.points[-2]).normalized()
	for city_id in region.starting_city_ids:
		for node_id in degrees:
			var node = region.road_nodes[node_id]
			if node.city_id == city_id and int(degrees[node_id]) == 1:
				sites.append({"point": node.position_km, "node": node.id, "city": city_id, "tangent": directions[node_id]})
	var bounds: Rect2 = region.jurisdictions[0].bounds_km
	var rng := RandomNumberGenerator.new()
	rng.seed = region.generation_seed * 1777 + 541
	for y in range(floori(bounds.position.y / COUNTRYSIDE_SPACING_KM), ceili(bounds.end.y / COUNTRYSIDE_SPACING_KM) + 1):
		for x in range(floori(bounds.position.x / COUNTRYSIDE_SPACING_KM), ceili(bounds.end.x / COUNTRYSIDE_SPACING_KM) + 1):
			var point := (Vector2(x, y) + Vector2(rng.randf_range(0.20, 0.80), rng.randf_range(0.20, 0.80))) * COUNTRYSIDE_SPACING_KM
			if not region.jurisdictions[0].contains_point(point) or region.terrain.water_at(point):
				continue
			var slope: float = region.terrain.slope_at(point)
			var height: float = region.terrain.elevation_at(point)
			if slope > 0.13 or (height > 1000.0 and rng.randf() > 0.22):
				continue
			var near_city := false
			for city_id in region.starting_city_ids:
				if point.distance_to(region.cities[city_id]["center_km"]) < 4.0:
					near_city = true
					break
			if not near_city:
				_add_site(region, sites, point)
	return sites


static func _add_site(region, sites: Array[Dictionary], point: Vector2) -> void:
	var node = RoadNodeData.new()
	node.id = region.road_nodes.size()
	node.position_km = point
	node.city_id = region.city_id_at_point(point)
	region.road_nodes.append(node)
	sites.append({"point": point, "node": node.id, "city": -1, "tangent": Vector2.ZERO})


static func _proximity_edges(region, sites: Array[Dictionary]) -> Array[Dictionary]:
	var positions := PackedVector2Array()
	for site in sites:
		positions.append(site["point"])
	var triangles: PackedInt32Array = Geometry2D.triangulate_delaunay(positions)
	var seen: Dictionary = {}
	var edges: Array[Dictionary] = []
	for index in range(0, triangles.size(), 3):
		for corner in range(3):
			var a: int = triangles[index + corner]
			var b: int = triangles[index + (corner + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if seen.has(key) or (sites[a]["city"] >= 0 and sites[a]["city"] == sites[b]["city"]):
				continue
			seen[key] = true
			var first: Vector2 = positions[a]
			var last: Vector2 = positions[b]
			var penalty := 0.0
			for fraction in [0.25, 0.5, 0.75]:
				var point: Vector2 = first.lerp(last, fraction)
				penalty += region.terrain.slope_at(point) * 4.0 + (2.0 if region.terrain.water_at(point) else 0.0)
			edges.append({"a": a, "b": b, "score": first.distance_to(last) * (1.0 + penalty)})
	edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) < float(b["score"]))
	return edges


static func _root(parents: PackedInt32Array, id: int) -> int:
	var cursor: int = id
	while parents[cursor] != cursor:
		cursor = parents[cursor]
	return cursor


static func _build_countryside(region, planner, sites: Array[Dictionary], candidates: Array[Dictionary], highways: Dictionary = {}) -> void:
	var route_started: int = Time.get_ticks_usec()
	var alignments := _precompute_routes(region, sites, candidates, highways)
	print("Countryside routes: %d candidates in %d ms" % [candidates.size(), (Time.get_ticks_usec() - route_started) / 1000])
	var parents := PackedInt32Array()
	var degrees := PackedInt32Array()
	var neighbors: Array[Dictionary] = []
	for index in range(sites.size()):
		parents.append(index)
		degrees.append(0)
		neighbors.append({})
	var city_roots: Dictionary = {}
	for index in range(sites.size()):
		var city_id: int = sites[index]["city"]
		if city_id < 0:
			continue
		if city_roots.has(city_id):
			parents[index] = city_roots[city_id]
			neighbors[index][city_roots[city_id]] = 1.0
			neighbors[city_roots[city_id]][index] = 1.0
		else:
			city_roots[city_id] = index
	# Sites that sit on the trunk network are already connected: skip the
	# rural candidates that would just parallel the highway between them.
	var view: Dictionary = RoadGraph.adjacency(region)
	var trunk_root := -1
	for index in range(sites.size()):
		var on_trunk := false
		for edge in view["neighbors"][sites[index]["node"]]:
			if region.road_links[view["edge_link"][edge.x]].road_class == Roads.HIGHWAY:
				on_trunk = true
				break
		if not on_trunk:
			continue
		if trunk_root < 0:
			trunk_root = index
		elif _root(parents, index) != _root(parents, trunk_root):
			parents[_root(parents, index)] = _root(parents, trunk_root)
	var installed: Dictionary = {}
	var install_us := 0
	# Connect geographic components first; then add useful lowland loops.
	for loops in [false, true]:
		for edge_index in range(candidates.size()):
			var edge: Dictionary = candidates[edge_index]
			var a: int = edge["a"]
			var b: int = edge["b"]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if installed.has(key):
				continue
			var same_component: bool = _root(parents, a) == _root(parents, b)
			if not loops and same_component:
				continue
			if loops:
				if not same_component or degrees[a] >= 4 or degrees[b] >= 4:
					continue
				var direct: float = sites[a]["point"].distance_to(sites[b]["point"])
				if direct > 75.0 or _nearby_distance(neighbors, a, b, direct * 1.65) <= direct * 1.65:
					continue
			var alignment: Dictionary = alignments[edge_index]
			if alignment.is_empty():
				continue
			var install_started: int = Time.get_ticks_usec()
			_install(region, sites[a]["node"], sites[b]["node"], Roads.COLLECTOR, alignment)
			install_us += Time.get_ticks_usec() - install_started
			installed[key] = true
			parents[_root(parents, b)] = _root(parents, a)
			degrees[a] += 1
			degrees[b] += 1
			neighbors[a][b] = alignment["length_km"]
			neighbors[b][a] = alignment["length_km"]
	print("Countryside installs: %d in %d ms phases=%s surface=%s" % [installed.size(), install_us / 1000, install_phase_us, RoadPlanner.surface_phase_us])
	_connect_isolated_cities(region, planner, sites, candidates, alignments, parents, degrees, neighbors, installed, city_roots)
	var segment_cells: Dictionary = region.street_spatial_cache.get("segments", {})
	var total_entries := 0
	var max_entries := 0
	var dense := 0
	for cell in segment_cells:
		var count: int = segment_cells[cell].size() / 2
		total_entries += count
		max_entries = maxi(max_entries, count)
		if count > 50:
			dense += 1
	print("segment index: cells=%d entries=%d dense(>50)=%d max=%d" % [segment_cells.size(), total_entries, dense, max_entries])
	# Roads leaving city streets form the arterial transition to country roads.
	# Only links that touch a settlement's real arterial gate count; a city
	# jurisdiction also covers wide rural land whose junctions must stay rural.
	var city_gate_nodes := {}
	for site in sites:
		if int(site["city"]) >= 0:
			city_gate_nodes[int(site["node"])] = true
	for link in region.road_links:
		if link.road_class == Roads.COLLECTOR and (city_gate_nodes.has(link.from_node_id) or city_gate_nodes.has(link.to_node_id)):
			if link.length_km < 18.0:
				link.road_class = Roads.ARTERIAL

# Routes never depend on installed roads, so every proximity candidate can be
# searched in parallel before the sequential union-find passes pick installs.
static func _avoidance_planner(region, highways: Dictionary):
	var local = Planner.new(region)
	if highways.has("avoid_costs") and not highways["avoid_costs"].is_empty():
		local.set_avoidance(highways["avoid_costs"], highways["avoid_origin"], highways["avoid_step"], highways["avoid_size"])
	return local


static func _precompute_routes(region, sites: Array[Dictionary], candidates: Array[Dictionary], highways: Dictionary = {}) -> Array:
	var results: Array = []
	results.resize(candidates.size())
	var routed := 0
	var jobs: Array[int] = []
	for index in range(candidates.size()):
		jobs.append(index)
	if jobs.is_empty():
		return results
	var workers: int = maxi(1, mini(8, OS.get_processor_count() - 1))
	var started: int = Time.get_ticks_usec()
	if workers == 1 or jobs.size() < 8:
		var local = _avoidance_planner(region, highways)
		for index in jobs:
			results[index] = _route_candidate(local, sites, candidates[index])
			routed += 1
		print("Countryside routes: %d sequential in %d ms" % [routed, (Time.get_ticks_usec() - started) / 1000])
		return results
	# Spatially coherent chunks keep each worker's lazy terrain cache warm.
	var order: Array[int] = []
	for index in jobs:
		order.append(index)
	order.sort_custom(func(x: int, y: int) -> bool:
		var first: Vector2 = (sites[candidates[x]["a"]]["point"] + sites[candidates[x]["b"]]["point"]) * 0.5
		var second: Vector2 = (sites[candidates[y]["a"]]["point"] + sites[candidates[y]["b"]]["point"]) * 0.5
		return first.y + first.x * 0.001 < second.y + second.x * 0.001
	)
	var chunk_size: int = ceili(float(order.size()) / float(workers * 4))
	var chunk_count: int = ceili(float(order.size()) / float(chunk_size))
	var chunk_slots: Array = []
	chunk_slots.resize(chunk_count)
	for chunk in range(chunk_count):
		chunk_slots[chunk] = []
	var route_chunk := func(chunk: int) -> void:
		var local = _avoidance_planner(region, highways)
		var slot: Array = chunk_slots[chunk]
		var start: int = chunk * chunk_size
		var finish: int = mini(start + chunk_size, order.size())
		var chunk_started: int = Time.get_ticks_usec()
		for position in range(start, finish):
			var candidate_index: int = order[position]
			slot.append([candidate_index, _route_candidate(local, sites, candidates[candidate_index])])
		print("route chunk %d: %d routes in %d ms" % [chunk, finish - start, (Time.get_ticks_usec() - chunk_started) / 1000])
	var task_id := WorkerThreadPool.add_group_task(route_chunk, chunk_count, workers, true, "Countryside routes")
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	var failures := 0
	for chunk in range(chunk_count):
		for pair in chunk_slots[chunk]:
			results[pair[0]] = pair[1]
			routed += 1
			if pair[1].is_empty():
				failures += 1
	print("Countryside routes: %d on %d workers in %d ms (%d failed)" % [routed, workers, (Time.get_ticks_usec() - started) / 1000, failures])
	return results


static func _route_candidate(planner, sites: Array[Dictionary], candidate: Dictionary) -> Dictionary:
	var first: Dictionary = sites[candidate["a"]]
	var last: Dictionary = sites[candidate["b"]]
	# Rural roads stay on the coarse search: difficult mountains get fewer
	# routes by design, and fine-grid rescue attempts dominate generation time.
	return planner.route(first["point"], last["point"], Roads.COLLECTOR, first["tangent"], -last["tangent"], false)


# Guarantee the combined hierarchy connects every starting settlement. The
# union-find only knows site-to-site installs, while surface crossings also
# join roads mid-link, so isolation is judged with a physical graph search.
static func _connect_isolated_cities(region, planner, sites: Array[Dictionary], candidates: Array[Dictionary], alignments: Array, parents: PackedInt32Array, degrees: PackedInt32Array, neighbors: Array[Dictionary], installed: Dictionary, city_roots: Dictionary) -> void:
	if region.starting_city_ids.is_empty():
		return
	var source_hub: int = region.city_hub_node_ids[region.starting_city_ids[0]]
	var missing: Array[int] = []
	for _round in range(4):
		var reachable: PackedByteArray = _nodes_reachable(region, source_hub)
		missing.clear()
		for city_id in region.starting_city_ids:
			if reachable[region.city_hub_node_ids[city_id]] == 0:
				missing.append(city_id)
		if missing.is_empty():
			return
		var merged := false
		for city_id in missing:
			if _rescue_city(region, planner, sites, candidates, alignments, parents, degrees, neighbors, installed, city_roots, city_id, source_hub, reachable):
				merged = true
		if not merged:
			break
	for city_id in missing:
		push_warning("Starting city %d has no drivable link into the regional network." % city_id)


static func _rescue_city(region, planner, sites: Array[Dictionary], candidates: Array[Dictionary], alignments: Array, parents: PackedInt32Array, degrees: PackedInt32Array, neighbors: Array[Dictionary], installed: Dictionary, city_roots: Dictionary, city_id: int, source_hub: int, reachable: PackedByteArray) -> bool:
	var cluster_site: int = city_roots.get(city_id, -1)
	if cluster_site >= 0:
		for edge_index in range(candidates.size()):
			var edge: Dictionary = candidates[edge_index]
			var a: int = edge["a"]
			var b: int = edge["b"]
			var a_city: int = sites[a]["city"]
			var b_city: int = sites[b]["city"]
			if not ((a_city == city_id and b_city != city_id) or (b_city == city_id and a_city != city_id)):
				continue
			var key := Vector2i(mini(a, b), maxi(a, b))
			if installed.has(key):
				continue
			var alignment: Dictionary = alignments[edge_index]
			if alignment.is_empty():
				alignment = planner.route(sites[a]["point"], sites[b]["point"], Roads.COLLECTOR, sites[a]["tangent"], -sites[b]["tangent"], true)
				alignments[edge_index] = alignment
			if alignment.is_empty():
				continue
			_install(region, sites[a]["node"], sites[b]["node"], Roads.COLLECTOR, alignment)
			installed[key] = true
			parents[_root(parents, b)] = _root(parents, a)
			degrees[a] += 1
			degrees[b] += 1
			neighbors[a][b] = alignment["length_km"]
			neighbors[b][a] = alignment["length_km"]
			if _nodes_reachable(region, source_hub)[region.city_hub_node_ids[city_id]] != 0:
				return true
	if cluster_site < 0:
		return false
	# Last resort: aim a route from the gate site at the nearest junction that
	# is already part of the physical network.
	var origin: Vector2 = sites[cluster_site]["point"]
	var ranked: Array[Dictionary] = []
	for index in range(sites.size()):
		if index != cluster_site and reachable[sites[index]["node"]] != 0:
			ranked.append({"index": index, "distance": origin.distance_to(sites[index]["point"])})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	var long_range_used := 0
	for entry in ranked.slice(0, 6):
		var target: int = entry["index"]
		var long_range: bool = long_range_used < 2
		if long_range:
			long_range_used += 1
		var alignment: Dictionary = planner.route(origin, sites[target]["point"], Roads.COLLECTOR, sites[cluster_site]["tangent"], Vector2.ZERO, false, long_range)
		if alignment.is_empty():
			continue
		_install(region, sites[cluster_site]["node"], sites[target]["node"], Roads.COLLECTOR, alignment)
		var key := Vector2i(mini(cluster_site, target), maxi(cluster_site, target))
		installed[key] = true
		parents[_root(parents, target)] = _root(parents, cluster_site)
		degrees[cluster_site] += 1
		degrees[target] += 1
		neighbors[cluster_site][target] = alignment["length_km"]
		neighbors[target][cluster_site] = alignment["length_km"]
		if _nodes_reachable(region, source_hub)[region.city_hub_node_ids[city_id]] != 0:
			return true
	return false


static func _nodes_reachable(region, source_node: int) -> PackedByteArray:
	var view: Dictionary = RoadGraph.adjacency(region)
	var neighbors: Array = view["neighbors"]
	var edge_from: PackedInt32Array = view["edge_from"]
	var edge_to: PackedInt32Array = view["edge_to"]
	var visited := PackedByteArray()
	visited.resize(region.road_nodes.size())
	var queue := PackedInt32Array([source_node])
	visited[source_node] = 1
	var cursor := 0
	while cursor < queue.size():
		var node_id: int = queue[cursor]
		cursor += 1
		for edge in neighbors[node_id]:
			var next_id: int = edge_to[edge.x] if edge.y == 0 else edge_from[edge.x]
			if visited[next_id] == 0:
				visited[next_id] = 1
				queue.append(next_id)
	return visited


static func _nearby_distance(neighbors: Array[Dictionary], first: int, last: int, limit: float) -> float:
	var queue: Array[int] = [first]
	var distances: Dictionary = {first: 0.0}
	var visited: Dictionary = {}
	while not queue.is_empty():
		var best := 0
		for index in range(1, queue.size()):
			if float(distances[queue[index]]) < float(distances[queue[best]]):
				best = index
		var id: int = queue[best]
		queue.remove_at(best)
		if visited.has(id):
			continue
		visited[id] = true
		var cost: float = distances[id]
		if cost > limit:
			break
		if id == last:
			return cost
		for other in neighbors[id]:
			var trial: float = cost + float(neighbors[id][other])
			if trial < float(distances.get(other, INF)):
				distances[other] = trial
				queue.append(other)
	return INF


static func _install(region, first: int, last: int, road_class: String, alignment: Dictionary):
	var link = Roads.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.corridor_id = link.id
	link.from_node_id = first
	link.to_node_id = last
	link.road_class = road_class
	link.lanes_per_direction = 2 if road_class == Roads.HIGHWAY else 1
	link.points = alignment["points"]
	link.elevation_profile_m = alignment["elevations_m"]
	link.terrain_spans.assign(alignment["terrain_spans"])
	link.recalculate_length()
	var owner_started: int = Time.get_ticks_usec()
	link.owner_jurisdiction_id = region.road_owner_for_points(link.points, road_class)
	var owner_us: int = Time.get_ticks_usec() - owner_started
	var crossings_started: int = Time.get_ticks_usec()
	link.crossings = RoadPlanner._crossings_for_route(region, link.points, road_class, {})
	var crossings_us: int = Time.get_ticks_usec() - crossings_started
	for crossing in link.crossings:
		crossing["above"] = road_class == Roads.HIGHWAY
	region.road_links.append(link)
	var surface_started: int = Time.get_ticks_usec()
	if road_class != Roads.HIGHWAY:
		RoadPlanner._connect_surface_crossings(region, link.corridor_id)
	var surface_us: int = Time.get_ticks_usec() - surface_started
	install_phase_us["owner"] = int(install_phase_us.get("owner", 0)) + owner_us
	install_phase_us["crossings"] = int(install_phase_us.get("crossings", 0)) + crossings_us
	install_phase_us["surface"] = int(install_phase_us.get("surface", 0)) + surface_us
	return link


static func _build_highways(region, planner, sites: Array[Dictionary]) -> Dictionary:
	var majors: Array[Dictionary] = []
	var gate_cities: Dictionary = {}
	var used: Dictionary = {}
	for city_id in region.starting_city_ids:
		var center: Vector2 = region.cities[city_id]["center_km"]
		var best := -1
		var distance := INF
		for index in range(sites.size()):
			if sites[index]["city"] >= 0:
				continue
			var trial: float = center.distance_to(sites[index]["point"])
			if trial >= 4.0 and trial < distance:
				distance = trial
				best = index
		if best >= 0:
			var node_id: int = sites[best]["node"]
			gate_cities[city_id] = node_id
			if not used.has(node_id):
				majors.append(sites[best])
				used[node_id] = true
	# Existing country junctions near opposite edges are through-route gateways.
	for sign_value in [-1.0, 1.0]:
		var best := -1
		var extreme := -INF
		for index in range(sites.size()):
			if sites[index]["city"] < 0 and sites[index]["point"].x * sign_value > extreme:
				best = index
				extreme = sites[index]["point"].x * sign_value
		if best >= 0 and not used.has(sites[best]["node"]):
			majors.append(sites[best])
			used[sites[best]["node"]] = true
	if majors.size() < 2:
		return {}
	var highway_stats := {"lines": 0, "legs": 0, "short": 0, "alignment_failed": 0, "attempts": 0}
	# Trunk corridors: a few long chained lines crossing the state through the
	# major gate sites, instead of a pocketed mesh of short Delaunay hops.
	var target_lines: int = clampi(majors.size() / 3, 3, 6)
	var unvisited: Dictionary = {}
	for index in range(majors.size()):
		unvisited[index] = true
	var chained: Dictionary = {}
	var chain_lengths: PackedVector2Array = PackedVector2Array()
	for line_index in range(target_lines):
		var start: int = _pick_trunk_start(majors, unvisited, chained, chain_lengths)
		if start < 0:
			break
		unvisited.erase(start)
		var chain: Array[int] = [start]
		var total_km := 0.0
		# Chained legs share their heading at each interchange so trunk lines
		# continue smoothly instead of snapping to a new direction.
		var chain_tangent := Vector2.ZERO
		while chain.size() < majors.size() and total_km < 900.0:
			var current: Dictionary = majors[chain[-1]]
			var direction: Vector2 = _trunk_heading(majors, chain)
			var ranked: Array[Dictionary] = _rank_trunk_candidates(majors, unvisited, current, direction, region)
			var installed := false
			for candidate in ranked.slice(0, 4):
				highway_stats["attempts"] += 1
				var next_index: int = candidate["index"]
				var first: int = current["node"]
				var last: int = majors[next_index]["node"]
				var a: Vector2 = region.road_nodes[first].position_km
				var b: Vector2 = region.road_nodes[last].position_km
				var alignment: Dictionary = planner.route(a, b, Roads.HIGHWAY, chain_tangent, Vector2.ZERO, false)
				if alignment.is_empty() and chain_tangent != Vector2.ZERO:
					alignment = planner.route(a, b, Roads.HIGHWAY, Vector2.ZERO, Vector2.ZERO, false)
				if alignment.is_empty():
					highway_stats["alignment_failed"] += 1
					continue
				var leg_km: float = float(alignment["length_km"])
				if leg_km < 30.0:
					highway_stats["short"] += 1
					continue
				for node_id in [first, last]:
					region.road_nodes[node_id].is_interchange = true
					region.road_nodes[node_id].interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([region.road_nodes[node_id].position_km]), Roads.HIGHWAY)
				var highway = _install(region, first, last, Roads.HIGHWAY, alignment)
				var leg_points: PackedVector2Array = highway.points
				chain_tangent = (leg_points[-1] - leg_points[-2]).normalized()
				_connect_highways(region, highway.corridor_id)
				unvisited.erase(next_index)
				chained[next_index] = true
				chain.append(next_index)
				total_km += leg_km
				highway_stats["legs"] += 1
				installed = true
				break
			if not installed:
				break
		if chain.size() >= 2:
			highway_stats["lines"] += 1
			chain_lengths.append(Vector2(majors[chain[0]]["point"].x, majors[chain[0]]["point"].y))
			for index in chain:
				chained[index] = true
	# Every starting settlement keeps a gateway on the trunk network, whatever
	# the travel-time economics of the sparse candidate list say.
	var attached := {}
	var attached_targets := {}
	for node_id in _highway_node_ids(region):
		attached[node_id] = true
	for _round in range(3):
		var joined := 0
		for city_id in gate_cities:
			var gate_node: int = gate_cities[city_id]
			if attached.has(gate_node):
				continue
			if _reach_highway_network(region, planner, gate_node, attached, attached_targets) >= 0:
				joined += 1
				highway_stats["guaranteed"] = int(highway_stats.get("guaranteed", 0)) + 1
		if joined == 0:
			break
	print("Highway candidates: ", highway_stats)
	var avoidance: Dictionary = _highway_avoidance(region)
	return {
		"gate_cities": gate_cities,
		"attached_targets": attached_targets,
		"avoid_costs": avoidance.get("costs", PackedFloat32Array()),
		"avoid_origin": avoidance.get("origin", Vector2i.ZERO),
		"avoid_step": avoidance.get("step", 4.0),
		"avoid_size": avoidance.get("size", Vector2i.ZERO),
	}


const AVOID_STEP_KM := 4.0
const AVOID_RADIUS_KM := 3.5
const AVOID_STRENGTH := 2.0


# Cost grid stamped from the trunk corridors: routes nearby pay extra per km so
# the rural web prefers neighbouring valleys over braiding along a highway.
static func _highway_avoidance(region) -> Dictionary:
	var polylines: Array[PackedVector2Array] = []
	for link in region.road_links:
		if link.road_class == Roads.HIGHWAY:
			polylines.append(link.points)
	if polylines.is_empty():
		return {}
	return _stamp_avoidance(region, polylines, AVOID_STRENGTH, AVOID_RADIUS_KM)


static func _stamp_avoidance(region, polylines, strength: float, radius: float) -> Dictionary:
	var bounds: Rect2 = region.jurisdictions[0].bounds_km
	var origin := Vector2i(floori(bounds.position.x / AVOID_STEP_KM), floori(bounds.position.y / AVOID_STEP_KM))
	var size := Vector2i(ceili(bounds.end.x / AVOID_STEP_KM) - origin.x, ceili(bounds.end.y / AVOID_STEP_KM) - origin.y)
	if size.x <= 0 or size.y <= 0:
		return {}
	var costs := PackedFloat32Array()
	costs.resize(size.x * size.y)
	for points in polylines:
		if points.size() < 2:
			continue
		for index in range(1, points.size()):
			var segment: float = points[index - 1].distance_to(points[index])
			var steps: int = maxi(1, roundi(segment / 2.0))
			for step in range(steps + 1):
				var sample: Vector2 = points[index - 1].lerp(points[index], float(step) / float(steps))
				var cell := Vector2i(floori(sample.x / AVOID_STEP_KM) - origin.x, floori(sample.y / AVOID_STEP_KM) - origin.y)
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var x: int = cell.x + dx
						var y: int = cell.y + dy
						if x < 0 or y < 0 or x >= size.x or y >= size.y:
							continue
						var center: Vector2 = Vector2(origin.x + x + 0.5, origin.y + y + 0.5) * AVOID_STEP_KM
						var falloff: float = strength * (1.0 - center.distance_to(sample) / radius)
						if falloff <= 0.0:
							continue
						var slot: int = y * size.x + x
						costs[slot] = maxf(costs[slot], falloff)
	return {"costs": costs, "origin": origin, "step": AVOID_STEP_KM, "size": size}


# A settlement's whole approach to its highway interchange is arterial: walk
# each hub->access path and promote the rural prefix up to the first link that
# already carries web or trunk traffic.
static func _promote_access_spurs(region) -> void:
	var costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	for city_id in region.starting_city_ids:
		var access_id: int = region.city_highway_access_node_ids[city_id]
		var hub_id: int = region.city_hub_node_ids[city_id]
		if access_id < 0 or access_id == hub_id:
			continue
		var route: Array[Vector2i] = RoadGraph.route_from_node(region, costs, access_id, hub_id)
		for edge in route:
			var link = region.road_links[edge.x]
			if link.road_class != Roads.COLLECTOR:
				break
			link.road_class = Roads.ARTERIAL


# Start points for trunk lines spread across the state: the first lines run
# coast to coast from the extreme gateways, later lines start where the
# existing trunks are farthest away.
static func _pick_trunk_start(majors: Array[Dictionary], unvisited: Dictionary, chained: Dictionary, chain_starts: PackedVector2Array) -> int:
	var western := -1
	var eastern := -1
	var west := INF
	var east := -INF
	for index in unvisited:
		var x: float = majors[index]["point"].x
		if x < west:
			west = x
			western = index
		if x > east:
			east = x
			eastern = index
	if chain_starts.is_empty():
		return western if western >= 0 else -1
	if chain_starts.size() == 1:
		return eastern if eastern >= 0 else -1
	var best := -1
	var best_gap := -INF
	for index in unvisited:
		var point: Vector2 = majors[index]["point"]
		var nearest := INF
		for start_point in chain_starts:
			nearest = minf(nearest, point.distance_to(start_point))
		if nearest > best_gap:
			best_gap = nearest
			best = index
	return best


# Direction a chain has been travelling, so the next leg keeps crossing the
# state instead of circling back over already-served territory.
static func _trunk_heading(majors: Array[Dictionary], chain: Array[int]) -> Vector2:
	var heading: Vector2 = majors[chain[-1]]["point"] - majors[chain[0]]["point"]
	return heading.normalized() if heading.length() > 0.001 else Vector2.ZERO


static func _rank_trunk_candidates(majors: Array[Dictionary], unvisited: Dictionary, current: Dictionary, direction: Vector2, region) -> Array[Dictionary]:
	var current_point: Vector2 = current["point"]
	var ranked: Array[Dictionary] = []
	for index in unvisited:
		var point: Vector2 = majors[index]["point"]
		var offset: Vector2 = point - current_point
		var distance: float = offset.length()
		if distance < 30.0 or distance > 450.0:
			continue
		var forward: float = 1.0
		if direction != Vector2.ZERO:
			forward = offset.normalized().dot(direction)
			if forward < -0.1:
				continue
		var penalty := 0.0
		for fraction in [0.25, 0.5, 0.75]:
			var sample: Vector2 = current_point.lerp(point, fraction)
			penalty += region.terrain.slope_at(sample) * 4.0 + (2.0 if region.terrain.water_at(sample) else 0.0)
		# Prefer steady 100-300 km legs: single super-legs across the whole
		# state exhaust the route search, so trunks chain forward hop by hop.
		var reach: float = clampf(distance, 100.0, 300.0)
		ranked.append({"index": index, "score": forward * reach / (1.0 + penalty)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	return ranked


static func _highway_node_ids(region) -> Dictionary:
	var ids := {}
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY:
			continue
		ids[link.from_node_id] = true
		ids[link.to_node_id] = true
	return ids


# Attach an isolated city gate to the existing trunk network with one more
# terrain-routed arterial, trying nearer junctions first and escalating to the
# long-range search budget when mountains stand in the way. Arterial
# connectors keep the trunk free of interchange split cascades while still
# guaranteeing every settlement a path onto the highway network.
static func _reach_highway_network(region, planner, gate_node: int, attached: Dictionary, attached_targets: Dictionary) -> int:
	var gate_point: Vector2 = region.road_nodes[gate_node].position_km
	var ranked: Array[Dictionary] = []
	for node_id in attached:
		ranked.append({"node": node_id, "distance": gate_point.distance_to(region.road_nodes[node_id].position_km)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	var long_range_used := 0
	for entry in ranked.slice(0, 6):
		var target: int = entry["node"]
		var target_point: Vector2 = region.road_nodes[target].position_km
		var alignment: Dictionary = planner.route(gate_point, target_point, Roads.ARTERIAL, Vector2.ZERO, Vector2.ZERO, false)
		if alignment.is_empty() and long_range_used < 2:
			long_range_used += 1
			alignment = planner.route(gate_point, target_point, Roads.ARTERIAL, Vector2.ZERO, Vector2.ZERO, false, true)
		if alignment.is_empty():
			continue
		_install(region, gate_node, target, Roads.ARTERIAL, alignment)
		attached[gate_node] = true
		attached_targets[gate_node] = target
		return target
	return -1


# Every starting settlement gets a highway access interchange: the gate itself
# when it sits on the trunk, otherwise the interchange where its chain of
# arterial connectors first touches the trunk network, or a final terrain-
# routed arterial spur where the gate has no connector at all.
static func _assign_highway_access(region, planner, gate_cities: Dictionary, attached_targets: Dictionary) -> void:
	var highway_ids := _highway_node_ids(region)
	if highway_ids.is_empty():
		return
	for city_id in gate_cities:
		var gate_node: int = gate_cities[city_id]
		var access_id: int = gate_node if highway_ids.has(gate_node) else _follow_to_highway(attached_targets, highway_ids, gate_node)
		if access_id < 0:
			access_id = _add_highway_spur(region, planner, gate_node)
		if access_id < 0:
			continue
		var node = region.road_nodes[access_id]
		node.is_interchange = true
		node.interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([node.position_km]), Roads.HIGHWAY)
		region.city_highway_access_node_ids[city_id] = access_id


# Walk a chain of arterial gate connectors to the interchange where the chain
# first touches the trunk network.
static func _follow_to_highway(attached_targets: Dictionary, highway_ids: Dictionary, gate_node: int) -> int:
	var visited := {}
	var node_id: int = gate_node
	while attached_targets.has(node_id) and not visited.has(node_id):
		visited[node_id] = true
		node_id = int(attached_targets[node_id])
		if highway_ids.has(node_id):
			return node_id
	return -1


static func _add_highway_spur(region, planner, gate_node: int) -> int:
	var gate_point: Vector2 = region.road_nodes[gate_node].position_km
	var options: Array[Dictionary] = []
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY:
			continue
		var point: Vector2 = RoadPlanner.closest_point(link.points, gate_point)
		options.append({"link_id": link.id, "point": point, "distance": point.distance_to(gate_point)})
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	for option in options.slice(0, 4):
		var point: Vector2 = option["point"]
		var alignment: Dictionary = planner.route(gate_point, point, Roads.ARTERIAL, Vector2.ZERO, Vector2.ZERO, true)
		if alignment.is_empty() or float(alignment["length_km"]) < 0.05:
			continue
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = point
		node.city_id = region.city_id_at_point(point)
		region.road_nodes.append(node)
		RoadPlanner.attach_junction(region, option["link_id"], node.id)
		_install(region, gate_node, node.id, Roads.ARTERIAL, alignment)
		return node.id
	return -1


static func _connect_highways(region, corridor_id: int) -> void:
	# Surface country crossings remain grade-separated; highway pairs get an
	# interchange where they actually meet. Braided corridors weaving through
	# the same valley for kilometres only interchange once per stretch instead
	# of fragmenting both routes at every weave.
	var pair_junctions := _highway_pair_junctions(region)
	var pending: Array[Dictionary] = []
	for link in region.road_links:
		if link.corridor_id != corridor_id:
			continue
		for crossing in link.crossings:
			var other_index: int = RoadGraph.link_index(region, crossing["link_id"])
			if other_index >= 0 and region.road_links[other_index].road_class == Roads.HIGHWAY:
				pending.append(crossing)
	for crossing in pending:
		var point: Vector2 = crossing["point"]
		var other_index: int = RoadGraph.link_index(region, crossing["link_id"])
		if other_index < 0:
			continue
		var other_corridor: int = region.road_links[other_index].corridor_id
		var pair_key := "%d|%d" % [mini(corridor_id, other_corridor), maxi(corridor_id, other_corridor)]
		if not _pair_has_interchange_near(pair_junctions, pair_key, point):
			var junction_id := -1
			for node in region.road_nodes:
				if node.position_km.distance_to(point) < 0.01:
					junction_id = node.id
					break
			if junction_id < 0:
				var node = RoadNodeData.new()
				node.id = region.road_nodes.size()
				node.position_km = point
				node.city_id = region.city_id_at_point(point)
				region.road_nodes.append(node)
				junction_id = node.id
			region.road_nodes[junction_id].is_interchange = true
			region.road_nodes[junction_id].interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([point]), Roads.HIGHWAY)
			for link in region.road_links:
				if link.road_class != Roads.HIGHWAY or RoadPlanner._node_at(region, link, point) >= 0:
					continue
				if RoadPlanner.closest_point(link.points, point).distance_to(point) < 0.001:
					RoadPlanner.attach_junction(region, link.id, junction_id)
			if not pair_junctions.has(pair_key):
				pair_junctions[pair_key] = []
			pair_junctions[pair_key].append(point)


# Junction points where two trunk corridors already meet, so later weaves of
# the same pair stay grade-separated.
static func _highway_pair_junctions(region) -> Dictionary:
	var corridors_at := {}
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY:
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			if not corridors_at.has(node_id):
				corridors_at[node_id] = {}
			corridors_at[node_id][link.corridor_id] = true
	var pair_junctions := {}
	for node in region.road_nodes:
		var corridors: Array = corridors_at.get(node.id, {}).keys()
		if corridors.size() < 2:
			continue
		corridors.sort()
		for i in range(corridors.size()):
			for j in range(i + 1, corridors.size()):
				var pair_key := "%d|%d" % [corridors[i], corridors[j]]
				if not pair_junctions.has(pair_key):
					pair_junctions[pair_key] = []
				pair_junctions[pair_key].append(node.position_km)
	return pair_junctions


const PAIR_INTERCHANGE_SPACING_KM := 25.0


static func _pair_has_interchange_near(pair_junctions: Dictionary, pair_key: String, point: Vector2) -> bool:
	for existing in pair_junctions.get(pair_key, []):
		if existing.distance_to(point) < PAIR_INTERCHANGE_SPACING_KM:
			return true
	return false
