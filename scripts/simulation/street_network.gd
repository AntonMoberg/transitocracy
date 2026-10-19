extends RefCounted

const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const Planner = preload("res://scripts/simulation/road_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const Paths = preload("res://scripts/simulation/street_paths.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")


static func attach(region, neighborhood, layout, completed: bool = false) -> void:
	neighborhood.street_layout = layout
	if neighborhood.character_profile.is_empty():
		neighborhood.character_profile = Character.resolve(region, neighborhood.city_id, neighborhood.position_km, layout.interior_style, neighborhood.zone_shares, neighborhood.zone_density)
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
		var road_class: String = path.get("road_class", Roads.COLLECTOR)
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
		var existing_index: int = Spatial.cache(region)["pairs"].get(Spatial.pair_key(first, last, road_class), -1)
		var existing_id: int = region.road_links[existing_index].id if existing_index >= 0 else -1
		if existing_id >= 0:
			plan.core_link_ids[path_index] = existing_id
			continue
		var covered_id: int = _covered_by_collectors(region, path["points"]) if road_class == Roads.COLLECTOR else -1
		if covered_id >= 0:
			plan.core_link_ids[path_index] = covered_id
			continue
		var runs: Array[PackedVector2Array] = []
		if road_class == Roads.COLLECTOR:
			runs = _uncovered_collector_runs(region, path["points"])
		else:
			runs.append(path["points"])
		for run in runs:
			var run_first: int = first if run[0].distance_to(path["points"][0]) < 0.001 else ensure_node(region, run[0], neighborhood.city_id)
			var run_last: int = last if run[-1].distance_to(path["points"][-1]) < 0.001 else ensure_node(region, run[-1], neighborhood.city_id)
			if run_first == run_last:
				continue
			var run_pair: int = Spatial.cache(region)["pairs"].get(Spatial.pair_key(run_first, run_last, road_class), -1)
			if run_pair >= 0:
				if not plan.core_link_ids.has(path_index):
					plan.core_link_ids[path_index] = region.road_links[run_pair].id
				continue
			var link = Roads.new()
			link.id = region.next_road_link_id
			region.next_road_link_id += 1
			link.from_node_id = run_first
			link.to_node_id = run_last
			link.road_class = road_class
			link.lanes_per_direction = ceili(paid_multiplier)
			link.points = _clean_path(run)
			link.owner_jurisdiction_id = region.city_jurisdiction_ids[neighborhood.city_id]
			link.managed_neighborhood_id = neighborhood.id
			link.recalculate_length()
			region.road_links.append(link)
			if not plan.core_link_ids.has(path_index):
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
	if not neighborhood.initially_developed:
		_join_adjacent_districts(region, neighborhood)
	region.road_geometry_revision += 1
	return true


static func _join_adjacent_districts(region, neighborhood) -> void:
	var layout = neighborhood.street_layout
	var used_nodes: Dictionary = Spatial.cache(region)["used_nodes"]
	for other in region.neighborhoods:
		if other.id == neighborhood.id or other.city_id != neighborhood.city_id or other.street_layout == null or other.development_plan == null or other.development_plan.completed_phase == 0:
			continue
		if not layout.bounds.grow(0.01).intersects(other.street_layout.bounds):
			continue
		var seam: PackedVector2Array = _shared_boundary_samples(layout.polygon, other.street_layout.polygon)
		if seam.is_empty():
			continue
		var current_ids: Dictionary = {}
		for local_id in neighborhood.development_plan.core_node_ids:
			current_ids[neighborhood.development_plan.core_node_ids[local_id]] = true
		var other_ids: Dictionary = {}
		for local_id in other.development_plan.core_node_ids:
			other_ids[other.development_plan.core_node_ids[local_id]] = true
		var installed: Array[Vector2] = []
		var has_local_seam := false
		for link in region.road_links:
			if link.road_class in [Roads.COLLECTOR, Roads.LOCAL] and ((current_ids.has(link.from_node_id) and other_ids.has(link.to_node_id)) or (other_ids.has(link.from_node_id) and current_ids.has(link.to_node_id))):
				installed.append((region.road_nodes[link.from_node_id].position_km + region.road_nodes[link.to_node_id].position_km) * 0.5)
				has_local_seam = has_local_seam or link.road_class == Roads.LOCAL
		if installed.size() >= 2 or has_local_seam:
			continue
		var candidates: Array[Dictionary] = []
		for local_id in neighborhood.development_plan.core_node_ids:
			if layout.arterial_nodes.has(local_id):
				continue
			var first: int = neighborhood.development_plan.core_node_ids[local_id]
			if not used_nodes.has(first):
				continue
			var first_point: Vector2 = region.road_nodes[first].position_km
			for other_local_id in other.development_plan.core_node_ids:
				if other.street_layout.arterial_nodes.has(other_local_id):
					continue
				var last: int = other.development_plan.core_node_ids[other_local_id]
				if first == last or not used_nodes.has(last):
					continue
				var last_point: Vector2 = region.road_nodes[last].position_km
				var length: float = first_point.distance_to(last_point)
				if length < 0.015 or length > 0.4:
					continue
				var middle: Vector2 = (first_point + last_point) * 0.5
				var seam_distance := INF
				for point in seam:
					seam_distance = minf(seam_distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, first_point, last_point)))
				if seam_distance > 0.03 or _crosses_arterial(region, first_point, last_point) or _connector_crosses_blocks(layout, first_point, last_point) or _connector_crosses_blocks(other.street_layout, first_point, last_point):
					continue
				candidates.append({"from": first, "to": last, "middle": middle, "score": length + seam_distance * 3.0})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) < float(b["score"]))
		for candidate in candidates:
			var separated := true
			for point in installed:
				if point.distance_to(candidate["middle"]) < 0.35:
					separated = false
			if not separated:
				continue
			var first: int = candidate["from"]
			var last: int = candidate["to"]
			if Spatial.cache(region)["pairs"].has(Spatial.pair_key(first, last, Roads.COLLECTOR)):
				continue
			var connector := PackedVector2Array([region.road_nodes[first].position_km, region.road_nodes[last].position_km])
			if _covered_by_collectors(region, connector) >= 0:
				continue
			var link = Roads.new()
			link.id = region.next_road_link_id
			region.next_road_link_id += 1
			link.from_node_id = first
			link.to_node_id = last
			link.road_class = Roads.COLLECTOR
			link.points = connector
			link.owner_jurisdiction_id = region.city_jurisdiction_ids[neighborhood.city_id]
			link.managed_neighborhood_id = neighborhood.id
			link.lanes_per_direction = ceili(neighborhood.development_plan.installed_multiplier)
			link.recalculate_length()
			region.road_links.append(link)
			installed.append(candidate["middle"])
			if installed.size() >= 2:
				break
		if installed.is_empty():
			_join_local_streets(region, neighborhood, other, seam, used_nodes)


static func _join_local_streets(region, neighborhood, other, seam: PackedVector2Array, used_nodes: Dictionary) -> void:
	var first_layout = neighborhood.street_layout
	var last_layout = other.street_layout
	var first_tree: Dictionary = _local_access_tree(first_layout, neighborhood.development_plan, used_nodes)
	var last_tree: Dictionary = _local_access_tree(last_layout, other.development_plan, used_nodes)
	if first_tree.is_empty() or last_tree.is_empty():
		return
	var first_nodes: Array[int] = _seam_street_nodes(first_layout, first_tree, seam)
	var last_nodes: Array[int] = _seam_street_nodes(last_layout, last_tree, seam)
	var best := {}
	var best_score := INF
	for first_id in first_nodes:
		var first_point: Vector2 = first_layout.nodes[first_id]
		for last_id in last_nodes:
			var last_point: Vector2 = last_layout.nodes[last_id]
			var gap: float = first_point.distance_to(last_point)
			if gap < 0.015 or gap > 0.32:
				continue
			var seam_distance := INF
			for point in seam:
				seam_distance = minf(seam_distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, first_point, last_point)))
			if seam_distance > 0.035 or _crosses_arterial(region, first_point, last_point) or _connector_crosses_blocks(first_layout, first_point, last_point) or _connector_crosses_blocks(last_layout, first_point, last_point):
				continue
			var score: float = gap + float(first_tree["distances"][first_id] + last_tree["distances"][last_id]) * 0.4 + seam_distance * 2.0
			if score < best_score:
				best_score = score
				best = {"first": first_id, "last": last_id}
	if best.is_empty():
		return
	var first_global: int = _install_local_access(region, neighborhood, first_tree, best["first"])
	var last_global: int = _install_local_access(region, other, last_tree, best["last"])
	if first_global < 0 or last_global < 0 or first_global == last_global:
		return
	_append_seam_link(region, first_global, last_global, Roads.LOCAL, neighborhood)


static func _local_access_tree(layout, plan, used_nodes: Dictionary) -> Dictionary:
	var sources := PackedInt32Array()
	for local_id in plan.core_node_ids:
		if used_nodes.has(plan.core_node_ids[local_id]):
			sources.append(local_id)
	if sources.is_empty():
		return {}
	var enabled := PackedByteArray()
	var costs := PackedFloat32Array()
	enabled.resize(layout.edges.size())
	for edge_id in range(layout.edges.size()):
		enabled[edge_id] = 1 if layout.classes[edge_id] == Roads.LOCAL and layout.phases[edge_id] <= plan.completed_phase and not layout.closed_edges.has(edge_id) else 0
		costs.append(layout.lengths[edge_id])
	return Paths.tree(Paths.adjacency(layout.nodes.size(), layout.edges, enabled), costs, sources)


static func _seam_street_nodes(layout, tree: Dictionary, seam: PackedVector2Array) -> Array[int]:
	var result: Array[int] = []
	for node_id in range(layout.nodes.size()):
		if tree["distances"][node_id] > 1.5:
			continue
		var point: Vector2 = layout.nodes[node_id]
		for boundary_point in seam:
			if point.distance_to(boundary_point) < 0.24:
				result.append(node_id)
				break
	return result


static func _install_local_access(region, neighborhood, tree: Dictionary, local_id: int) -> int:
	var layout = neighborhood.street_layout
	var plan = neighborhood.development_plan
	var path: Array[Vector2i] = Paths.path(tree, local_id, layout.edges)
	for step in path:
		var edge: Vector2 = layout.edges[step.x]
		var first_local: int = int(edge.x)
		var last_local: int = int(edge.y)
		var first_global: int = plan.core_node_ids.get(first_local, -1)
		if first_global < 0:
			first_global = ensure_node(region, layout.nodes[first_local], neighborhood.city_id)
		var last_global: int = plan.core_node_ids.get(last_local, -1)
		if last_global < 0:
			last_global = ensure_node(region, layout.nodes[last_local], neighborhood.city_id)
		_append_seam_link(region, first_global, last_global, Roads.LOCAL, neighborhood)
	var global_id: int = plan.core_node_ids.get(local_id, -1)
	if global_id < 0:
		global_id = ensure_node(region, layout.nodes[local_id], neighborhood.city_id)
		plan.core_node_ids[local_id] = global_id
	if not neighborhood.access_node_ids.has(global_id):
		neighborhood.access_node_ids.append(global_id)
		if not region.road_nodes[global_id].is_interchange and region.road_nodes[global_id].kind != "City":
			region.road_nodes[global_id].managed_neighborhood_id = neighborhood.id
	return global_id


static func _append_seam_link(region, first: int, last: int, road_class: String, neighborhood) -> void:
	if first == last or Spatial.cache(region)["pairs"].has(Spatial.pair_key(first, last, road_class)):
		return
	var link = Roads.new()
	link.id = region.next_road_link_id
	region.next_road_link_id += 1
	link.from_node_id = first
	link.to_node_id = last
	link.road_class = road_class
	link.points = PackedVector2Array([region.road_nodes[first].position_km, region.road_nodes[last].position_km])
	link.owner_jurisdiction_id = region.city_jurisdiction_ids[neighborhood.city_id]
	link.managed_neighborhood_id = neighborhood.id
	link.lanes_per_direction = ceili(neighborhood.development_plan.installed_multiplier)
	link.recalculate_length()
	region.road_links.append(link)


static func _shared_boundary_samples(first: PackedVector2Array, second: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(first.size()):
		var start: Vector2 = first[index]
		var end: Vector2 = first[(index + 1) % first.size()]
		if start.distance_to(end) < 0.04:
			continue
		for fraction in [0.25, 0.5, 0.75]:
			var point: Vector2 = start.lerp(end, fraction)
			for other_index in range(second.size()):
				if point.distance_to(Geometry2D.get_closest_point_to_segment(point, second[other_index], second[(other_index + 1) % second.size()])) < 0.005:
					points.append(point)
					break
	return points


static func _crosses_arterial(region, first: Vector2, last: Vector2) -> bool:
	var nearby: Dictionary = {}
	for fraction in [0.0, 0.5, 1.0]:
		for link_index in Spatial.near_links(region, first.lerp(last, fraction)):
			nearby[link_index] = true
	for link_index in nearby:
		var link = region.road_links[link_index]
		if link.road_class != Roads.ARTERIAL:
			continue
		for segment in range(1, link.points.size()):
			if Geometry2D.segment_intersects_segment(first, last, link.points[segment - 1], link.points[segment]) != null:
				return true
	return false


static func _connector_crosses_blocks(layout, first: Vector2, last: Vector2) -> bool:
	for block in layout.blocks:
		if block.get("demolished", false):
			continue
		var polygon: PackedVector2Array = block["polygon"]
		for fraction in [0.2, 0.4, 0.6, 0.8]:
			var point: Vector2 = first.lerp(last, fraction)
			if Geography.segment_on_land(polygon, point, point) and not _near_polygon_edge(polygon, point):
				return true
	return false


static func _near_polygon_edge(polygon: PackedVector2Array, point: Vector2) -> bool:
	for index in range(polygon.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])) < 0.012:
			return true
	return false


static func _covered_by_collectors(region, points: PackedVector2Array) -> int:
	if points.size() < 2:
		return -1
	var first_link_id := -1
	for segment in range(1, points.size()):
		var first: Vector2 = points[segment - 1]
		var last: Vector2 = points[segment]
		var samples: int = maxi(1, ceili(first.distance_to(last) / 0.04))
		for sample_index in range(samples + 1):
			var point: Vector2 = first.lerp(last, float(sample_index) / float(samples))
			var covering_id := -1
			for link_index in Spatial.near_links(region, point):
				var link = region.road_links[link_index]
				if link.road_class == Roads.COLLECTOR and Planner.closest_point(link.points, point).distance_to(point) < 0.0015:
					covering_id = link.id
					break
			if covering_id < 0:
				return -1
			if first_link_id < 0:
				first_link_id = covering_id
	return first_link_id


static func _uncovered_collector_runs(region, points: PackedVector2Array) -> Array[PackedVector2Array]:
	var runs: Array[PackedVector2Array] = []
	var active := PackedVector2Array()
	for segment in range(1, points.size()):
		var segment_start: Vector2 = points[segment - 1]
		var segment_end: Vector2 = points[segment]
		var direction: Vector2 = segment_end - segment_start
		var squared_length: float = direction.length_squared()
		if squared_length < 0.00000001:
			continue
		var nearby: Dictionary = {}
		for sample in [segment_start, (segment_start + segment_end) * 0.5, segment_end]:
			for link_index in Spatial.near_links(region, sample):
				nearby[link_index] = true
		var cuts: Array[Dictionary] = [{"t": 0.0, "point": segment_start}, {"t": 1.0, "point": segment_end}]
		for link_index in nearby:
			var link = region.road_links[link_index]
			if link.road_class != Roads.COLLECTOR:
				continue
			for vertex in link.points:
				var along: float = (vertex - segment_start).dot(direction) / squared_length
				if along <= 0.01 or along >= 0.99 or vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, segment_start, segment_end)) >= 0.002:
					continue
				cuts.append({"t": along, "point": vertex})
		cuts.sort_custom(func(first_cut: Dictionary, second_cut: Dictionary) -> bool: return float(first_cut["t"]) < float(second_cut["t"]))
		for cut_index in range(1, cuts.size()):
			var first: Vector2 = cuts[cut_index - 1]["point"]
			var last: Vector2 = cuts[cut_index]["point"]
			if first.distance_to(last) < 0.0005:
				continue
			var middle: Vector2 = (first + last) * 0.5
			var covered := false
			for link_index in nearby:
				var link = region.road_links[link_index]
				if link.road_class == Roads.COLLECTOR and Planner.closest_point(link.points, first).distance_to(first) < 0.0015 and Planner.closest_point(link.points, middle).distance_to(middle) < 0.0015 and Planner.closest_point(link.points, last).distance_to(last) < 0.0015:
					covered = true
					break
			if covered:
				if active.size() >= 2:
					runs.append(active)
				active = PackedVector2Array()
				continue
			if active.is_empty():
				active.append(first)
			active.append(last)
	if active.size() >= 2:
		runs.append(active)
	return runs


static func _clean_path(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		if result.is_empty() or result[-1].distance_to(point) >= 0.0005:
			result.append(point)
	return result
