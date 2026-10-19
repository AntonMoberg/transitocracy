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
	var region = _region(PackedVector2Array([Vector2(1, 3), Vector2(16, 3)]), 18.0)
	Planner.refresh_candidates(region)
	if not _candidates_do_not_overlap(region):
		return
	var through := 0
	var edge := 0
	var first_through_id := -1
	for candidate in region.development_candidates:
		if candidate["key"].contains(":through"):
			through += 1
			if first_through_id < 0:
				first_through_id = candidate["id"]
			if candidate["layout_input"]["edge_frontage"]:
				_fail("A through-road candidate must place its arterial inside the district.")
				return
		else:
			edge += 1
	if through == 0 or edge <= through:
		_fail("Long open arterials should allow occasional through-road districts, with edge-frontage districts more common: %d through, %d edge." % [through, edge])
		return
	if not Planner.set_candidate_style(region, first_through_id, "Organic"):
		_fail("A through-road candidate should allow a different interior street style.")
		return
	var curved = _region(PackedVector2Array([Vector2(1, 3), Vector2(2.3, 3.13), Vector2(3.8, 3.25), Vector2(5.1, 3.14), Vector2(6.4, 3)]), 7.5)
	Planner.refresh_candidates(curved)
	if not _candidates_do_not_overlap(curved):
		return
	var follows_curve := false
	for candidate in curved.development_candidates:
		for vertex in candidate["polygon"]:
			if vertex.distance_to(Vector2(3.8, 3.25)) < 0.00001:
				follows_curve = true
	if not follows_curve:
		_fail("At least one new district boundary should retain a curved arterial's control point.")
		return
	var established = Neighborhood.new()
	established.id = 0
	established.city_id = 0
	var layout = Layout.new()
	layout.key = "existing"
	layout.city_id = 0
	layout.polygon = PackedVector2Array([Vector2(1.5, 3.7), Vector2(5.2, 3.7), Vector2(5.2, 4.3), Vector2(1.5, 4.3)])
	layout.bounds = Geography._bounds(layout.polygon)
	layout.nodes = PackedVector2Array([Vector2(1.5, 3)])
	layout.arterial_nodes = PackedInt32Array([0])
	established.street_layout = layout
	established.development_approved = true
	curved.neighborhoods.append(established)
	Planner.refresh_candidates(curved)
	if not _candidates_do_not_overlap(curved):
		return
	var first_new: Dictionary = {}
	for candidate in curved.development_candidates:
		if int(candidate["neighborhood_id"]) < 0:
			first_new = candidate
			break
	if first_new.is_empty() or Planner._adjacency_score(first_new["polygon"], [layout.polygon]) <= 0.0:
		_fail("The first new candidate should connect to the established district.")
		return
	var uncovered := 0
	var sampled := 0
	for y in [2.55, 3.52]:
		for step in range(49):
			var point := Vector2(1.2 + float(step) * 0.1, y)
			if Jurisdiction.polygon_contains_point(point, layout.polygon):
				continue
			sampled += 1
			var covered := false
			for candidate in curved.development_candidates:
				if int(candidate["neighborhood_id"]) < 0 and Jurisdiction.polygon_contains_point(point, candidate["polygon"]):
					covered = true
					break
			if not covered:
				uncovered += 1
	if uncovered > 0:
		_fail("Candidate outlines left %d gaps in %d samples beside the curved road and existing district." % [uncovered, sampled])
		return
	var least_block_coverage := 1.0
	var boundary_local_streets := 0
	for candidate in curved.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or not candidate["layout_input"]["edge_frontage"]:
			continue
		var blocks_area := 0.0
		for block in candidate["layout"].blocks:
			blocks_area += Geography.polygon_area(block["polygon"])
		least_block_coverage = minf(least_block_coverage, blocks_area / Geography.polygon_area(candidate["polygon"]))
		var street_layout = candidate["layout"]
		for edge_id in range(street_layout.edges.size()):
			if street_layout.classes[edge_id] != LinkData.LOCAL:
				continue
			var street_pair: Vector2 = street_layout.edges[edge_id]
			var endpoint: Vector2 = street_layout.nodes[int(street_pair.y)]
			for outline_edge in range(street_layout.polygon.size()):
				if endpoint.distance_to(Geometry2D.get_closest_point_to_segment(endpoint, street_layout.polygon[outline_edge], street_layout.polygon[(outline_edge + 1) % street_layout.polygon.size()])) < 0.001:
					boundary_local_streets += 1
					break
	if boundary_local_streets == 0 or least_block_coverage < 0.98:
		_fail("Irregular expansion districts need local streets and blocks reaching their outer edges.")
		return
	if not _check_remote_expansion():
		return
	print("Expansion candidates prioritize existing districts, preserve curved road edges, and occasionally contain an arterial (%d through, %d edge, %d uncovered samples, %.2f block coverage, %d boundary locals)." % [through, edge, uncovered, least_block_coverage, boundary_local_streets])
	quit(0)


func _check_remote_expansion() -> bool:
	var remote = _region(PackedVector2Array([Vector2(1, 3), Vector2(39, 3)]), 40.0)
	remote.cities[0]["center_km"] = Vector2(3, 3)
	Planner.refresh_candidates(remote)
	for candidate in remote.development_candidates:
		if candidate["center_km"].x > 12.0:
			_fail("An isolated stretch of arterial should not create remote zoning plans.")
			return false
	var existing = Neighborhood.new()
	existing.id = 0
	existing.city_id = 0
	var layout = Layout.new()
	layout.key = "remote-existing"
	layout.city_id = 0
	layout.polygon = PackedVector2Array([Vector2(23, 3.6), Vector2(25, 3.6), Vector2(25, 4.4), Vector2(23, 4.4)])
	layout.bounds = Geography._bounds(layout.polygon)
	layout.nodes = PackedVector2Array([Vector2(24, 3)])
	layout.arterial_nodes = PackedInt32Array([0])
	existing.street_layout = layout
	existing.development_approved = true
	remote.neighborhoods.append(existing)
	Planner.refresh_candidates(remote)
	var touching := 0
	for candidate in remote.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or candidate["center_km"].x < 12.0:
			continue
		if Planner._shared_edge_length(candidate["polygon"], layout.polygon) >= Planner.MIN_SHARED_EDGE_KM:
			touching += 1
		elif Planner._outline_distance(candidate["polygon"], layout.polygon) > 0.12:
			_fail("Remote zoning must adjoin developed land or fill a narrow seam beside it.")
			return false
	if touching == 0:
		_fail("An established remote neighborhood should allow expansion along a shared edge.")
		return false
	return true


func _region(points: PackedVector2Array, width: float):
	var region = Region.new()
	region.generation_seed = 1729
	var state = Jurisdiction.new()
	state.id = 0
	state.kind = "State"
	state.polygon_km = PackedVector2Array([Vector2(0, 0), Vector2(width, 0), Vector2(width, 7), Vector2(0, 7)])
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
	region.cities.append({"id": 0, "jurisdiction_id": 1, "neighborhood_ids": [], "density": 1, "center_km": Vector2(width * 0.5, 3.5)})
	region.starting_city_ids.append(0)
	region.city_hub_node_ids.append(0)
	for point in [points[0], points[-1]]:
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
	road.points = points
	road.recalculate_length()
	region.road_links.append(road)
	return region


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _candidates_do_not_overlap(region) -> bool:
	for first in range(region.development_candidates.size()):
		for second in range(first + 1, region.development_candidates.size()):
			var overlap := 0.0
			for piece in Geometry2D.intersect_polygons(region.development_candidates[first]["polygon"], region.development_candidates[second]["polygon"]):
				overlap += Geography.polygon_area(piece)
			if overlap > 0.001:
				_fail("Zoning candidates %d and %d overlap by %.3f km²." % [first, second, overlap])
				return false
	return true
