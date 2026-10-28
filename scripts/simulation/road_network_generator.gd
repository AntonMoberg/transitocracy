extends RefCounted

const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Topology = preload("res://scripts/simulation/road_topology.gd")

const COUNTRYSIDE_SPACING_KM = 30.0

static var install_phase_us: Dictionary = {}


static func generate(region,progress=null) -> void:
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
	if progress!=null: progress.report("Placing city streets",region)
	for city in region.cities:
		UrbanGraph.build_starting_city(region, city)
	var planner = Planner.new(region)
	var sites: Array[Dictionary] = _sites(region)
	var generation_started: int = Time.get_ticks_msec()
	print("Regional road sites: ", sites.size())
	if sites.size() >= 2:
		# Layered phases: trunk corridors first, then the rural web spreads
		# from their interchanges and the city gates, avoiding trunk valleys.
		if progress!=null: progress.report("Routing highways",region)
		var highways: Dictionary = _build_highways(region, planner, sites)
		var candidates: Array[Dictionary] = _proximity_edges(region, sites)
		if not highways.is_empty():
			planner.set_avoidance(highways["avoid_costs"], highways["avoid_origin"], highways["avoid_step"], highways["avoid_size"])
		if progress!=null: progress.report("Connecting regional roads",region)
		_build_countryside(region, planner, sites, candidates, highways,progress)
		print("Countryside roads: %d links in %d ms" % [region.road_links.size(), Time.get_ticks_msec() - generation_started])
		_assign_highway_access(region, planner, highways.get("gate_cities", {}))
		_promote_access_spurs(region)
		if progress!=null: progress.report("Refining road connections",region)
		var topology_started:=Time.get_ticks_msec()
		print("Shared corridors: ", Topology.consolidate(region))
		print("Corridor consolidation ms: ",Time.get_ticks_msec()-topology_started)
		topology_started=Time.get_ticks_msec()
		print("Road topology: ", Topology.cleanup(region))
		print("Topology cleanup ms: ",Time.get_ticks_msec()-topology_started)
		topology_started=Time.get_ticks_msec()
		# Prune unused branches first: otherwise a temporary third arm can
		# hide a bend that becomes impossible once its overlapping fork moves.
		var short_merges:=Topology.consolidate_approaches(region)
		print("Shared approaches: ",short_merges)
		print("Approach consolidation ms: ",Time.get_ticks_msec()-topology_started)
		if short_merges>0: print("Final road topology: ",Topology.cleanup(region))
		_assign_highway_access(region, planner, highways.get("gate_cities", {}))
		_mark_map_backbone(region)
		print("Regional roads complete: %d ms" % (Time.get_ticks_msec() - generation_started))
	for link in region.road_links:
		link.owner_jurisdiction_id = region.road_owner_for_points(link.points, link.road_class)
		if link.road_class==Roads.HIGHWAY:
			var access:Array=[link.from_node_id,link.to_node_id]
			for junction in link.junctions: access.append(junction.node_id)
			for id in access:
				region.road_nodes[id].is_interchange=true
				region.road_nodes[id].interchange_owner_jurisdiction_id=link.owner_jurisdiction_id
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


static func _facing_city_site(sites:Array[Dictionary],site_id:int,target:Vector2) -> int:
	var city_id:int=sites[site_id].city
	if city_id<0: return site_id
	var best:=site_id
	var best_score:=INF
	for i in range(sites.size()):
		if sites[i].city!=city_id: continue
		var delta:Vector2=target-sites[i].point
		var facing:float=sites[i].tangent.normalized().dot(delta.normalized())
		# Attach on the side facing the incoming route. Nearest-point-only
		# selection can force a road to loop around an outward-facing city gate.
		var score:float=delta.length()+maxf(0.0,.25-facing)*8.0
		if score<best_score:
			best=i
			best_score=score
	return best

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
			if sites[a].city>=0 and sites[a].city==sites[b].city: continue
			a=_facing_city_site(sites,a,positions[b])
			b=_facing_city_site(sites,b,positions[a])
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


static func _build_countryside(region, planner, sites: Array[Dictionary], candidates: Array[Dictionary], highways: Dictionary = {},progress=null) -> void:
	var route_started: int = Time.get_ticks_usec()
	var alignments:Array=[]
	alignments.resize(candidates.size())
	var route_pool:Array=[]
	var routed_count:=0
	var next_preview_ms:=Time.get_ticks_msec()+500
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
	# Seed union-find from actual connected components, including interior junctions.
	var view: Dictionary = RoadGraph.adjacency(region)
	var node_components := _road_components(view)
	var component_sites := {}
	for index in range(sites.size()):
		var node_id: int = sites[index].node
		var component: int = node_components[node_id]
		if component_sites.has(component):
			parents[_root(parents, index)] = _root(parents, component_sites[component])
		else:
			component_sites[component] = index
	# Add the actual existing graph to loop-distance queries; do not treat two
	# gates on a long highway as either disconnected or zero kilometres apart.
	var node_offset: int = neighbors.size()
	for node_id in range(view.neighbors.size()): neighbors.append({})
	for edge in range(view.edge_from.size()):
		var a: int = node_offset + view.edge_from[edge]
		var b: int = node_offset + view.edge_to[edge]
		var km: float = region.road_links[view.edge_link[edge]].length_km * view.edge_fraction[edge]
		neighbors[a][b] = minf(km, float(neighbors[a].get(b, INF)))
		neighbors[b][a] = neighbors[a][b]
	for index in range(sites.size()):
		var node_id: int = node_offset + sites[index].node
		neighbors[index][node_id] = 0.0
		neighbors[node_id][index] = 0.0
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
				if not same_component or degrees[a] >= 3 or degrees[b] >= 3:
					continue
				var direct: float = sites[a]["point"].distance_to(sites[b]["point"])
				if direct > 75.0 or _nearby_distance(neighbors, a, b, direct * 1.85) <= direct * 1.85:
					continue
			if alignments[edge_index]==null:
				# Route a bounded lookahead only after inexpensive graph tests.
				# Eligibility is checked again when applying results in original order.
				var batch:Array[Dictionary]=[]
				var indices:Array[int]=[]
				for next in range(edge_index,candidates.size()):
					if alignments[next]!=null: continue
					var choice:Dictionary=candidates[next]
					var same:bool=_root(parents,choice.a)==_root(parents,choice.b)
					if not loops and same: continue
					if loops:
						if not same or degrees[choice.a]>=3 or degrees[choice.b]>=3: continue
						var direct:float=sites[choice.a].point.distance_to(sites[choice.b].point)
						if direct>75.0 or _nearby_distance(neighbors,choice.a,choice.b,direct*1.85)<=direct*1.85: continue
					batch.append(choice)
					indices.append(next)
					if batch.size()>=64: break
				var prepared:=_precompute_routes(region,sites,batch,highways,null,route_pool)
				for i in range(indices.size()): alignments[indices[i]]=prepared[i]
				routed_count+=batch.size()
				if progress!=null:
					progress.report("Connecting regional roads",region)
					progress.advance(routed_count,candidates.size())
			var alignment: Dictionary = alignments[edge_index]
			if alignment.is_empty():
				continue
			var install_started: int = Time.get_ticks_usec()
			_install(region, sites[a]["node"], sites[b]["node"], Roads.COLLECTOR, alignment)
			if progress!=null and Time.get_ticks_msec()>=next_preview_ms:
				progress.report("Installing regional roads",region)
				next_preview_ms=Time.get_ticks_msec()+500
			install_us += Time.get_ticks_usec() - install_started
			installed[key] = true
			parents[_root(parents, b)] = _root(parents, a)
			degrees[a] += 1
			degrees[b] += 1
			neighbors[a][b] = alignment["length_km"]
			neighbors[b][a] = alignment["length_km"]
	print("Countryside installs: %d in %d ms phases=%s surface=%s" % [installed.size(), install_us / 1000, install_phase_us, RoadPlanner.surface_phase_us])
	print("Countryside searches: %d / %d candidates in %.2f seconds"%[routed_count,candidates.size(),(Time.get_ticks_usec()-route_started)/1000000.0])
	if OS.get_cmdline_user_args().has("--profile-generation"):
		var totals:Dictionary={}
		for worker in route_pool:
			for stage in worker.profile_us: totals[stage]=int(totals.get(stage,0))+worker.profile_us[stage]
		print("Rural worker CPU microseconds (search includes cells/edges/tunnels): ",totals)
	for i in range(alignments.size()):
		if alignments[i]==null: alignments[i]={}
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
	# Shared valley alignments are consolidated after the network is assembled.
	# Rerouting a road in isolation discarded its existing junctions.


const BRAID_SAMPLE_KM := 2.0
const BRAID_NEAR_KM := 1.0
const TRUNK_OVERLAP_REROUTE_KM := 12.0
const PAIR_OVERLAP_REROUTE_KM := 10.0
const REROUTE_STRENGTH := 4.0
const REROUTE_MAX_STRETCH := 1.5


# Routes share valleys by construction; send the worst offenders looking for
# their own path once the whole web exists. Keeps the original geometry when
# no reasonable alternative route exists.
static func _de_braid(region) -> void:
	var started: int = Time.get_ticks_msec()
	var trunk_jobs: Array[Dictionary] = []
	var trunk_polylines: Array[PackedVector2Array] = []
	for link in region.road_links:
		if link.road_class == Roads.HIGHWAY:
			trunk_polylines.append(link.points)
	if not trunk_polylines.is_empty():
		var trunk_cells := _sample_cells(trunk_polylines)
		for link in region.road_links:
			if link.road_class != Roads.COLLECTOR or link.managed_neighborhood_id >= 0:
				continue
			if _overlap_km(_link_samples(link), trunk_cells) >= TRUNK_OVERLAP_REROUTE_KM:
				trunk_jobs.append({"link": link, "polylines": trunk_polylines, "radius": AVOID_RADIUS_KM})
	var pair_jobs: Array[Dictionary] = []
	var by_id := {}
	for link in region.road_links:
		if link.road_class == Roads.COLLECTOR and link.managed_neighborhood_id < 0:
			by_id[link.id] = link
	if by_id.size() >= 2:
		var pair_overlap := _pair_overlaps(by_id)
		for pair_key in pair_overlap:
			if float(pair_overlap[pair_key]) < PAIR_OVERLAP_REROUTE_KM:
				continue
			var first = by_id[pair_key.x]
			var second = by_id[pair_key.y]
			var victim = first if first.length_km <= second.length_km else second
			var kept = second if victim == first else first
			pair_jobs.append({"link": victim, "polylines": [kept.points], "radius": 2.5})
	var stats := {"trunk": trunk_jobs.size(), "pairs": pair_jobs.size()}
	var rerouted := _plan_and_apply_reroutes(region, trunk_jobs)
	rerouted += _plan_and_apply_reroutes(region, pair_jobs)
	stats["rerouted"] = rerouted
	stats["ms"] = Time.get_ticks_msec() - started
	print("De-braid: ", stats)


static func _link_samples(link) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	for index in range(1, link.points.size()):
		var segment: float = link.points[index - 1].distance_to(link.points[index])
		var steps: int = maxi(1, roundi(segment / BRAID_SAMPLE_KM))
		for step in range(steps):
			samples.append({"point": link.points[index - 1].lerp(link.points[index], float(step) / float(steps)), "spacing": segment / float(steps)})
	return samples


static func _sample_cells(polylines: Array[PackedVector2Array]) -> Dictionary:
	var cells := {}
	for points in polylines:
		for index in range(1, points.size()):
			var segment: float = points[index - 1].distance_to(points[index])
			var steps: int = maxi(1, roundi(segment / BRAID_SAMPLE_KM))
			for step in range(steps + 1):
				var sample: Vector2 = points[index - 1].lerp(points[index], float(step) / float(steps))
				var key := Vector2i(floori(sample.x / BRAID_SAMPLE_KM), floori(sample.y / BRAID_SAMPLE_KM))
				if not cells.has(key):
					cells[key] = PackedVector2Array()
				cells[key].append(sample)
	return cells


static func _overlap_km(samples: Array[Dictionary], cells: Dictionary) -> float:
	var total := 0.0
	for sample in samples:
		var point: Vector2 = sample["point"]
		var base := Vector2i(floori(point.x / BRAID_SAMPLE_KM), floori(point.y / BRAID_SAMPLE_KM))
		var near := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if _near_any(point, cells.get(Vector2i(base.x + dx, base.y + dy), PackedVector2Array())):
					near = true
					break
			if near:
				break
		if near:
			total += float(sample["spacing"])
	return total


static func _near_any(point: Vector2, others: PackedVector2Array) -> bool:
	var limit: float = BRAID_NEAR_KM * BRAID_NEAR_KM
	for other in others:
		if point.distance_squared_to(other) < limit:
			return true
	return false


# Shared-overlap kilometres for every unordered pair of countryside links.
static func _pair_overlaps(by_id: Dictionary) -> Dictionary:
	var cells := {}
	var samples_by_id := {}
	for link_id in by_id:
		var samples: Array[Dictionary] = _link_samples(by_id[link_id])
		samples_by_id[link_id] = samples
		for sample in samples:
			var key := Vector2i(floori(sample["point"].x / BRAID_SAMPLE_KM), floori(sample["point"].y / BRAID_SAMPLE_KM))
			if not cells.has(key):
				cells[key] = []
			cells[key].append(link_id)
			cells[key].append(sample["point"])
	var pair_overlap := {}
	for link_id in by_id:
		for sample in samples_by_id[link_id]:
			var point: Vector2 = sample["point"]
			var base := Vector2i(floori(point.x / BRAID_SAMPLE_KM), floori(point.y / BRAID_SAMPLE_KM))
			var near := {}
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var entries: Array = cells.get(Vector2i(base.x + dx, base.y + dy), [])
					for entry_index in range(0, entries.size(), 2):
						var other_id: int = entries[entry_index]
						if other_id == link_id or near.has(other_id):
							continue
						if point.distance_to(entries[entry_index + 1]) < BRAID_NEAR_KM:
							near[other_id] = true
			for other_id in near:
				if other_id < link_id:
					continue
				var pair_key := Vector2i(link_id, other_id)
				pair_overlap[pair_key] = float(pair_overlap.get(pair_key, 0.0)) + float(sample["spacing"])
	return pair_overlap


# Re-routes are planned in parallel (read-only region access) and applied on
# the main thread; a stretch beyond 1.5x the original keeps the original.
static func _plan_and_apply_reroutes(region, jobs: Array[Dictionary]) -> int:
	if jobs.is_empty():
		return 0
	var alignments: Array = []
	alignments.resize(jobs.size())
	var plan_job := func(index: int) -> void:
		var job: Dictionary = jobs[index]
		var local = Planner.new(region)
		var grid: Dictionary = _stamp_avoidance(region, job["polylines"], REROUTE_STRENGTH, job["radius"])
		if not grid.is_empty():
			local.set_avoidance(grid["costs"], grid["origin"], grid["step"], grid["size"])
		alignments[index] = local.route(region.road_nodes[job["link"].from_node_id].position_km, region.road_nodes[job["link"].to_node_id].position_km, job["link"].road_class, Vector2.ZERO, Vector2.ZERO, false)
	if jobs.size() >= 8 and OS.get_processor_count() > 1:
		var workers: int = mini(8, OS.get_processor_count() - 1)
		var task_id: int = WorkerThreadPool.add_group_task(plan_job, jobs.size(), workers, false, "De-braid routes")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for index in range(jobs.size()):
			plan_job.call(index)
	var applied := 0
	for index in range(jobs.size()):
		var job: Dictionary = jobs[index]
		var link = job["link"]
		var alignment: Dictionary = alignments[index]
		if alignment.is_empty() or float(alignment["length_km"]) > link.length_km * REROUTE_MAX_STRETCH:
			if alignment.is_empty():
				print("  de-braid keep %d: no alternative route" % link.id)
			else:
				print("  de-braid keep %d: %.1f km alternative too long" % [link.id, float(alignment["length_km"])])
			continue
		link.points = alignment["points"]
		link.elevation_profile_m = alignment["elevations_m"]
		link.terrain_spans.assign(alignment["terrain_spans"])
		link.junctions.clear()
		link.recalculate_length()
		link.owner_jurisdiction_id = region.road_owner_for_points(link.points, link.road_class)
		link.crossings = RoadPlanner._crossings_for_route(region, link.points, link.road_class, {})
		for crossing in link.crossings:
			crossing["above"] = link.road_class == Roads.HIGHWAY
		applied += 1
		# Surface attachments reference the replaced geometry; cross the
		# corridor again so junctions re-attach where the new path meets.
		RoadPlanner._connect_surface_crossings(region, link.corridor_id)
	return applied


# Routes never depend on installed roads, so every proximity candidate can be
# searched in parallel before the sequential union-find passes pick installs.
static func _avoidance_planner(region, highways: Dictionary):
	var local = Planner.new(region)
	if highways.has("avoid_costs") and not highways["avoid_costs"].is_empty():
		local.set_avoidance(highways["avoid_costs"], highways["avoid_origin"], highways["avoid_step"], highways["avoid_size"])
	return local


static func _precompute_routes(region, sites: Array[Dictionary], candidates: Array[Dictionary], highways: Dictionary = {},progress=null,pool:Array=[]) -> Array:
	var results: Array = []
	results.resize(candidates.size())
	var routed := 0
	var jobs: Array[int] = []
	for index in range(candidates.size()):
		jobs.append(index)
	if jobs.is_empty():
		return results
	var workers: int = maxi(1, mini(8, OS.get_processor_count() - 1))
	if pool.is_empty():
		for i in range(workers): pool.append(_avoidance_planner(region,highways))
	var started: int = Time.get_ticks_usec()
	if workers == 1 or jobs.size() < 8:
		var local = pool[0]
		local.edge_computed.fill(0)
		if local.tunnel_cache.size()>=65536: local.tunnel_cache.clear()
		for index in jobs:
			results[index] = _route_candidate(local, sites, candidates[index])
			if progress!=null: progress.advance(1,jobs.size())
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
	var dispatch:Dictionary={"next":0}
	var dispatch_mutex:=Mutex.new()
	var route_chunk := func(worker_id: int) -> void:
		var local = pool[worker_id]
		# Immutable terrain samples and tunnel measurements survive a batch. Route-dependent caches
		# reset, so dynamic scheduling cannot change a candidate's result.
		while true:
			dispatch_mutex.lock()
			var chunk:int=dispatch.next
			dispatch.next+=1
			dispatch_mutex.unlock()
			if chunk>=chunk_count: break
			local.edge_computed.fill(0)
			if local.tunnel_cache.size()>=65536: local.tunnel_cache.clear()
			var slot: Array = chunk_slots[chunk]
			var start: int = chunk * chunk_size
			var finish: int = mini(start + chunk_size, order.size())
			for position in range(start, finish):
				var candidate_index: int = order[position]
				slot.append([candidate_index, _route_candidate(local, sites, candidates[candidate_index])])
				if progress!=null: progress.advance(1,jobs.size())
	var task_id := WorkerThreadPool.add_group_task(route_chunk, workers, workers, true, "Countryside routes")
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
	var gates: Array[Dictionary] = []
	var gate_cities := {}
	# Highway endpoints are chosen around real settlements, independently of
	# optional countryside samples. This remains deterministic as density changes.
	for city_id in region.starting_city_ids:
		var center: Vector2 = region.cities[city_id].center_km
		var best := Vector2.INF
		var best_score := INF
		for radius in [8.0, 12.0, 16.0]:
			for direction in range(16):
				var point: Vector2 = center + Vector2.from_angle(direction * TAU / 16.0) * radius
				if not region.jurisdictions[0].contains_point(point) or region.terrain.water_at(point): continue
				var slope: float = region.terrain.slope_at(point)
				if slope > 0.10: continue
				var score: float = radius + slope * 200.0 + maxf(0.0, region.terrain.elevation_at(point) - region.terrain.elevation_at(center)) * 0.02
				if score < best_score:
					best_score = score
					best = point
		if not best.is_finite(): continue
		_add_site(region, sites, best)
		var node_id: int = sites[-1].node
		gate_cities[city_id] = node_id
		gates.append({"point":best, "node":node_id, "city":city_id})
	if gates.size() < 2: return {}
	var macro = Planner.new(region, 8.0)
	var detailed = Planner.new(region, 4.0)
	var candidates := _state_corridor_candidates(gates, macro)
	var installed: Array = []
	var served := {}
	var route_id := 0
	for candidate in candidates:
		if installed.size() >= 2: break
		if not installed.is_empty():
			var newly_served := 0
			for gate in gates:
				if not served.has(gate.city) and RoadPlanner.closest_point(candidate.guide, gate.point).distance_to(gate.point) < 40.0: newly_served += 1
			var distinct := 0
			for point in candidate.guide:
				if RoadPlanner.closest_point(installed[0].points, point).distance_to(point) > 20.0: distinct += 1
			if newly_served < 2 or distinct < candidate.guide.size() / 2: continue
		var alignment: Dictionary = detailed.align_corridor(candidate.guide)
		if alignment.is_empty(): continue
		var connection := {}
		if not installed.is_empty():
			connection = _corridor_connection(region, macro, detailed, installed[0], alignment.points)
			if connection.is_empty(): continue
		var link = _install(region, gates[candidate.a].node, gates[candidate.b].node, Roads.HIGHWAY, alignment)
		link.trunk_route_id = route_id
		route_id += 1
		link.map_major = true
		installed.append(link)
		_connect_highways(region, link.corridor_id)
		if not connection.is_empty():
			var first_node: int = _corridor_junction(region, sites, installed[0], connection.a)
			var last_node: int = _corridor_junction(region, sites, link, connection.b)
			var connector = _install(region, first_node, last_node, Roads.HIGHWAY, connection.alignment)
			connector.trunk_route_id = route_id
			connector.map_major = true
			route_id += 1
			installed.append(connector)
			_connect_highways(region, connector.corridor_id)
		for gate in gates:
			if RoadPlanner.closest_point(link.points, gate.point).distance_to(gate.point) < 40.0: served[gate.city] = true
	# Attach unserved cities to the network itself, allowing shared regional
	# branches. Routes end at a real junction on the chosen existing highway.
	var remaining: Array = gates.duplicate()
	while not remaining.is_empty() and not installed.is_empty():
		var choices: Array[Dictionary] = []
		for gate_index in range(remaining.size()):
			var gate: Dictionary = remaining[gate_index]
			for link in installed:
				var target: Vector2 = RoadPlanner.closest_point(link.points, gate.point)
				choices.append({"gate":gate_index,"link":link,"point":target,"distance":target.distance_to(gate.point)})
		choices.sort_custom(func(a,b): return a.distance < b.distance)
		var gate: Dictionary = remaining[choices[0].gate]
		var gate_index: int = choices[0].gate
		for choice in choices:
			if int(choice.gate) != gate_index: continue
			if float(choice.distance) < 0.01:
				RoadPlanner.attach_junction(region, choice.link.id, gate.node)
				break
			var road_class: String = Roads.ARTERIAL if float(choice.distance) < 40.0 else Roads.HIGHWAY
			var alignment := {}
			if road_class == Roads.HIGHWAY:
				var guide: Dictionary = macro.plan_corridor(gate.point, choice.point)
				if not guide.is_empty(): alignment = detailed.align_corridor(guide.points)
			if alignment.is_empty():
				road_class = Roads.ARTERIAL
				alignment = planner.route(gate.point, choice.point, road_class, Vector2.ZERO, Vector2.ZERO, true, true)
			if alignment.is_empty(): continue
			var target_id: int = RoadPlanner._node_at(region, choice.link, choice.point)
			if target_id < 0:
				_add_site(region, sites, choice.point)
				target_id = sites[-1].node
				RoadPlanner.attach_junction(region, choice.link.id, target_id)
			region.road_nodes[target_id].is_interchange = true
			region.road_nodes[target_id].interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([choice.point]), Roads.HIGHWAY)
			var branch = _install(region, gate.node, target_id, road_class, alignment)
			branch.map_major = true
			if road_class == Roads.HIGHWAY:
				branch.trunk_route_id = route_id
				route_id += 1
				installed.append(branch)
				_connect_highways(region, branch.corridor_id)
			break
		remaining.remove_at(gate_index)
	for link in installed:
		for node_id in [link.from_node_id, link.to_node_id]:
			region.road_nodes[node_id].is_interchange = true
			region.road_nodes[node_id].interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([region.road_nodes[node_id].position_km]), Roads.HIGHWAY)
	print("Terrain corridors: candidates=%d highways=%d cities=%d" % [candidates.size(), installed.size(), gates.size()])
	var avoidance: Dictionary = _highway_avoidance(region)
	return {"gate_cities":gate_cities,"avoid_costs":avoidance.get("costs",PackedFloat32Array()),"avoid_origin":avoidance.get("origin",Vector2i.ZERO),"avoid_step":avoidance.get("step",4.0),"avoid_size":avoidance.get("size",Vector2i.ZERO)}


static func _corridor_junction(region, sites: Array[Dictionary], link, point: Vector2) -> int:
	var node_id: int = RoadPlanner._node_at(region, link, point)
	if node_id < 0:
		_add_site(region, sites, point)
		node_id = sites[-1].node
		RoadPlanner.attach_junction(region, link.id, node_id)
	region.road_nodes[node_id].is_interchange = true
	region.road_nodes[node_id].interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([point]), Roads.HIGHWAY)
	return node_id


static func _corridor_connection(_region, macro, detailed, existing, points: PackedVector2Array) -> Dictionary:
	var choices: Array[Dictionary] = []
	for i in range(0, points.size(), maxi(1, points.size()/24)):
		var a: Vector2 = RoadPlanner.closest_point(existing.points, points[i])
		var distance: float = a.distance_to(points[i])
		if distance < 4.0: continue
		choices.append({"a":a,"b":points[i],"distance":distance})
	choices.sort_custom(func(a,b): return a.distance < b.distance)
	for choice in choices.slice(0, 4):
		var trace: Dictionary = macro.plan_corridor(choice.a, choice.b)
		if trace.is_empty(): continue
		var alignment: Dictionary = detailed.align_corridor(trace.points)
		if not alignment.is_empty(): return {"a":choice.a,"b":choice.b,"alignment":alignment}
	return {}


static func _state_corridor_candidates(gates: Array[Dictionary], planner) -> Array[Dictionary]:
	var extent := Rect2(gates[0].point, Vector2.ZERO)
	for gate in gates: extent = extent.expand(gate.point)
	var pairs: Array[Dictionary] = []
	var seen := {}
	# Reserve candidates for both axes; a wide state must not exclude all
	# north/south valleys merely because its east/west pairs are longer.
	for axis in range(2):
		if extent.size[axis] < 1.0: continue
		var axis_pairs: Array[Dictionary] = []
		for a in range(gates.size()):
			for b in range(a+1, gates.size()):
				var delta: Vector2 = (gates[b].point - gates[a].point).abs()
				if delta[axis] < extent.size[axis] * 0.7: continue
				axis_pairs.append({"a":a,"b":b,"distance":delta.length(),"span":delta[axis]})
		axis_pairs.sort_custom(func(a,b): return a.span > b.span)
		for pair in axis_pairs.slice(0,4):
			var key := Vector2i(pair.a,pair.b)
			if seen.has(key): continue
			seen[key] = true
			pairs.append(pair)
	var result: Array[Dictionary] = []
	for pair in pairs.slice(0, 8):
		var trace: Dictionary = planner.plan_corridor(gates[pair.a].point, gates[pair.b].point)
		if trace.is_empty(): continue
		result.append({"a":pair.a,"b":pair.b,"guide":trace.points,"score":float(trace.cost) / maxf(1.0,pair.distance * pair.distance)})
	result.sort_custom(func(a,b): return a.score < b.score)
	return result


static func _road_components(view: Dictionary) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(view.neighbors.size())
	result.fill(-1)
	for start in range(result.size()):
		if result[start] >= 0: continue
		var queue: Array[int] = [start]
		result[start] = start
		var cursor := 0
		while cursor < queue.size():
			var node: int = queue[cursor]
			cursor += 1
			for edge in view.neighbors[node]:
				var other: int = view.edge_to[edge.x] if edge.y == 0 else view.edge_from[edge.x]
				if result[other] < 0:
					result[other] = start
					queue.append(other)
	return result


static func _mark_map_backbone(region) -> void:
	# Static geography, never live congestion: preserve continuous approaches
	# and a spanning backbone between the developed settlement hubs.
	var costs := RoadGraph.free_flow_costs(region)
	var cities: Array = region.starting_city_ids.duplicate()
	for city_id in cities:
		var access: int = region.city_highway_access_node_ids[city_id]
		if access >= 0:
			for edge in RoadGraph.route_from_node(region, costs, region.city_hub_node_ids[city_id], access):
				region.road_links[edge.x].map_major = true
	if cities.is_empty(): return
	var attached: Array = [cities.pop_front()]
	while not cities.is_empty():
		var best := Vector2i(-1,-1)
		var distance := INF
		for index in range(cities.size()):
			for city_id in attached:
				var trial: float = region.cities[cities[index]].center_km.distance_to(region.cities[city_id].center_km)
				if trial < distance:
					distance = trial
					best = Vector2i(index, city_id)
		var city_id: int = cities[best.x]
		for edge in RoadGraph.route_from_node(region, costs, region.city_hub_node_ids[city_id], region.city_hub_node_ids[best.y]):
			region.road_links[edge.x].map_major = true
		attached.append(city_id)
		cities.remove_at(best.x)


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


static func _highway_node_ids(region) -> Dictionary:
	var ids := {}
	for link in region.road_links:
		if link.road_class != Roads.HIGHWAY:
			continue
		ids[link.from_node_id] = true
		ids[link.to_node_id] = true
		for junction in link.junctions: ids[int(junction.node_id)] = true
	return ids


# Resolve access from the finished graph, including interior interchanges and
# countryside rescue links. Endpoint bookkeeping alone can miss valid access.
static func _assign_highway_access(region, planner, gate_cities: Dictionary) -> void:
	var highway_ids := _highway_node_ids(region)
	if highway_ids.is_empty(): return
	var view := RoadGraph.adjacency(region)
	var costs := RoadGraph.free_flow_costs(region)
	for city_id in region.starting_city_ids:
		var hub: int = region.city_hub_node_ids[city_id]
		var tree := RoadGraph._shortest_tree(region, costs, view, hub, false, false, false)
		var access_id := -1
		var minutes: float = RoadGraph.UNREACHABLE_MINUTES
		for node_id in highway_ids:
			if tree.distances[node_id] < minutes:
				minutes = tree.distances[node_id]
				access_id = node_id
		if access_id < 0:
			access_id = _add_highway_spur(region, planner, gate_cities.get(city_id, hub))
			if access_id >= 0:
				highway_ids[access_id] = true
				view = RoadGraph.adjacency(region)
				costs = RoadGraph.free_flow_costs(region)
		if access_id < 0:
			push_warning("No terrain-feasible highway access for starting city %d" % city_id)
			continue
		var node = region.road_nodes[access_id]
		node.is_interchange = true
		node.interchange_owner_jurisdiction_id = region.road_owner_for_points(PackedVector2Array([node.position_km]), Roads.HIGHWAY)
		region.city_highway_access_node_ids[city_id] = access_id


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
