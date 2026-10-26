extends RefCounted

const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const MIN_HIGHWAY_RADIUS_KM = 2.0
const HIGHWAY_TANGENT_STRAIGHT_KM = 0.1
const AUTO = "Auto"
const STRAIGHT = "Straight"
const CURVED = "Curved"
const MULTIPOINT = "Multi-point Curved"


static func build_player(region, first: Vector2, last: Vector2, road_class: String, anchors: PackedVector2Array, mode: String, start_tangent: Vector2 = Vector2.ZERO, end_tangent: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	if mode not in [STRAIGHT, CURVED, MULTIPOINT]:
		return PackedVector2Array()
	if mode == STRAIGHT and not anchors.is_empty():
		return PackedVector2Array()
	if mode == CURVED and anchors.size() != 1:
		return PackedVector2Array()
	if mode == MULTIPOINT and (anchors.is_empty() or anchors.size() % 2 == 0):
		return PackedVector2Array()
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	if mode == STRAIGHT:
		if first.distance_to(last)<0.1 or not StateGeography.segment_on_land(land,first,last): return PackedVector2Array()
		var chord:Vector2=(last-first).normalized()
		if (start_tangent==Vector2.ZERO or start_tangent.dot(chord)>.99999) and (end_tangent==Vector2.ZERO or end_tangent.dot(chord)>.99999): return PackedVector2Array([first,last])
		var reach:float=minf(first.distance_to(last)*.45,maxf(1.6,first.distance_to(last)*.2))
		var path:=PackedVector2Array([first])
		var lead:float=minf(.1,reach*.05)
		if start_tangent!=Vector2.ZERO:
			path.append(first+start_tangent*lead)
			var body:Vector2=first+chord*reach
			if not _sample_player_curve(land,path,path[-1],path[-1]+start_tangent*reach*.5,body-chord*reach*.5,body,0): return PackedVector2Array()
		if end_tangent!=Vector2.ZERO:
			var body:Vector2=last-chord*reach
			if path[-1].distance_to(body)>.000001: path.append(body)
			var finish:Vector2=last-end_tangent*lead
			if not _sample_player_curve(land,path,body,body+chord*reach*.5,finish-end_tangent*reach*.5,finish,0): return PackedVector2Array()
		path.append(last)
		return path
	if mode == MULTIPOINT:
		var route := PackedVector2Array([first])
		var curve_start: Vector2 = first
		var incoming_tangent: Vector2 = start_tangent
		for index in range(0, anchors.size(), 2):
			var curve_end: Vector2 = anchors[index + 1] if index + 1 < anchors.size() else last
			var curve_end_tangent: Vector2 = end_tangent if index + 1 == anchors.size() else Vector2.ZERO
			var segment: PackedVector2Array = build_player(region, curve_start, curve_end, road_class, PackedVector2Array([anchors[index]]), CURVED, incoming_tangent, curve_end_tangent)
			if segment.is_empty():
				return PackedVector2Array()
			for point_index in range(1, segment.size()):
				route.append(segment[point_index])
			incoming_tangent = (curve_end - anchors[index]).normalized()
			curve_start = curve_end
		return route
	if first.distance_to(last) < 0.1:
		return PackedVector2Array()
	var start: Vector2 = first
	var finish: Vector2 = last
	var result := PackedVector2Array([first])
	var lead: float = minf(HIGHWAY_TANGENT_STRAIGHT_KM, first.distance_to(last) * 0.1)
	if start_tangent != Vector2.ZERO:
		start += start_tangent.normalized() * lead
		if not StateGeography.segment_on_land(land, first, start):
			return PackedVector2Array()
		result.append(start)
	if end_tangent != Vector2.ZERO:
		finish -= end_tangent.normalized() * lead
	var joins := PackedVector2Array([start, finish])
	var tangents := PackedVector2Array()
	var handles := PackedFloat32Array()
	for index in range(joins.size()):
		var direction := Vector2.ZERO
		if index == 0:
			direction = start_tangent if start_tangent != Vector2.ZERO else anchors[0] - joins[0]
		elif index == joins.size() - 1:
			direction = end_tangent if end_tangent != Vector2.ZERO else joins[index] - anchors[-1]
		else:
			direction = anchors[index] - anchors[index - 1]
		if direction.length_squared() < 0.000001:
			direction = joins[mini(index + 1, joins.size() - 1)] - joins[maxi(0, index - 1)]
		tangents.append(direction.normalized())
		var before: float = joins[index - 1].distance_to(joins[index]) if index > 0 else INF
		var after: float = joins[index].distance_to(joins[index + 1]) if index < joins.size() - 1 else INF
		handles.append(minf(before, after) * 0.35)
	for index in range(joins.size() - 1):
		var segment_start: Vector2 = joins[index]
		var segment_end: Vector2 = joins[index + 1]
		var control_a: Vector2 = segment_start + tangents[index] * handles[index]
		var control_b: Vector2 = segment_end - tangents[index + 1] * handles[index + 1]
		if not _sample_player_curve(land, result, segment_start, control_a, control_b, segment_end, 0):
			return PackedVector2Array()
	if end_tangent != Vector2.ZERO:
		if not StateGeography.segment_on_land(land, result[-1], last):
			return PackedVector2Array()
		result.append(last)
	return result


static func _sample_player_curve(land: PackedVector2Array, result: PackedVector2Array, first: Vector2, control_a: Vector2, control_b: Vector2, last: Vector2, depth: int) -> bool:
	var chord_error: float = maxf(control_a.distance_to(Geometry2D.get_closest_point_to_segment(control_a, first, last)), control_b.distance_to(Geometry2D.get_closest_point_to_segment(control_b, first, last)))
	var entry: Vector2 = control_a - first
	var exit: Vector2 = last - control_b
	var turn: float = absf(entry.angle_to(exit)) if entry.length_squared() > 0.00000001 and exit.length_squared() > 0.00000001 else 0.0
	if depth >= 14 or (chord_error <= 0.00005 and turn <= deg_to_rad(2.0)):
		if result[-1].distance_to(last) < 0.0000001:
			return true
		if not StateGeography.segment_on_land(land, result[-1], last):
			return false
		result.append(last)
		return true
	var first_a: Vector2 = (first + control_a) * 0.5
	var middle: Vector2 = (control_a + control_b) * 0.5
	var last_b: Vector2 = (control_b + last) * 0.5
	var first_middle: Vector2 = (first_a + middle) * 0.5
	var last_middle: Vector2 = (middle + last_b) * 0.5
	var midpoint: Vector2 = (first_middle + last_middle) * 0.5
	return _sample_player_curve(land, result, first, first_a, first_middle, midpoint, depth + 1) and _sample_player_curve(land, result, midpoint, last_middle, last_b, last, depth + 1)


static func build(region, from_id: int, to_id: int, road_class: String, waypoints: PackedVector2Array = PackedVector2Array(), from_tangent: Vector2 = Vector2.ZERO, to_tangent: Vector2 = Vector2.ZERO, land_certified: bool = false) -> PackedVector2Array:
	assert(not land_certified or waypoints.is_empty())
	if road_class == RoadLinkData.HIGHWAY and not waypoints.is_empty():
		# A waypoint already on the natural route must not introduce a new bend.
		var natural_route: PackedVector2Array = build(region, from_id, to_id, road_class, PackedVector2Array(), from_tangent, to_tangent)
		var cursor := 0
		var all_on_route := true
		for waypoint in waypoints:
			while cursor < natural_route.size() and natural_route[cursor] != waypoint:
				cursor += 1
			if cursor == natural_route.size():
				all_on_route = false
				break
			cursor += 1
		if all_on_route:
			return natural_route
	var anchors := PackedVector2Array([region.road_nodes[from_id].position_km])
	anchors.append_array(waypoints)
	anchors.append(region.road_nodes[to_id].position_km)
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	var safe_path := PackedVector2Array([anchors[0]])
	for leg_index in range(1, anchors.size()):
		var safe_leg: PackedVector2Array = PackedVector2Array([anchors[leg_index - 1], anchors[leg_index]]) if land_certified else StateGeography.land_route(land, anchors[leg_index - 1], anchors[leg_index])
		for point_index in range(1, safe_leg.size()):
			if safe_path[-1].distance_squared_to(safe_leg[point_index]) > 0.000001:
				safe_path.append(safe_leg[point_index])
	if safe_path.size() < 2:
		return safe_path
	if road_class == RoadLinkData.ARTERIAL and waypoints.is_empty() and safe_path.size() == 2 and from_tangent==Vector2.ZERO and to_tangent==Vector2.ZERO:
		return safe_path
	# Use one bend scale for the whole route so adjoining segments keep the same tangent.
	var highway: bool = road_class == RoadLinkData.HIGHWAY
	var path_options: Array[PackedVector2Array] = [safe_path]
	if highway:
		if safe_path.size() > 2:
			for inset_km in [2.0, 4.0, 8.0, 12.0, 20.0, 30.0]:
				var inset_path: PackedVector2Array = _inset_coastal_detour(land, safe_path, inset_km)
				if not inset_path.is_empty():
					path_options.append(inset_path)
		elif not land_certified:
			# Small side routes give a coastline-constrained endpoint more room to turn.
			var middle: Vector2 = safe_path[0].lerp(safe_path[1], 0.5)
			var normal: Vector2 = (safe_path[1] - safe_path[0]).normalized().orthogonal()
			for offset_km in [-5.0, 5.0, -10.0, 10.0, -20.0, 20.0, -40.0, 40.0]:
				var middle_point: Vector2 = middle + normal * offset_km
				if Geometry2D.is_point_in_polygon(middle_point, land) and StateGeography.segment_on_land(land, safe_path[0], middle_point) and StateGeography.segment_on_land(land, middle_point, safe_path[1]):
					path_options.append(PackedVector2Array([safe_path[0], middle_point, safe_path[1]]))
	var best_route := PackedVector2Array()
	var best_radius := -1.0
	for path in path_options:
		for bend_scale in [1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.0]:
			if bend_scale == 0.0 and not highway:
				return safe_path
			var handle_scales: Array[float] = [1.0]
			if highway:
				handle_scales.append_array([1.5, 2.0, 3.0])
			for handle_scale in handle_scales:
				var route := PackedVector2Array([path[0]])
				var valid := true
				for segment_index in range(path.size() - 1):
					var first: Vector2 = path[segment_index]
					var last: Vector2 = path[segment_index + 1]
					var chord: Vector2 = (last - first).normalized()
					var start_direction: Vector2 = _tangent_at(path, segment_index, from_tangent, to_tangent, bend_scale)
					var end_direction: Vector2 = _tangent_at(path, segment_index + 1, from_tangent, to_tangent, bend_scale)
					var segment: PackedVector2Array = _curved_segment(land, first, last, chord, start_direction, end_direction, road_class, region.generation_seed, from_id, to_id, segment_index, bend_scale, handle_scale, land_certified)
					if segment.is_empty():
						valid = false
						break
					for point_index in range(1, segment.size()):
						route.append(segment[point_index])
				if not valid:
					continue
				if not highway:
					return route
				var radius: float = significant_curve_radius(route)
				if radius >= MIN_HIGHWAY_RADIUS_KM:
					return route
				if radius > best_radius:
					best_radius = radius
					best_route = route
	return best_route if not best_route.is_empty() else safe_path


static func minimum_curve_radius(points: PackedVector2Array) -> float:
	var minimum := INF
	for index in range(1, points.size() - 1):
		var before: Vector2 = points[index] - points[index - 1]
		var after: Vector2 = points[index + 1] - points[index]
		if before.length() < 0.005 or after.length() < 0.005:
			continue
		var cross: float = absf(before.cross(after))
		if cross < 0.00000001:
			continue
		minimum = minf(minimum, before.length() * after.length() * (before + after).length() / (2.0 * cross))
	return minimum


# Curvature of the genuine alignment rather than its polyline sampling: curves
# flatter than the 2 m chord tolerance are absorbed by simplification first.
static func significant_curve_radius(points: PackedVector2Array) -> float:
	return minimum_curve_radius(_simplify(points, 0.002))


static func _simplify(points: PackedVector2Array, epsilon: float) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var keep := PackedByteArray()
	keep.resize(points.size())
	keep[0] = 1
	keep[points.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, points.size() - 1)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var index := -1
		var distance := 0.0
		for middle in range(span.x + 1, span.y):
			var trial: float = Geometry2D.get_closest_point_to_segment(points[middle], points[span.x], points[span.y]).distance_to(points[middle])
			if trial > distance:
				distance = trial
				index = middle
		if distance > epsilon and index >= 0:
			keep[index] = 1
			stack.append(Vector2i(span.x, index))
			stack.append(Vector2i(index, span.y))
	var result := PackedVector2Array()
	for index in range(points.size()):
		if keep[index] != 0:
			result.append(points[index])
	return result


static func _inset_coastal_detour(land: PackedVector2Array, path: PackedVector2Array, inset_km: float) -> PackedVector2Array:
	var signed_area := 0.0
	for index in range(land.size()):
		signed_area += land[index].cross(land[(index + 1) % land.size()])
	# Vector2.orthogonal() points right of its vector in Godot coordinates.
	var inward_sign := -1.0 if signed_area > 0.0 else 1.0
	var inset := path.duplicate()
	for path_index in range(1, path.size() - 1):
		var nearest_index := -1
		var nearest_distance := INF
		for coast_index in range(land.size()):
			var distance: float = path[path_index].distance_squared_to(land[coast_index])
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_index = coast_index
		if nearest_distance > 0.000001:
			continue
		var previous: Vector2 = (land[nearest_index] - land[posmod(nearest_index - 1, land.size())]).normalized()
		var next: Vector2 = (land[(nearest_index + 1) % land.size()] - land[nearest_index]).normalized()
		var inward: Vector2 = (previous.orthogonal() + next.orthogonal()).normalized() * inward_sign
		if inward == Vector2.ZERO:
			return PackedVector2Array()
		inset[path_index] = path[path_index] + inward * inset_km
		if not Geometry2D.is_point_in_polygon(inset[path_index], land):
			return PackedVector2Array()
	for segment_index in range(1, inset.size()):
		if not StateGeography.segment_on_land(land, inset[segment_index - 1], inset[segment_index]):
			return PackedVector2Array()
	return inset


static func clearance_to_coast(land: PackedVector2Array, point: Vector2) -> float:
	var clearance := INF
	for index in range(land.size()):
		clearance = minf(clearance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, land[index], land[(index + 1) % land.size()])))
	return clearance


static func _tangent_at(path: PackedVector2Array, index: int, from_tangent: Vector2, to_tangent: Vector2, bend_scale: float) -> Vector2:
	var incoming: Vector2 = (path[index] - path[index - 1]).normalized() if index > 0 else (path[1] - path[0]).normalized()
	var outgoing: Vector2 = (path[index + 1] - path[index]).normalized() if index < path.size() - 1 else incoming
	if index == 0 and from_tangent != Vector2.ZERO:
		return from_tangent.normalized()
	if index == path.size() - 1 and to_tangent != Vector2.ZERO:
		return to_tangent.normalized()
	var preferred: Vector2 = outgoing
	if index > 0 and index < path.size() - 1 and incoming.dot(outgoing) > -0.65:
		preferred = (incoming + outgoing).normalized()
	var straight: Vector2 = outgoing if index < path.size() - 1 else incoming
	return straight.lerp(preferred, bend_scale).normalized()


static func _curved_segment(land: PackedVector2Array, first: Vector2, last: Vector2, chord: Vector2, start_direction: Vector2, end_direction: Vector2, road_class: String, seed_value: int, from_id: int, to_id: int, segment_index: int, bend_scale: float, handle_scale: float, land_certified: bool) -> PackedVector2Array:
	var length: float = first.distance_to(last)
	if length < 0.001:
		return PackedVector2Array([first, last])
	var highway: bool = road_class == RoadLinkData.HIGHWAY
	var rng := RandomNumberGenerator.new()
	rng.seed = posmod(seed_value * 1000003 + from_id * 73856093 + to_id * 19349663 + segment_index * 26544357, 2147483647)
	var bend: float = minf(length * (0.055 if highway else 0.12), 7.0 if highway else 1.4) * rng.randf_range(0.75, 1.0) * (-1.0 if rng.randf() < 0.5 else 1.0) * bend_scale
	var edge_distance: float = minf(HIGHWAY_TANGENT_STRAIGHT_KM, length * 0.08) if highway else 0.0
	var curve_first: Vector2 = first + start_direction * edge_distance
	var curve_last: Vector2 = last - end_direction * edge_distance
	var handle_length: float = minf(minf(length * 0.32, 12.0 if highway else 1.0) * handle_scale, length * 0.48)
	var first_control: Vector2 = curve_first + start_direction * handle_length
	var second_control: Vector2 = curve_last - end_direction * handle_length
	var steps: int = clampi(ceili(length / (2.0 if highway else 0.15)), 12 if highway else 6, 80)
	var sample_times: Array[float] = []
	for step in range(1, steps):
		var sample_t: float = float(step) / float(steps)
		if highway:
			sample_t = 0.5 - 0.5 * cos(sample_t * PI)
		sample_times.append(sample_t)
	var candidate := PackedVector2Array([first])
	if highway:
		if not land_certified and not StateGeography.segment_on_land(land, first, curve_first):
			return PackedVector2Array()
		candidate.append(curve_first)
	for t in sample_times:
		var inverse: float = 1.0 - t
		var point: Vector2 = curve_first * (inverse * inverse * inverse) + first_control * (3.0 * inverse * inverse * t) + second_control * (3.0 * inverse * t * t) + curve_last * (t * t * t)
		point += chord.orthogonal() * (bend * 16.0 * t * t * inverse * inverse)
		if not land_certified and not StateGeography.segment_on_land(land, candidate[-1], point):
			return PackedVector2Array()
		candidate.append(point)
	if highway:
		if not land_certified and not StateGeography.segment_on_land(land, candidate[-1], curve_last):
			return PackedVector2Array()
		candidate.append(curve_last)
	if not land_certified and not StateGeography.segment_on_land(land, candidate[-1], last):
		return PackedVector2Array()
	candidate.append(last)
	return candidate
