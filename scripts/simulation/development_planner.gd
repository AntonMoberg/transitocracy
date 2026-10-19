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
				if posmod(hash("%d:%s" % [region.generation_seed, through_key]), 100) < THROUGH_CANDIDATE_PERCENT and not proposed_keys.has(through_key):
					proposed_keys[through_key] = true
					proposals.append({"kind": "through", "key": through_key, "city_id": through_city_id, "route": local_route, "frontage_id": frontage_id, "priority": _near_existing_score(center, established.get(through_city_id, [])) + 0.5})
			for side in [1, -1]:
				var directed: PackedVector2Array = local_route.duplicate()
				if side < 0:
					directed.reverse()
				var corridor_outline: PackedVector2Array = LayoutGenerator.frontage_outline(directed)
				for offset in [0.12, 0.48]:
					var sample: Vector2 = center + normal * float(side) * offset
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
					if pieces.size() != 1:
						continue
					var outline: PackedVector2Array = pieces[0]
					var available: PackedVector2Array = _largest_available_piece(outline, established.get(city_id, []))
					if available.size() < 3 or Geography.polygon_area(available) < 0.4:
						if Geography.polygon_area(available) >= 0.02:
							small_remainders.append({"city_id": city_id, "outline": outline, "key": key, "route": directed, "frontage_id": frontage_id})
						continue
					proposed_keys[key] = true
					proposals.append({"kind": "edge", "key": key, "city_id": city_id, "route": directed, "frontage_id": frontage_id, "outline": outline, "priority": _adjacency_score(available, established.get(city_id, []))})
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
			if available.size() < 3 or Geography.polygon_area(available) < 0.4:
				if Geography.polygon_area(available) >= 0.02:
					small_remainders.append({"city_id": city_id, "outline": proposal["outline"], "key": key, "route": proposal["route"], "frontage_id": proposal["frontage_id"]})
				continue
			available = _shape_open_corner(available, proposal["route"], claimed.get(city_id, []))
			layout = LayoutGenerator.generate(region, city_id, proposal["route"], key, [], true, [], PackedByteArray([1, 0, 0, 0]), "Grid", available)
			input = {"route": proposal["route"], "edge_frontage": true, "boundaries": [], "arterial_sides": PackedByteArray([1, 0, 0, 0])}
		if layout.polygon.size() < 3:
			continue
		_register_candidate(region, layout, -1, int(proposal["frontage_id"]), input)
		if not claimed.has(city_id):
			claimed[city_id] = []
		claimed[city_id].append(layout.polygon)
		if proposal["kind"] == "edge":
			candidate_claim_slots[region.development_candidates.size() - 1] = claimed[city_id].size() - 1
	_resolve_small_remainders(region, small_remainders, claimed, candidate_claim_slots)
	for key in chosen_styles:
		if region.development_candidate_keys.has(key):
			set_candidate_style(region, int(region.development_candidate_keys[key]), chosen_styles[key])
	for key in chosen_characters:
		if region.development_candidate_keys.has(key):
			set_candidate_character(region, int(region.development_candidate_keys[key]), chosen_characters[key])


static func _resolve_small_remainders(region, remainders: Array[Dictionary], claimed: Dictionary, claim_slots: Dictionary) -> void:
	for item in remainders:
		var city_id: int = item["city_id"]
		var piece: PackedVector2Array = _largest_available_piece(item["outline"], claimed.get(city_id, []))
		var area: float = Geography.polygon_area(piece)
		if area < 0.02 or area >= 0.4:
			continue
		var bounds: Rect2 = Geography._bounds(piece)
		var best_id := -1
		var best_score := 0.5
		var best_outline := PackedVector2Array()
		for candidate_id in claim_slots:
			var candidate: Dictionary = region.development_candidates[candidate_id]
			if candidate["city_id"] != city_id or not candidate["layout"].bounds.grow(0.01).intersects(bounds):
				continue
			var score: float = _adjacency_score(piece, [candidate["polygon"]])
			if score <= best_score or _shared_boundary_on_arterial(region, piece, candidate["polygon"]):
				continue
			var joined: Array[PackedVector2Array] = Geometry2D.merge_polygons(candidate["polygon"], piece)
			if joined.size() != 1 or Geography.polygon_area(joined[0]) > 4.0 or absf(Geography.polygon_area(joined[0]) - Geography.polygon_area(candidate["polygon"]) - area) > 0.005:
				continue
			best_id = candidate_id
			best_score = score
			best_outline = joined[0]
		if best_id >= 0:
			var target: Dictionary = region.development_candidates[best_id]
			var input: Dictionary = target["layout_input"]
			var layout = LayoutGenerator.generate(region, city_id, input["route"], target["key"], [], true, [], input["arterial_sides"], target["layout"].interior_style, best_outline)
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
		var small_layout = LayoutGenerator.generate(region, city_id, item["route"], item["key"], [], true, [], small_input["arterial_sides"], "Grid", piece)
		if small_layout.polygon.size() < 3 or small_layout.arterial_nodes.is_empty() or small_layout.core_paths.is_empty() or small_layout.blocks.is_empty():
			continue
		_register_candidate(region, small_layout, -1, item["frontage_id"], small_input)
		var city_claims: Array = claimed[city_id]
		city_claims.append(small_layout.polygon)
		claim_slots[region.development_candidates.size() - 1] = city_claims.size() - 1
		claimed[city_id] = city_claims


static func _shared_boundary_on_arterial(region, first: PackedVector2Array, second: PackedVector2Array) -> bool:
	var shared := 0.0
	var arterial := 0.0
	for index in range(first.size()):
		var start: Vector2 = first[index]
		var finish: Vector2 = first[(index + 1) % first.size()]
		var middle: Vector2 = (start + finish) * 0.5
		var touches := false
		for other_index in range(second.size()):
			if middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, second[other_index], second[(other_index + 1) % second.size()])) < 0.006:
				touches = true
				break
		if not touches:
			continue
		var length: float = start.distance_to(finish)
		shared += length
		for link_index in Spatial.near_links(region, middle):
			var link = region.road_links[link_index]
			if link.road_class == Roads.ARTERIAL and RoadPlanner.closest_point(link.points, middle).distance_to(middle) < 0.015:
				arterial += length
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


static func _shape_open_corner(polygon: PackedVector2Array, frontage: PackedVector2Array, neighbors: Array) -> PackedVector2Array:
	# An isolated four-sided Voronoi cell can exactly match a straight road's
	# frontage strip. Give its outer, unshared corner a short angled edge.
	var simple: PackedVector2Array = LayoutGenerator._clean_polygon(polygon)
	if simple.size() != 4:
		return polygon
	for index in range(4):
		var incoming: Vector2 = (simple[index] - simple[posmod(index - 1, 4)]).normalized()
		var outgoing: Vector2 = (simple[(index + 1) % 4] - simple[index]).normalized()
		if absf(incoming.dot(outgoing)) > 0.005:
			return polygon
	var corner := -1
	var best_distance := 0.08
	for index in range(4):
		var point: Vector2 = simple[index]
		var distance: float = point.distance_to(RoadPlanner.closest_point(frontage, point))
		if distance <= best_distance:
			continue
		var shared := false
		for neighbor in neighbors:
			for edge in range(neighbor.size()):
				if point.distance_to(Geometry2D.get_closest_point_to_segment(point, neighbor[edge], neighbor[(edge + 1) % neighbor.size()])) < 0.12:
					shared = true
					break
			if shared:
				break
		if not shared:
			corner = index
			best_distance = distance
	if corner < 0:
		return polygon
	var previous: Vector2 = simple[posmod(corner - 1, 4)]
	var vertex: Vector2 = simple[corner]
	var next: Vector2 = simple[(corner + 1) % 4]
	var inset: float = minf(0.11, minf(vertex.distance_to(previous), vertex.distance_to(next)) * 0.14)
	var shaped := PackedVector2Array()
	for index in range(4):
		if index == corner:
			shaped.append(vertex.move_toward(previous, inset))
			shaped.append(vertex.move_toward(next, inset))
		else:
			shaped.append(simple[index])
	return shaped


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
	var shared := 0.0
	var nearest := INF
	for other in established:
		for index in range(polygon.size()):
			var first: Vector2 = polygon[index]
			var last: Vector2 = polygon[(index + 1) % polygon.size()]
			var middle: Vector2 = (first + last) * 0.5
			for other_index in range(other.size()):
				var distance: float = middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, other[other_index], other[(other_index + 1) % other.size()]))
				nearest = minf(nearest, distance)
				if distance < 0.006:
					shared += first.distance_to(last)
					break
	return shared * 10.0 - nearest if nearest < INF else -1000.0


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
	var layout = LayoutGenerator.generate(region, int(candidate["city_id"]), input["route"], candidate["key"], [], bool(input["edge_frontage"]), input["boundaries"], input["arterial_sides"], style, candidate["polygon"])
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
