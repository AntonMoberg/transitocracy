extends RefCounted

const Geography = preload("res://scripts/simulation/state_geography.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")

const BRUSH_RADIUS_KM = 0.42
const ROAD_REACH_KM = 0.30
const MIN_AREA_KM2 = 0.12
const MAX_AREA_KM2 = 3.6


static func painted_polygon(stroke: PackedVector2Array) -> PackedVector2Array:
	if stroke.is_empty():
		return PackedVector2Array()
	if stroke.size() == 1:
		var circle := PackedVector2Array()
		for index in range(24):
			circle.append(stroke[0] + Vector2.RIGHT.rotated(TAU * float(index) / 24.0) * BRUSH_RADIUS_KM)
		return circle
	var pieces: Array[PackedVector2Array] = Geometry2D.offset_polyline(stroke, BRUSH_RADIUS_KM, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)
	return largest(pieces)


static func largest(polygons: Array[PackedVector2Array]) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_area := 0.0
	for polygon in polygons:
		var area: float = Geography.polygon_area(polygon)
		if area > best_area:
			best = polygon
			best_area = area
	return best


static func clip_to_city(region, city_id: int, polygon: PackedVector2Array) -> PackedVector2Array:
	if city_id < 0 or polygon.size() < 3:
		return PackedVector2Array()
	var city_polygon: PackedVector2Array = region.jurisdictions[region.city_jurisdiction_ids[city_id]].polygon_km
	var clipped: PackedVector2Array = largest(Geometry2D.intersect_polygons(polygon, city_polygon))
	for neighborhood in region.neighborhoods:
		if clipped.size() < 3:
			return clipped
		if neighborhood.city_id != city_id or neighborhood.street_layout == null:
			continue
		if not Geography._bounds(clipped).intersects(neighborhood.street_layout.bounds):
			continue
		clipped = largest(Geometry2D.clip_polygons(clipped, neighborhood.street_layout.polygon))
	return clipped


static func plan(region, city_id: int, polygon: PackedVector2Array, key: String, guide: Dictionary = {}, style: String = "Grid", exact_outline: bool = false) -> Dictionary:
	if polygon.size() < 3:
		return {}
	var buildable: PackedVector2Array
	if exact_outline:
		buildable = clip_to_city(region, city_id, polygon)
	else:
		# Legacy brush drafts need a short reach to find road access.
		var expanded: Array[PackedVector2Array] = Geometry2D.offset_polygon(polygon, ROAD_REACH_KM, Geometry2D.JOIN_ROUND)
		buildable = clip_to_city(region, city_id, largest(expanded))
	if buildable.size() < 3:
		return {}
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var best_route := PackedVector2Array()
	var best_link_id := -1
	var best_area := 0.0
	var best_retained := 0.0
	var buildable_bounds: Rect2 = Geography._bounds(buildable).grow(1.5)
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or rooted[link.from_node_id] == 0 or rooted[link.to_node_id] == 0:
			continue
		if not buildable_bounds.intersects(Geography._bounds(link.points)):
			continue
		for reversed in [false, true]:
			var route: PackedVector2Array = link.points.duplicate()
			if reversed:
				route.reverse()
			var frontage: PackedVector2Array = LayoutGenerator.frontage_outline(route)
			var outline: PackedVector2Array = largest(Geometry2D.intersect_polygons(buildable, frontage))
			var area: float = Geography.polygon_area(outline)
			if area <= 0.02:
				continue
			var retained: float = Geography.polygon_area(largest(Geometry2D.intersect_polygons(polygon, outline)))
			if retained > best_retained + 0.001 or (absf(retained - best_retained) <= 0.001 and area > best_area):
				best_area = area
				best_retained = retained
				best_route = route
				best_link_id = link.id
	if best_link_id < 0:
		return {}
	# The frontage strip identifies a road entrance, not the district boundary.
	# Pass the whole painted area to the layout generator so a broad stroke or
	# an angled boundary does not lose land outside the standard frontage depth.
	var edge_sides := PackedByteArray([1, 0, 0, 0])
	var layout = LayoutGenerator.generate(region, city_id, best_route, key, [], true, [], edge_sides, style, buildable, guide)
	var edge_frontage := true
	# A stroke can cross the arterial. A one-sided grid then shows lots on only
	# half of the district, so use a through grid when it covers more land.
	if _block_coverage(layout) < 0.85:
		var through_layout = LayoutGenerator.generate(region, city_id, best_route, key, [], false, [], PackedByteArray(), style, buildable, guide)
		if _block_coverage(through_layout) > _block_coverage(layout) + 0.05:
			layout = through_layout
			edge_frontage = false
	if not _valid_layout(layout):
		return {}
	return {"layout": layout, "frontage_id": best_link_id, "input": {"route": best_route, "edge_frontage": edge_frontage, "boundaries": [], "arterial_sides": edge_sides if edge_frontage else PackedByteArray(), "grid_guide": guide}}


static func _valid_layout(layout) -> bool:
	return layout.polygon.size() >= 3 and not layout.arterial_nodes.is_empty() and not layout.core_paths.is_empty() and not layout.blocks.is_empty()


static func _block_coverage(layout) -> float:
	if not _valid_layout(layout):
		return 0.0
	var area: float = Geography.polygon_area(layout.polygon)
	var covered := 0.0
	for block in layout.blocks:
		covered += Geography.polygon_area(block["polygon"])
	return covered / maxf(area, 0.001)


static func snap_anchor(region, city_id: int, point: Vector2, tolerance: float = 0.12, exclude_draft_id: int = -1, road_indices: Array[int] = [], restrict_roads: bool = false, previous_anchor: Dictionary = {}) -> Dictionary:
	var best: Dictionary = {"point": point}
	var distance: float = tolerance
	var nearby_paths: Array[Dictionary] = []
	var street_feature: Dictionary = {}
	if city_id < 0:
		return best
	var city_polygon: PackedVector2Array = region.jurisdictions[region.city_jurisdiction_ids[city_id]].polygon_km
	if Geography._bounds(city_polygon).grow(tolerance).has_point(point):
		nearby_paths.append({"path": city_polygon, "closed": true, "kind": "city", "index": city_id})
		best = _snap_to_path(point, city_polygon, true, "city", city_id, best, distance)
		if best.has("kind"):
			distance = point.distance_to(best["point"])
	for neighborhood_index in range(region.neighborhoods.size()):
		var neighborhood = region.neighborhoods[neighborhood_index]
		if neighborhood.city_id != city_id or neighborhood.street_layout == null or not neighborhood.street_layout.bounds.grow(tolerance).has_point(point):
			continue
		nearby_paths.append({"path": neighborhood.street_layout.polygon, "closed": true, "kind": "neighborhood", "index": neighborhood_index})
		best = _snap_to_path(point, neighborhood.street_layout.polygon, true, "neighborhood", neighborhood_index, best, distance)
		street_feature = _boundary_street_feature(point, tolerance, neighborhood.street_layout, neighborhood.street_layout.polygon, "neighborhood", neighborhood_index, previous_anchor, street_feature)
		if best.has("kind"):
			distance = point.distance_to(best["point"])
	for draft in region.growth_area_drafts:
		if int(draft["city_id"]) != city_id or int(draft["id"]) == exclude_draft_id or not Geography._bounds(draft["polygon"]).grow(tolerance).has_point(point):
			continue
		nearby_paths.append({"path": draft["polygon"], "closed": true, "kind": "draft", "index": int(draft["id"])})
		best = _snap_to_path(point, draft["polygon"], true, "draft", int(draft["id"]), best, distance)
		var candidate_id: int = int(region.development_candidate_keys.get("growth:%d" % int(draft["id"]), -1))
		if candidate_id >= 0 and candidate_id < region.development_candidates.size() and region.development_candidates[candidate_id].has("layout"):
			street_feature = _boundary_street_feature(point, tolerance, region.development_candidates[candidate_id]["layout"], draft["polygon"], "draft", int(draft["id"]), previous_anchor, street_feature)
		if best.has("kind"):
			distance = point.distance_to(best["point"])
	for link_index in (road_indices if restrict_roads else range(region.road_links.size())):
		var link = region.road_links[link_index]
		if link.road_class not in [Roads.ARTERIAL, Roads.HIGHWAY] or not Geography._bounds(link.points).grow(tolerance).has_point(point):
			continue
		nearby_paths.append({"path": link.points, "closed": false, "kind": "road", "index": link_index})
		best = _snap_to_path(point, link.points, false, "road", link_index, best, distance)
		if best.has("kind"):
			distance = point.distance_to(best["point"])
	var feature: Dictionary = _nearby_snap_feature(point, tolerance, nearby_paths, previous_anchor)
	if not street_feature.is_empty():
		feature = _choose_snap_feature(point, tolerance, feature, street_feature, previous_anchor)
	return feature if not feature.is_empty() else best


static func _boundary_street_feature(point: Vector2, tolerance: float, layout, boundary: PackedVector2Array, kind: String, index: int, previous_anchor: Dictionary, best: Dictionary) -> Dictionary:
	if boundary.size() < 3 or _point_outline_distance(point, boundary) > tolerance + 0.015:
		return best
	for edge_id in range(mini(layout.edges.size(), layout.classes.size())):
		if layout.classes[edge_id] not in [Roads.LOCAL, Roads.COLLECTOR] or layout.closed_edges.has(edge_id):
			continue
		var edge: Vector2 = layout.edges[edge_id]
		for node_id in [int(edge.x), int(edge.y)]:
			if node_id < 0 or node_id >= layout.nodes.size():
				continue
			var endpoint: Vector2 = layout.nodes[node_id]
			if point.distance_to(endpoint) > tolerance + 0.015:
				continue
			var anchor: Dictionary = _snap_to_path(endpoint, boundary, true, kind, index, {"point": endpoint}, 0.015)
			if not anchor.has("kind"):
				continue
			anchor["snap_point"] = true
			anchor["intersection"] = true
			anchor["street_class"] = layout.classes[edge_id]
			best = _choose_snap_feature(point, tolerance, best, anchor, previous_anchor)
	return best


static func _point_outline_distance(point: Vector2, polygon: PackedVector2Array) -> float:
	var nearest: float = INF
	for index in range(polygon.size()):
		nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])))
	return nearest


static func angle_snap_anchor(region, anchors: Array[Dictionary], point: Vector2) -> Dictionary:
	if anchors.is_empty():
		return {"point": point}
	var origin: Vector2 = anchors[-1]["point"]
	var delta: Vector2 = point - origin
	if delta.length_squared() < 0.000001:
		return {"point": point}
	var reference := Vector2.RIGHT
	var has_reference := false
	if anchors.size() >= 2:
		var prior_edge: PackedVector2Array = path_between(region, anchors[-2], anchors[-1])
		for index in range(prior_edge.size() - 1, 0, -1):
			var tangent: Vector2 = prior_edge[index] - prior_edge[index - 1]
			if tangent.length_squared() > 0.000001:
				reference = tangent.normalized()
				has_reference = true
				break
	elif anchors[-1].has("kind"):
		var path: PackedVector2Array = _anchor_path(region, anchors[-1])
		var segment: int = int(anchors[-1].get("segment", 0))
		if path.size() >= 2 and segment >= 0 and segment < path.size():
			var tangent: Vector2 = path[(segment + 1) % path.size()] - path[segment]
			if tangent.length_squared() > 0.000001:
				reference = tangent.normalized()
				has_reference = true
	var step: float = deg_to_rad(5.0)
	var angle: float = roundf(reference.angle_to(delta) / step) * step
	var direction: Vector2 = reference.rotated(angle)
	var label: String = "Bearing %d°" % (roundi(rad_to_deg(direction.angle()) / 5.0) * 5)
	if has_reference:
		var turn: int = roundi(rad_to_deg(angle))
		label = "%+d°" % turn if turn != 0 else "0°"
	return {"point": origin + direction * delta.length(), "angle_snapped": true, "angle_label": label, "angle_reference": reference, "has_reference": has_reference}


static func _nearby_snap_feature(point: Vector2, tolerance: float, paths: Array[Dictionary], previous_anchor: Dictionary) -> Dictionary:
	var segments: Array[Dictionary] = []
	var best: Dictionary = {}
	for source in paths:
		var path: PackedVector2Array = source["path"]
		var closed: bool = source["closed"]
		var count: int = path.size() if closed else path.size() - 1
		for segment in range(count):
			var first: Vector2 = path[segment]
			var last: Vector2 = path[(segment + 1) % path.size()]
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last)) > tolerance:
				continue
			var nearby: Dictionary = {"first": first, "last": last, "kind": source["kind"], "index": source["index"], "segment": segment}
			segments.append(nearby)
			if not closed and segment == 0:
				best = _choose_snap_feature(point, tolerance, best, _feature_on_segment(nearby, first, false), previous_anchor)
			if not closed and segment == count - 1:
				best = _choose_snap_feature(point, tolerance, best, _feature_on_segment(nearby, last, false), previous_anchor)
			if closed:
				var before: Vector2 = path[posmod(segment - 1, path.size())]
				var turn: float = absf((first - before).angle_to(last - first)) if before.distance_squared_to(first) > 0.000001 and first.distance_squared_to(last) > 0.000001 else 0.0
				if turn >= deg_to_rad(25.0):
					best = _choose_snap_feature(point, tolerance, best, _feature_on_segment(nearby, first, false), previous_anchor)
	for first_index in range(segments.size()):
		var first: Dictionary = segments[first_index]
		for second_index in range(first_index + 1, segments.size()):
			var second: Dictionary = segments[second_index]
			if first["kind"] == second["kind"] and first["index"] == second["index"]:
				continue
			var intersection: Variant = Geometry2D.segment_intersects_segment(first["first"], first["last"], second["first"], second["last"])
			if intersection == null or point.distance_to(intersection) > tolerance:
				continue
			var preferred: Dictionary = second if _same_snap_source(second, previous_anchor) and not _same_snap_source(first, previous_anchor) else first
			best = _choose_snap_feature(point, tolerance, best, _feature_on_segment(preferred, intersection, true), previous_anchor)
	return best


static func _feature_on_segment(segment: Dictionary, position: Vector2, intersection: bool) -> Dictionary:
	var start: Vector2 = segment["first"]
	var end: Vector2 = segment["last"]
	var progress: float = 0.0 if start == end else clampf((position - start).dot(end - start) / start.distance_squared_to(end), 0.0, 1.0)
	return {"point": position, "kind": segment["kind"], "index": segment["index"], "segment": segment["segment"], "progress": progress, "snap_point": true, "intersection": intersection}


static func _same_snap_source(first: Dictionary, second: Dictionary) -> bool:
	return not second.is_empty() and first.get("kind", "") == second.get("kind", "") and first.get("index", -1) == second.get("index", -2)


static func _choose_snap_feature(point: Vector2, tolerance: float, best: Dictionary, candidate: Dictionary, previous_anchor: Dictionary) -> Dictionary:
	var error: float = point.distance_to(candidate["point"])
	if error > tolerance:
		return best
	if best.is_empty():
		return candidate
	var best_error: float = point.distance_to(best["point"])
	if error < best_error - 0.005:
		return candidate
	if absf(error - best_error) <= 0.005 and _same_snap_source(candidate, previous_anchor) and not _same_snap_source(best, previous_anchor):
		return candidate
	if absf(error - best_error) <= 0.005 and candidate["intersection"] and not best["intersection"]:
		return candidate
	return best


static func _snap_to_path(point: Vector2, path: PackedVector2Array, closed: bool, kind: String, index: int, best: Dictionary, distance: float) -> Dictionary:
	if path.size() < 2:
		return best
	var segment_count: int = path.size() if closed else path.size() - 1
	for segment in range(segment_count):
		var first: Vector2 = path[segment]
		var last: Vector2 = path[(segment + 1) % path.size()]
		var snapped: Vector2 = Geometry2D.get_closest_point_to_segment(point, first, last)
		var error: float = point.distance_to(snapped)
		if error < distance:
			distance = error
			var progress: float = 0.0 if first == last else clampf((snapped - first).dot(last - first) / first.distance_squared_to(last), 0.0, 1.0)
			best = {"point": snapped, "kind": kind, "index": index, "segment": segment, "progress": progress}
	return best


static func _anchor_path(region, anchor: Dictionary) -> PackedVector2Array:
	match String(anchor.get("kind", "")):
		"city":
			return region.jurisdictions[region.city_jurisdiction_ids[int(anchor["index"])]].polygon_km
		"neighborhood":
			return region.neighborhoods[int(anchor["index"])].street_layout.polygon
		"draft":
			for draft in region.growth_area_drafts:
				if int(draft["id"]) == int(anchor["index"]):
					return draft["polygon"]
		"road":
			return region.road_links[int(anchor["index"])].points
	return PackedVector2Array()


static func path_between(region, first: Dictionary, last: Dictionary) -> PackedVector2Array:
	var direct := PackedVector2Array([first["point"], last["point"]])
	if not first.has("kind") or first.get("kind") != last.get("kind") or first.get("index") != last.get("index"):
		return direct
	var path: PackedVector2Array = _anchor_path(region, first)
	if path.size() < 2:
		return direct
	var closed: bool = first["kind"] != "road"
	var forward: PackedVector2Array = _walk_path(path, first, last, closed, true)
	if not closed:
		return forward if float(first["segment"]) + float(first["progress"]) <= float(last["segment"]) + float(last["progress"]) else _walk_path(path, first, last, false, false)
	var reverse: PackedVector2Array = _walk_path(path, first, last, true, false)
	return forward if _polyline_length(forward) <= _polyline_length(reverse) else reverse


static func _walk_path(path: PackedVector2Array, first: Dictionary, last: Dictionary, closed: bool, forward: bool) -> PackedVector2Array:
	var result := PackedVector2Array([first["point"]])
	var segment: int = first["segment"]
	var target: int = last["segment"]
	var same_segment: bool = segment == target
	var ordered: bool = float(first["progress"]) <= float(last["progress"]) if forward else float(first["progress"]) >= float(last["progress"])
	if same_segment and ordered:
		result.append(last["point"])
		return result
	var count: int = path.size() if closed else path.size() - 1
	for unused in range(count + 1):
		if forward:
			result.append(path[(segment + 1) % path.size()])
			segment = (segment + 1) % count
		else:
			result.append(path[segment])
			segment = posmod(segment - 1, count)
		if segment == target:
			break
	result.append(last["point"])
	return result


static func _polyline_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
	return length


static func outline_from_anchors(region, anchors: Array[Dictionary], close: bool = true) -> PackedVector2Array:
	var outline := PackedVector2Array()
	if anchors.is_empty():
		return outline
	if anchors.size() == 1:
		return PackedVector2Array([anchors[0]["point"]])
	var segment_count: int = anchors.size() if close else anchors.size() - 1
	for index in range(segment_count):
		var piece: PackedVector2Array = path_between(region, anchors[index], anchors[(index + 1) % anchors.size()])
		for point in piece:
			if outline.is_empty() or outline[-1].distance_to(point) > 0.0001:
				outline.append(point)
	if close and outline.size() > 1 and outline[-1].distance_to(outline[0]) <= 0.0001:
		outline.remove_at(outline.size() - 1)
	return outline


static func snap_vertex(region, city_id: int, point: Vector2, exclude_draft_id: int = -1) -> Vector2:
	return snap_anchor(region, city_id, point, 0.09, exclude_draft_id)["point"]
