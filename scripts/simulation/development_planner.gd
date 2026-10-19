extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const Budget = preload("res://scripts/simulation/development_budget.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const ArterialAreas = preload("res://scripts/simulation/arterial_areas.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const CELL_SIZE_KM = LayoutGenerator.FRONTAGE_KM
const CELL_OVERLAP_KM = 0.18
const THROUGH_CANDIDATE_PERCENT = 14
const CORE_ZONING_RADIUS_KM = 3.5
const MIN_SHARED_EDGE_KM = 0.04
const MIN_CANDIDATE_HALF_WIDTH_KM = 0.13
const MIN_NARROW_PART_AREA_SHARE = 0.12


static func refresh_candidates(region) -> void:
	var chosen_styles: Dictionary = {}
	var chosen_characters: Dictionary = {}
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and candidate["layout"].interior_style == "Organic":
			chosen_styles[candidate["key"]] = "Organic"
		if int(candidate["neighborhood_id"]) < 0 and candidate.get("character_override", Character.AUTO) != Character.AUTO:
			chosen_characters[candidate["key"]] = candidate["character_override"]
	region.development_candidates.clear()
	region.development_candidate_keys.clear()
	region.development_candidate_cells.clear()
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var corridors: Dictionary = {}
	var claimed: Dictionary = {}
	var established: Dictionary = {}
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		if not claimed.has(neighborhood.city_id):
			claimed[neighborhood.city_id] = []
			established[neighborhood.city_id] = []
		claimed[neighborhood.city_id].append(neighborhood.street_layout.polygon)
		if neighborhood.development_approved:
			established[neighborhood.city_id].append(neighborhood.street_layout.polygon)
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		var corridor_id: int = link.corridor_id if link.corridor_id >= 0 else link.id
		if not corridors.has(corridor_id):
			corridors[corridor_id] = []
		corridors[corridor_id].append(link)
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		var layout = neighborhood.street_layout
		var frontage_id := -1
		for link_index in Spatial.near_links(region, layout.nodes[layout.arterial_nodes[0]]):
			var link = region.road_links[link_index]
			if link.road_class == Roads.ARTERIAL and rooted[link.from_node_id] != 0 and rooted[link.to_node_id] != 0 and RoadPlanner.closest_point(link.points, layout.nodes[layout.arterial_nodes[0]]).distance_to(layout.nodes[layout.arterial_nodes[0]]) < 0.02:
				frontage_id = link.id
				break
		_register_candidate(region, layout, neighborhood.id, frontage_id)
	for face in ArterialAreas.bounded_faces(region, rooted):
		var polygon: PackedVector2Array = face["polygon"]
		var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(polygon)
		if triangles.size() < 3:
			continue
		var inside: Vector2 = (polygon[triangles[0]] + polygon[triangles[1]] + polygon[triangles[2]]) / 3.0
		var city_id: int = region.city_id_at_point(inside)
		if city_id < 0 or _overlaps_claimed(polygon, claimed.get(city_id, [])):
			continue
		if not _can_expand_to(region, city_id, polygon, established.get(city_id, [])):
			continue
		var city_polygon: PackedVector2Array = region.jurisdictions[region.city_jurisdiction_ids[city_id]].polygon_km
		var contained_area := 0.0
		for piece in Geometry2D.intersect_polygons(polygon, city_polygon):
			contained_area += Geography.polygon_area(piece)
		if contained_area < Geography.polygon_area(polygon) * 0.999:
			continue
		var key: String = "%d:%s" % [city_id, face["key"]]
		var layout = LayoutGenerator.generate(region, city_id, face["boundaries"][0], key, [], true, face["boundaries"], PackedByteArray([1, 1, 1, 1]))
		if layout.polygon.size() < 3 or layout.arterial_nodes.size() < 2 or absf(Geography.polygon_area(layout.polygon) - Geography.polygon_area(polygon)) > 0.01:
			continue
		_register_candidate(region, layout, -1, face["links"][0], {"route": face["boundaries"][0], "edge_frontage": true, "boundaries": face["boundaries"], "arterial_sides": PackedByteArray([1, 1, 1, 1])})
		if not claimed.has(city_id):
			claimed[city_id] = []
		claimed[city_id].append(layout.polygon)
	var proposals: Array[Dictionary] = []
	var proposed_keys: Dictionary = {}
	# Tiny clipped cells cannot form a normal district. Revisit them after the
	# larger proposals exist so a shared edge can become one continuous zone.
	var small_remainders: Array[Dictionary] = []
	for corridor_id in corridors:
		var links: Array = corridors[corridor_id]
		links.sort_custom(func(first, second) -> bool: return first.corridor_start_km < second.corridor_start_km)
		var route := PackedVector2Array()
		var length := 0.0
		var start_station: float = links[0].corridor_start_km
		for link in links:
			if not route.is_empty() and route[-1].distance_to(link.points[0]) > 0.02:
				continue
			length += link.length_km
			route.append_array(link.points if route.is_empty() else link.points.slice(1))
		for slot in range(floori(start_station / CELL_SIZE_KM), ceili((start_station + length) / CELL_SIZE_KM)):
			var start: float = maxf(0.0, float(slot) * CELL_SIZE_KM - start_station)
			var finish: float = minf(length, float(slot + 1) * CELL_SIZE_KM - start_station)
			if finish - start < 0.6:
				continue
			var station: float = (start + finish) * 0.5
			var center: Vector2 = LayoutGenerator._along(route, station)
			var before: Vector2 = LayoutGenerator._along(route, maxf(0.0, station - 0.02))
			var after: Vector2 = LayoutGenerator._along(route, minf(length, station + 0.02))
			var tangent: Vector2 = (after - before).normalized()
			if tangent == Vector2.ZERO:
				continue
			var normal := Vector2(-tangent.y, tangent.x)
			var frontage_id := -1
			for link in links:
				if RoadPlanner.closest_point(link.points, center).distance_to(center) < 0.02:
					frontage_id = link.id
					break
			if frontage_id < 0:
				continue
			var local_route: PackedVector2Array = LayoutGenerator.frontage(route, maxf(0.0, station - CELL_SIZE_KM), minf(length, station + CELL_SIZE_KM))
			var through_city_id: int = region.city_id_at_point(center)
			if through_city_id >= 0:
				var through_key: String = "%d:%d:%d:through" % [through_city_id, corridor_id, slot]
				if center.distance_to(region.cities[through_city_id]["center_km"]) <= CORE_ZONING_RADIUS_KM and posmod(hash("%d:%s" % [region.generation_seed, through_key]), 100) < THROUGH_CANDIDATE_PERCENT and not proposed_keys.has(through_key):
					proposed_keys[through_key] = true
					var through_route: PackedVector2Array = LayoutGenerator.frontage(route, maxf(0.0, station - 1.0), minf(length, station + 1.0))
					proposals.append({"kind": "through", "key": through_key, "city_id": through_city_id, "route": through_route, "frontage_id": frontage_id, "priority": _near_existing_score(center, established.get(through_city_id, [])) + 0.5})
			for side in [1, -1]:
				var directed: PackedVector2Array = local_route.duplicate()
				if side < 0:
					directed.reverse()
				var corridor_outline: PackedVector2Array = LayoutGenerator.frontage_outline(directed)
				# A cell can touch the road strip without containing its center.
				# Sample across the full frontage depth and either side of the slot.
				for sample_shift in [-0.35, 0.35]:
					var sample_station: float = clampf(station + sample_shift, 0.0, length)
					var sample_center: Vector2 = LayoutGenerator._along(route, sample_station)
					var sample_before: Vector2 = LayoutGenerator._along(route, maxf(0.0, sample_station - 0.02))
					var sample_after: Vector2 = LayoutGenerator._along(route, minf(length, sample_station + 0.02))
					var sample_normal: Vector2 = (sample_after - sample_before).normalized().orthogonal()
					for offset in [0.2, 0.75, 1.3]:
						var sample: Vector2 = sample_center + sample_normal * float(side) * offset
						var city_id: int = region.city_id_at_point(sample)
						if city_id < 0:
							continue
						var grid: Vector2i = Geography.cell_grid_at_point(region.generation_seed, sample)
						var key: String = "%d:%d:%d:%d:%d" % [city_id, corridor_id, grid.x, grid.y, side]
						if region.development_candidate_keys.has(key) or proposed_keys.has(key):
							continue
						var cell: PackedVector2Array = Geography.cell_polygon(region, city_id, grid)
						# Overlap before clipping lets neighboring proposals meet without narrow unclaimed strips.
						var expanded: Array[PackedVector2Array] = Geometry2D.offset_polygon(cell, CELL_OVERLAP_KM, Geometry2D.JOIN_MITER)
						if expanded.size() == 1:
							var city_polygon: PackedVector2Array = region.jurisdictions[region.city_jurisdiction_ids[city_id]].polygon_km
							cell = _largest_intersection(expanded[0], city_polygon)
						var pieces: Array[PackedVector2Array] = Geometry2D.intersect_polygons(cell, corridor_outline)
						for piece_index in range(pieces.size()):
							var piece_key: String = key if pieces.size() == 1 else "%s:%d" % [key, piece_index]
							if proposed_keys.has(piece_key):
								continue
							var outline: PackedVector2Array = pieces[piece_index]
							var available: PackedVector2Array = _largest_available_piece(outline, established.get(city_id, []))
							if not _can_expand_to(region, city_id, available, established.get(city_id, [])):
								continue
							if available.size() < 3 or Geography.polygon_area(available) < 0.4:
								if Geography.polygon_area(available) >= 0.02:
									small_remainders.append({"city_id": city_id, "outline": outline, "key": piece_key, "route": directed, "frontage_id": frontage_id})
								continue
							proposed_keys[piece_key] = true
							proposals.append({"kind": "edge", "key": piece_key, "city_id": city_id, "route": directed, "corridor_origin": route[0], "frontage_id": frontage_id, "outline": outline, "priority": _adjacency_score(available, established.get(city_id, []))})
	proposals.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		if not is_equal_approx(float(first["priority"]), float(second["priority"])):
			return float(first["priority"]) > float(second["priority"])
		return String(first["key"]) < String(second["key"])
	)
	var candidate_claim_slots: Dictionary = {}
	for proposal in proposals:
		var city_id: int = proposal["city_id"]
		var key: String = proposal["key"]
		var layout
		var input: Dictionary
		if proposal["kind"] == "through":
			layout = LayoutGenerator.generate(region, city_id, proposal["route"], key, claimed.get(city_id, []))
			input = {"route": proposal["route"], "edge_frontage": false, "boundaries": [], "arterial_sides": PackedByteArray()}
		else:
			var available: PackedVector2Array = _largest_available_piece(proposal["outline"], claimed.get(city_id, []))
			if not _can_expand_to(region, city_id, available, established.get(city_id, [])):
				continue
			available = _trim_narrow_parts(available)
			if available.size() < 3 or Geography.polygon_area(available) < 0.4:
				if Geography.polygon_area(available) >= 0.02:
					small_remainders.append({"city_id": city_id, "outline": proposal["outline"], "key": key, "route": proposal["route"], "frontage_id": proposal["frontage_id"]})
				continue
			var grid_guide: Dictionary = _neighbor_grid_guide(region, available, city_id)
			if not grid_guide.has("axis"):
				grid_guide["axis"] = (proposal["route"][-1] - proposal["route"][0]).normalized()
				grid_guide["origin"] = proposal["corridor_origin"]
			layout = LayoutGenerator.generate(region, city_id, proposal["route"], key, [], true, [], PackedByteArray([1, 0, 0, 0]), "Grid", available, grid_guide)
			input = {"route": proposal["route"], "edge_frontage": true, "boundaries": [], "arterial_sides": PackedByteArray([1, 0, 0, 0]), "grid_guide": grid_guide}
		if layout.polygon.size() < 3:
			continue
		_register_candidate(region, layout, -1, int(proposal["frontage_id"]), input)
		if not claimed.has(city_id):
			claimed[city_id] = []
		claimed[city_id].append(layout.polygon)
		if proposal["kind"] == "edge":
			candidate_claim_slots[region.development_candidates.size() - 1] = claimed[city_id].size() - 1
	_resolve_small_remainders(region, small_remainders, claimed, established, candidate_claim_slots)
	_propagate_approved_grid_guides(region)
	_align_through_candidates(region)
	for key in chosen_styles:
		if region.development_candidate_keys.has(key):
			set_candidate_style(region, int(region.development_candidate_keys[key]), chosen_styles[key])
	for key in chosen_characters:
		if region.development_candidate_keys.has(key):
			set_candidate_character(region, int(region.development_candidate_keys[key]), chosen_characters[key])


static func _resolve_small_remainders(region, remainders: Array[Dictionary], claimed: Dictionary, established: Dictionary, claim_slots: Dictionary) -> void:
	for item in remainders:
		var city_id: int = item["city_id"]
		var piece: PackedVector2Array = _largest_available_piece(item["outline"], claimed.get(city_id, []))
		if not _can_expand_to(region, city_id, piece, established.get(city_id, [])):
			continue
		piece = _trim_narrow_parts(piece)
		var area: float = Geography.polygon_area(piece)
		if area < 0.02 or area >= 0.4:
			continue
		var bounds: Rect2 = Geography._bounds(piece)
		var best_id := -1
		var best_score := 0.05
		var best_outline := PackedVector2Array()
		for candidate_id in claim_slots:
			var candidate: Dictionary = region.development_candidates[candidate_id]
			if candidate["city_id"] != city_id or not candidate["layout"].bounds.grow(0.01).intersects(bounds):
				continue
			var score: float = _adjacency_score(piece, [candidate["polygon"]])
			if score <= best_score or _shared_boundary_on_arterial(region, piece, candidate["polygon"]):
				continue
			var joined: Array[PackedVector2Array] = Geometry2D.merge_polygons(candidate["polygon"], piece)
			if joined.size() != 1 or Geography.polygon_area(joined[0]) > 5.0 or absf(Geography.polygon_area(joined[0]) - Geography.polygon_area(candidate["polygon"]) - area) > 0.005:
				continue
			# A remainder must not restore a narrow neck that the width pass removed.
			if Geography.polygon_area(joined[0]) - Geography.polygon_area(_trim_narrow_parts(joined[0])) > 0.01:
				continue
			best_id = candidate_id
			best_score = score
			best_outline = joined[0]
		if best_id >= 0:
			var target: Dictionary = region.development_candidates[best_id]
			var input: Dictionary = target["layout_input"]
			var layout = LayoutGenerator.generate(region, city_id, input["route"], target["key"], [], true, [], input["arterial_sides"], target["layout"].interior_style, best_outline, input.get("grid_guide", {}))
			if layout.polygon.size() >= 3 and not layout.core_paths.is_empty() and absf(Geography.polygon_area(layout.polygon) - Geography.polygon_area(best_outline)) <= 0.005:
				target["polygon"] = layout.polygon
				target["layout"] = layout
				region.development_candidates[best_id] = target
				var city_claims: Array = claimed[city_id]
				city_claims[claim_slots[best_id]] = layout.polygon
				claimed[city_id] = city_claims
				continue
		# Keep a separate small plan only when it has usable arterial frontage.
		if area < 0.18 or region.development_candidate_keys.has(item["key"]):
			continue
		var small_input := {"route": item["route"], "edge_frontage": true, "boundaries": [], "arterial_sides": PackedByteArray([1, 0, 0, 0])}
		small_input["grid_guide"] = _neighbor_grid_guide(region, piece, city_id)
		var small_layout = LayoutGenerator.generate(region, city_id, item["route"], item["key"], [], true, [], small_input["arterial_sides"], "Grid", piece, small_input["grid_guide"])
		if small_layout.polygon.size() < 3 or small_layout.arterial_nodes.is_empty() or small_layout.core_paths.is_empty() or small_layout.blocks.is_empty():
			continue
		_register_candidate(region, small_layout, -1, item["frontage_id"], small_input)
		if not claimed.has(city_id):
			claimed[city_id] = []
		var city_claims: Array = claimed[city_id]
		city_claims.append(small_layout.polygon)
		claim_slots[region.development_candidates.size() - 1] = city_claims.size() - 1
		claimed[city_id] = city_claims


static func _propagate_approved_grid_guides(region) -> void:
	var anchored: Dictionary = {}
	for candidate in region.development_candidates:
		var neighborhood_id: int = int(candidate["neighborhood_id"])
		if neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_approved:
			anchored[candidate["key"]] = true
	if anchored.is_empty():
		return
	for pass_index in range(4):
		var added := 0
		for candidate_id in range(region.development_candidates.size()):
			var candidate: Dictionary = region.development_candidates[candidate_id]
			if anchored.has(candidate["key"]) or int(candidate["neighborhood_id"]) >= 0:
				continue
			var input: Dictionary = candidate["layout_input"]
			if not input.get("edge_frontage", false) or not input.get("boundaries", []).is_empty() or candidate["layout"].interior_style != "Grid":
				continue
			var guide: Dictionary = _neighbor_grid_guide(region, candidate["polygon"], int(candidate["city_id"]), String(candidate["key"]), anchored)
			if not guide.has("source_key"):
				continue
			var layout = LayoutGenerator.generate(region, int(candidate["city_id"]), input["route"], candidate["key"], [], true, [], input["arterial_sides"], "Grid", candidate["polygon"], guide)
			if layout.polygon.size() < 3 or layout.core_paths.is_empty() or absf(Geography.polygon_area(layout.polygon) - Geography.polygon_area(candidate["polygon"])) > 0.005:
				continue
			candidate["layout"] = layout
			input["grid_guide"] = guide
			candidate["layout_input"] = input
			region.development_candidates[candidate_id] = candidate
			anchored[candidate["key"]] = true
			added += 1
		if added == 0:
			break


static func _align_through_candidates(region) -> void:
	for candidate_id in range(region.development_candidates.size()):
		var candidate: Dictionary = region.development_candidates[candidate_id]
		if int(candidate["neighborhood_id"]) >= 0 or not String(candidate["key"]).ends_with(":through") or candidate["layout"].interior_style != "Grid":
			continue
		var guide: Dictionary = _neighbor_grid_guide(region, candidate["polygon"], int(candidate["city_id"]), String(candidate["key"]))
		if not guide.has("source_key"):
			continue
		var input: Dictionary = candidate["layout_input"]
		var layout = LayoutGenerator.generate(region, int(candidate["city_id"]), input["route"], candidate["key"], [], false, [], PackedByteArray(), "Grid", candidate["polygon"], guide)
		if layout.polygon.size() < 3 or layout.core_paths.is_empty() or absf(Geography.polygon_area(layout.polygon) - Geography.polygon_area(candidate["polygon"])) > 0.005:
			continue
		candidate["layout"] = layout
		input["grid_guide"] = guide
		candidate["layout_input"] = input
		region.development_candidates[candidate_id] = candidate


static func _shared_boundary_on_arterial(region, first: PackedVector2Array, second: PackedVector2Array) -> bool:
	var shared := 0.0
	var arterial := 0.0
	for index in range(first.size()):
		var start: Vector2 = first[index]
		var finish: Vector2 = first[(index + 1) % first.size()]
		var edge: Vector2 = finish - start
		var length: float = edge.length()
		if length < 0.001:
			continue
		var direction: Vector2 = edge / length
		for other_index in range(second.size()):
			var other_start: Vector2 = second[other_index]
			var other_finish: Vector2 = second[(other_index + 1) % second.size()]
			var other_edge: Vector2 = other_finish - other_start
			if other_edge.length() < 0.001 or absf(direction.dot(other_edge.normalized())) < 0.995:
				continue
			if absf(direction.cross(other_start - start)) > 0.006 or absf(direction.cross(other_finish - start)) > 0.006:
				continue
			var low: float = maxf(0.0, minf((other_start - start).dot(direction), (other_finish - start).dot(direction)))
			var high: float = minf(length, maxf((other_start - start).dot(direction), (other_finish - start).dot(direction)))
			var overlap: float = maxf(0.0, high - low)
			if overlap < 0.005:
				continue
			shared += overlap
			var middle: Vector2 = start + direction * ((low + high) * 0.5)
			for link_index in Spatial.near_links(region, middle):
				var link = region.road_links[link_index]
				if link.road_class == Roads.ARTERIAL and RoadPlanner.closest_point(link.points, middle).distance_to(middle) < 0.015:
					arterial += overlap
					break
	return shared > 0.0 and arterial > shared * 0.25


static func _overlaps_claimed(polygon: PackedVector2Array, claimed: Array) -> bool:
	for other in claimed:
		for piece in Geometry2D.intersect_polygons(polygon, other):
			if Geography.polygon_area(piece) > 0.001:
				return true
	return false


static func _largest_available_piece(polygon: PackedVector2Array, exclusions: Array) -> PackedVector2Array:
	var pieces: Array[PackedVector2Array] = [polygon]
	for exclusion in exclusions:
		var remaining: Array[PackedVector2Array] = []
		for piece in pieces:
			if Geometry2D.intersect_polygons(piece, exclusion).is_empty():
				remaining.append(piece)
			else:
				remaining.append_array(Geometry2D.clip_polygons(piece, exclusion))
		pieces = remaining
		if pieces.is_empty():
			return PackedVector2Array()
	var best := PackedVector2Array()
	var largest := 0.0
	for piece in pieces:
		var area: float = Geography.polygon_area(piece)
		if area > largest:
			best = piece
			largest = area
	return best


static func _trim_narrow_parts(polygon: PackedVector2Array) -> PackedVector2Array:
	if polygon.size() < 3:
		return PackedVector2Array()
	# Keep land that can hold a core at least two radii wide. Re-expanding
	# preserves the useful outer boundary while dropping thin peninsulas and
	# narrow connections between otherwise separate pieces.
	var largest := 0.0
	var best := PackedVector2Array()
	for core in Geometry2D.offset_polygon(polygon, -MIN_CANDIDATE_HALF_WIDTH_KM, Geometry2D.JOIN_MITER):
		for expanded in Geometry2D.offset_polygon(core, MIN_CANDIDATE_HALF_WIDTH_KM, Geometry2D.JOIN_MITER):
			for clipped in Geometry2D.intersect_polygons(expanded, polygon):
				var clean: PackedVector2Array = LayoutGenerator._clean_polygon(clipped)
				var area: float = Geography.polygon_area(clean)
				if area > largest:
					best = clean
					largest = area
	# Tiny tapered corners are useful for closing gaps along curved roads.
	# Keep them unless the removed part is substantial or extends far from
	# the usable core, as a long thin tail can be small by area.
	var reach := INF
	if best.size() >= 3:
		var original_bounds: Rect2 = Geography._bounds(polygon)
		var core_bounds: Rect2 = Geography._bounds(best)
		reach = maxf(maxf(absf(original_bounds.position.x - core_bounds.position.x), absf(original_bounds.end.x - core_bounds.end.x)), maxf(absf(original_bounds.position.y - core_bounds.position.y), absf(original_bounds.end.y - core_bounds.end.y)))
	if Geography.polygon_area(polygon) - largest < 0.005 or (Geography.polygon_area(polygon) - largest < Geography.polygon_area(polygon) * MIN_NARROW_PART_AREA_SHARE and reach < 0.5):
		return polygon
	return best


static func _largest_intersection(first: PackedVector2Array, second: PackedVector2Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var largest := 0.0
	for piece in Geometry2D.intersect_polygons(first, second):
		var area: float = Geography.polygon_area(piece)
		if area > largest:
			best = piece
			largest = area
	return best


static func _near_existing_score(point: Vector2, polygons: Array) -> float:
	var distance := INF
	for polygon in polygons:
		for index in range(polygon.size()):
			distance = minf(distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])))
	return -distance if distance < INF else -1000.0


static func _adjacency_score(polygon: PackedVector2Array, established: Array) -> float:
	var shared: float = _shared_edge_length_with_any(polygon, established)
	if shared >= MIN_SHARED_EDGE_KM:
		return 1000.0 + shared * 10.0
	var nearest := INF
	for other in established:
		for index in range(polygon.size()):
			var first: Vector2 = polygon[index]
			var last: Vector2 = polygon[(index + 1) % polygon.size()]
			var middle: Vector2 = (first + last) * 0.5
			for other_index in range(other.size()):
				var distance: float = middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, other[other_index], other[(other_index + 1) % other.size()]))
				nearest = minf(nearest, distance)
	return -nearest if nearest < INF else -1000.0


static func _shared_edge_length(first: PackedVector2Array, second: PackedVector2Array) -> float:
	var shared := 0.0
	for first_index in range(first.size()):
		var start: Vector2 = first[first_index]
		var finish: Vector2 = first[(first_index + 1) % first.size()]
		var edge: Vector2 = finish - start
		var length: float = edge.length()
		if length < 0.001:
			continue
		var direction: Vector2 = edge / length
		for second_index in range(second.size()):
			var other_start: Vector2 = second[second_index]
			var other_finish: Vector2 = second[(second_index + 1) % second.size()]
			var other_edge: Vector2 = other_finish - other_start
			if other_edge.length() < 0.001 or absf(direction.dot(other_edge.normalized())) < 0.995:
				continue
			if absf(direction.cross(other_start - start)) > 0.006 or absf(direction.cross(other_finish - start)) > 0.006:
				continue
			var low: float = maxf(0.0, minf((other_start - start).dot(direction), (other_finish - start).dot(direction)))
			var high: float = minf(length, maxf((other_start - start).dot(direction), (other_finish - start).dot(direction)))
			shared += maxf(0.0, high - low)
	return shared


static func _can_expand_to(region, city_id: int, polygon: PackedVector2Array, established: Array) -> bool:
	if polygon.size() < 3:
		return false
	var center: Vector2 = region.cities[city_id]["center_km"]
	if Jurisdiction.polygon_contains_point(center, polygon):
		return true
	for index in range(polygon.size()):
		if center.distance_to(Geometry2D.get_closest_point_to_segment(center, polygon[index], polygon[(index + 1) % polygon.size()])) <= CORE_ZONING_RADIUS_KM:
			return true
	if _shared_edge_length_with_any(polygon, established) >= MIN_SHARED_EDGE_KM:
		return true
	# A tiny seam between the clipped polygons should not strand a district.
	for other in established:
		if Geography._bounds(polygon).grow(0.12).intersects(Geography._bounds(other)) and _outline_distance(polygon, other) <= 0.12:
			return true
	return false


static func _shared_edge_length_with_any(polygon: PackedVector2Array, others: Array) -> float:
	var shared := 0.0
	var bounds: Rect2 = Geography._bounds(polygon).grow(0.01)
	for other in others:
		if bounds.intersects(Geography._bounds(other)):
			shared += _shared_edge_length(polygon, other)
	return shared


static func _outline_distance(first: PackedVector2Array, second: PackedVector2Array) -> float:
	var nearest := INF
	for vertex in first:
		for index in range(second.size()):
			nearest = minf(nearest, vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, second[index], second[(index + 1) % second.size()])))
	for vertex in second:
		for index in range(first.size()):
			nearest = minf(nearest, vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, first[index], first[(index + 1) % first.size()])))
	return nearest


static func _neighbor_grid_guide(region, polygon: PackedVector2Array, city_id: int, exclude_key: String = "", allowed_sources: Dictionary = {}) -> Dictionary:
	var best_score := 0.0
	var best: Dictionary = {}
	var seam_targets: Array[Dictionary] = []
	if city_id < 0 or city_id >= region.cities.size():
		return best
	var bounds: Rect2 = Geography._bounds(polygon)
	for candidate in region.development_candidates:
		if int(candidate["city_id"]) != city_id or candidate["key"] == exclude_key or (not allowed_sources.is_empty() and not allowed_sources.has(candidate["key"])):
			continue
		var neighborhood_id: int = int(candidate["neighborhood_id"])
		if neighborhood_id >= 0 and not region.neighborhoods[neighborhood_id].development_approved:
			continue
		var layout = candidate["layout"]
		if not bounds.grow(0.02).intersects(layout.bounds):
			continue
		var shared: float = _shared_edge_length(polygon, layout.polygon)
		if shared < MIN_SHARED_EDGE_KM or _shared_boundary_on_arterial(region, polygon, layout.polygon):
			continue
		_append_seam_targets(seam_targets, polygon, layout)
		if layout.interior_style != "Grid" or layout.grid_axis == Vector2.ZERO:
			continue
		var score: float = shared + (0.15 if neighborhood_id >= 0 else 0.0)
		if score <= best_score:
			continue
		best_score = score
		var collector_points := PackedVector2Array()
		var collector_directions := PackedVector2Array()
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.COLLECTOR:
				continue
			var pair: Vector2 = layout.edges[edge_id]
			var first: Vector2 = layout.nodes[int(pair.x)]
			var last: Vector2 = layout.nodes[int(pair.y)]
			collector_points.append((first + last) * 0.5)
			collector_directions.append((last - first).normalized())
		best = {"axis": layout.grid_axis, "origin": layout.grid_origin, "column_spacing": layout.grid_column_spacing_km, "row_spacing": layout.grid_row_spacing_km, "collector_points": collector_points, "collector_directions": collector_directions, "source_key": candidate["key"]}
	if not seam_targets.is_empty():
		best["seam_targets"] = seam_targets
	return best


static func _append_seam_targets(targets: Array[Dictionary], polygon: PackedVector2Array, layout) -> void:
	var bounds: Rect2 = Geography._bounds(polygon).grow(0.02)
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] not in [Roads.LOCAL, Roads.COLLECTOR]:
			continue
		var pair: Vector2 = layout.edges[edge_id]
		var first: Vector2 = layout.nodes[int(pair.x)]
		var last: Vector2 = layout.nodes[int(pair.y)]
		for reversed in [false, true]:
			var point: Vector2 = last if not reversed else first
			var interior: Vector2 = first if not reversed else last
			if not bounds.has_point(point) or _point_outline_distance(point, polygon) > 0.012 or _point_outline_distance(point, layout.polygon) > 0.012 or _point_outline_distance(interior, polygon) < 0.03:
				continue
			targets.append({"point": point, "direction": (point - interior).normalized(), "road_class": layout.classes[edge_id]})


static func _point_outline_distance(point: Vector2, polygon: PackedVector2Array) -> float:
	var nearest := INF
	for index in range(polygon.size()):
		nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])))
	return nearest


static func _register_candidate(region, layout, neighborhood_id: int, frontage_id: int, layout_input: Dictionary = {}) -> void:
	var area = Jurisdiction.new()
	area.polygon_km = layout.polygon
	Geography.update_bounds(area)
	if not Jurisdiction.polygon_contains_point(area.center_km, layout.polygon):
		var triangles: PackedInt32Array = Geometry2D.triangulate_polygon(layout.polygon)
		if triangles.size() >= 3:
			area.center_km = (layout.polygon[triangles[0]] + layout.polygon[triangles[1]] + layout.polygon[triangles[2]]) / 3.0
	var candidate_id: int = region.development_candidates.size()
	var grid: Vector2i = Geography.cell_grid_at_point(region.generation_seed, area.center_km)
	var character_profile: String
	if neighborhood_id >= 0:
		character_profile = region.neighborhoods[neighborhood_id].character_profile
	else:
		var defaults: Dictionary = RegionGenerator.zone_defaults(region, layout.city_id, grid)
		character_profile = Character.resolve(region, layout.city_id, area.center_km, layout.interior_style, defaults["shares"], defaults["density"])
	region.development_candidates.append({"id": candidate_id, "key": layout.key, "city_id": layout.city_id, "grid": grid, "polygon": layout.polygon, "center_km": area.center_km, "frontage_link_id": frontage_id, "neighborhood_id": neighborhood_id, "layout": layout, "layout_input": layout_input, "character_override": Character.AUTO, "character_profile": character_profile})
	region.development_candidate_keys[layout.key] = candidate_id
	var cell_key: String = "%d:%d" % [grid.x, grid.y]
	if not region.development_candidate_cells.has(cell_key):
		region.development_candidate_cells[cell_key] = []
	region.development_candidate_cells[cell_key].append(candidate_id)


static func set_candidate_style(region, candidate_id: int, style: String) -> bool:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size() or style not in ["Grid", "Organic"]:
		return false
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate["neighborhood_id"]) >= 0 or candidate.get("layout_input", {}).is_empty():
		return false
	if candidate["layout"].interior_style == style:
		return true
	var input: Dictionary = candidate["layout_input"]
	var layout = LayoutGenerator.generate(region, int(candidate["city_id"]), input["route"], candidate["key"], [], bool(input["edge_frontage"]), input["boundaries"], input["arterial_sides"], style, candidate["polygon"], input.get("grid_guide", {}))
	if layout.polygon.size() < 3 or layout.arterial_nodes.is_empty() or layout.core_paths.is_empty():
		return false
	candidate["layout"] = layout
	if candidate.get("character_override", Character.AUTO) == Character.AUTO:
		var defaults: Dictionary = RegionGenerator.zone_defaults(region, int(candidate["city_id"]), candidate["grid"])
		candidate["character_profile"] = Character.resolve(region, int(candidate["city_id"]), candidate["center_km"], style, defaults["shares"], defaults["density"])
	region.development_candidates[candidate_id] = candidate
	return true


static func set_candidate_character(region, candidate_id: int, profile: String) -> bool:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size() or (profile != Character.AUTO and not Character.PROFILES.has(profile)):
		return false
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if int(candidate["neighborhood_id"]) >= 0:
		return false
	var defaults: Dictionary = RegionGenerator.zone_defaults(region, int(candidate["city_id"]), candidate["grid"])
	candidate["character_override"] = profile
	candidate["character_profile"] = Character.resolve(region, int(candidate["city_id"]), candidate["center_km"], candidate["layout"].interior_style, defaults["shares"], defaults["density"], profile)
	region.development_candidates[candidate_id] = candidate
	return true


static func set_approval(region, candidate_id: int, approved: bool, allocation: int = -1, shares: Dictionary = {}, density: Dictionary = {}) -> Dictionary:
	if candidate_id < 0 or candidate_id >= region.development_candidates.size():
		return {"ok": false, "reason": "Select a neighborhood plan."}
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var neighborhood_id: int = candidate["neighborhood_id"]
	if approved and not shares.is_empty():
		var reason: String = Budget.validate_zoning(shares, density)
		if not reason.is_empty():
			return {"ok": false, "reason": reason}
	if not approved:
		if neighborhood_id < 0:
			return {"ok": false, "reason": "This land is not approved."}
		return Budget.cancel(region, neighborhood_id)
	var frontage_index: int = RoadGraph.link_index(region, int(candidate["frontage_link_id"]))
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	if frontage_index < 0 or region.road_links[frontage_index].road_class != Roads.ARTERIAL or rooted[region.road_links[frontage_index].from_node_id] == 0 or rooted[region.road_links[frontage_index].to_node_id] == 0:
		return {"ok": false, "reason": "Connect this arterial to an established city."}
	var city = region.jurisdictions[region.city_jurisdiction_ids[candidate["city_id"]]]
	var estimate: int = candidate["layout"].total_cost()
	if neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_plan != null:
		estimate = Budget.remaining_cost(region.neighborhoods[neighborhood_id])
		if allocation < 0:
			allocation = maxi(0, estimate - region.neighborhoods[neighborhood_id].development_plan.reserved)
	if allocation < 0:
		allocation = estimate
	if region.dev_mode:
		allocation = 0
	if not region.dev_mode and allocation > city.treasury:
		return {"ok": false, "reason": "Insufficient city funds. Allocate a smaller phased budget."}
	var new_neighborhood: bool = neighborhood_id < 0
	var neighborhood
	if new_neighborhood:
		neighborhood = RegionGenerator.append_neighborhood(region, candidate["city_id"], candidate["polygon"], candidate["grid"])
		_initialize_empty(neighborhood)
		var final_shares: Dictionary = shares if not shares.is_empty() else neighborhood.zone_shares
		var final_density: Dictionary = density if not density.is_empty() else neighborhood.zone_density
		neighborhood.character_profile = Character.resolve(region, neighborhood.city_id, candidate["center_km"], candidate["layout"].interior_style, final_shares, final_density, candidate.get("character_override", Character.AUTO))
		var gateway = RoadNodeData.new()
		gateway.id = region.road_nodes.size()
		gateway.city_id = neighborhood.city_id
		gateway.neighborhood_id = neighborhood.id
		gateway.kind = "Neighborhood"
		gateway.position_km = neighborhood.position_km
		region.road_nodes.append(gateway)
		region.neighborhood_gateway_node_ids.append(gateway.id)
		region.neighborhood_spoke_link_ids.append(-1)
		region.neighborhood_development_connected.append(0)
		region.neighborhood_accessible.append(0)
		region.accessibility.append(0.0)
		StreetNetwork.attach(region, neighborhood, candidate["layout"])
		RoadLand.apply_to_new_neighborhood(region, neighborhood)
		candidate["neighborhood_id"] = neighborhood.id
	else:
		neighborhood = region.neighborhoods[neighborhood_id]
		if neighborhood.street_layout == null:
			StreetNetwork.attach(region, neighborhood, candidate["layout"])
	neighborhood.development_approved = true
	if neighborhood.households == 0:
		neighborhood.development_state = "Developing"
	neighborhood.development_plan.active = true
	neighborhood.development_plan.reserved += allocation
	neighborhood.development_plan.status = "Approved"
	city.treasury -= allocation
	if not shares.is_empty():
		Budget.queue_zoning(region, neighborhood.id, shares, density, region.current_day_key)
	region.road_geometry_revision += 1
	return {"ok": true, "new_neighborhood": new_neighborhood, "allocated": allocation}


static func _initialize_empty(neighborhood) -> void:
	neighborhood.development_jobs_by_skill = neighborhood.jobs_by_skill.duplicate()
	neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
	neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
	neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
	neighborhood.baseline_occupancy = 0.75
	neighborhood.rent_level = float(neighborhood.monthly_rent)
	var weighted_income := 0.0
	for skill in neighborhood.jobs_by_skill:
		weighted_income += neighborhood.jobs_by_skill[skill] * {"Entry": 3000.0, "Skilled": 4300.0, "Professional": 6500.0}[skill]
	neighborhood.development_income = roundi(weighted_income / maxf(1.0, float(neighborhood.jobs)) * 1.1)
	neighborhood.households = 0
	neighborhood.population = 0
	neighborhood.jobs = 0
	neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
	neighborhood.shopping_attraction = 0.0
	neighborhood.monthly_rent = 0
	neighborhood.development_state = "Developing"
