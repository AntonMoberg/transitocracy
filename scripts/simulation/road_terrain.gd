extends RefCounted

const Roads = preload("res://scripts/simulation/road_link_data.gd")
const SAMPLE_KM = 0.10


static func slice_profile(original: PackedVector2Array, heights: PackedFloat32Array, path: PackedVector2Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if heights.size() != original.size():
		return result
	var known: Dictionary = {}
	for index in range(original.size()):
		known[original[index]] = heights[index]
	for point in path:
		if known.has(point):
			result.append(known[point])
			continue
		var best := INF
		var value := 0.0
		for index in range(1, original.size()):
			var near: Vector2 = Geometry2D.get_closest_point_to_segment(point, original[index - 1], original[index])
			var distance: float = near.distance_squared_to(point)
			if distance < best:
				best = distance
				var fraction: float = original[index - 1].distance_to(near) / maxf(0.000001, original[index - 1].distance_to(original[index]))
				value = lerpf(heights[index - 1], heights[index], fraction)
		result.append(value)
	return result


static func clip_spans(original: Array[Dictionary], path: PackedVector2Array, profile: PackedFloat32Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(1, path.size()):
		var middle: Vector2 = (path[index - 1] + path[index]) * 0.5
		var kind := ""
		for span in original:
			var points: PackedVector2Array = span.get("points", PackedVector2Array([span["from"], span["to"]]))
			for segment in range(1, points.size()):
				if middle.distance_to(Geometry2D.get_closest_point_to_segment(middle, points[segment - 1], points[segment])) < 0.0001:
					kind = span["kind"]
					break
			if kind != "":
				break
		if kind == "":
			continue
		var distance: float = path[index - 1].distance_to(path[index])
		if not result.is_empty() and result[-1]["kind"] == kind and result[-1]["to"].distance_to(path[index - 1]) < 0.00001:
			result[-1]["points"].append(path[index])
			result[-1]["elevations_m"].append(profile[index])
			result[-1]["to"] = path[index]
			result[-1]["length_km"] += distance
		else:
			result.append({"kind": kind, "from": path[index - 1], "to": path[index], "points": PackedVector2Array([path[index - 1], path[index]]), "elevations_m": PackedFloat32Array([profile[index - 1], profile[index]]), "length_km": distance})
	return result


static func spans(region, points: PackedVector2Array, road_class: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for span in preview(region, points, road_class, true).get("spans", []):
		result.append(span)
	return result


static func surface_paths(region, points: PackedVector2Array, road_class: String) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for path in preview(region, points, road_class, true).get("surface_paths", [points]):
		result.append(path)
	return result


static func preview(region, points: PackedVector2Array, road_class: String, allow_water_endpoints: bool = false) -> Dictionary:
	if region.terrain == null or points.size() < 2:
		var plain_paths: Array[PackedVector2Array] = []
		plain_paths.append(points)
		return {"ok": true, "spans": [], "surface_paths": plain_paths, "cost": 0, "bridge_km": 0.0, "tunnel_km": 0.0, "earthwork_km": 0.0, "max_grade": 0.0}
	var terrain = region.terrain
	if not allow_water_endpoints and (terrain.water_at(points[0]) or terrain.water_at(points[-1])):
		return {"ok": false, "reason": "Roads need dry land at both ends."}
	var grade_limit: float = 0.06 if road_class == Roads.HIGHWAY else 0.08
	var samples := PackedVector2Array([points[0]])
	for segment in range(1, points.size()):
		var length: float = points[segment - 1].distance_to(points[segment])
		for part in range(1, maxi(1, ceili(length / SAMPLE_KM)) + 1):
			samples.append(points[segment - 1].lerp(points[segment], float(part) / float(maxi(1, ceili(length / SAMPLE_KM)))))
	var segment_kinds := PackedStringArray()
	var max_grade := 0.0
	for i in range(1, samples.size()):
		var first: Vector2 = samples[i - 1]
		var last: Vector2 = samples[i]
		var distance: float = first.distance_to(last)
		var grade: float = absf(terrain.elevation_at(first) - terrain.elevation_at(last)) / maxf(1.0, distance * 1000.0)
		max_grade = maxf(max_grade, grade)
		var kind := ""
		if distance >= 0.00001:
			var middle: Vector2 = (first + last) * 0.5
			if terrain.water_at(middle) or terrain.water_at(first.lerp(last, 0.25)) or terrain.water_at(first.lerp(last, 0.75)):
				kind = "Bridge"
			elif grade > grade_limit * 1.8 and terrain.slope_at(middle) > 0.15:
				kind = "Tunnel"
			elif grade > grade_limit * 0.65:
				kind = "Earthwork"
		if kind == "Tunnel" and (i == 1 or i == samples.size() - 1):
			kind = "Earthwork"
		segment_kinds.append(kind)
	# A one or two sample steep patch calls for grading, not a tiny tunnel.
	var tunnel_start := -1
	for index in range(segment_kinds.size() + 1):
		if index < segment_kinds.size() and segment_kinds[index] == "Tunnel":
			if tunnel_start < 0:
				tunnel_start = index
		elif tunnel_start >= 0:
			var run_length := 0.0
			for run in range(tunnel_start, index):
				run_length += samples[run].distance_to(samples[run + 1])
			if run_length < 0.25:
				for run in range(tunnel_start, index):
					segment_kinds[run] = "Earthwork"
			tunnel_start = -1
	var spans: Array[Dictionary] = []
	var surface_paths: Array[PackedVector2Array] = []
	var current_surface := PackedVector2Array()
	var active_kind := ""
	var active_start := Vector2.ZERO
	var active_length := 0.0
	var active_points := PackedVector2Array()
	var bridge_km := 0.0
	var tunnel_km := 0.0
	var earthwork_km := 0.0
	for i in range(1, samples.size()):
		var a: Vector2 = samples[i - 1]
		var b: Vector2 = samples[i]
		var distance: float = a.distance_to(b)
		if distance < 0.00001:
			continue
		var kind: String = segment_kinds[i - 1]
		if kind == "Tunnel":
			if current_surface.size() >= 2:
				surface_paths.append(current_surface)
			current_surface = PackedVector2Array()
		else:
			if current_surface.is_empty():
				current_surface.append(a)
			current_surface.append(b)
		if kind != active_kind:
			if active_kind != "":
				spans.append({"kind": active_kind, "from": active_start, "to": a, "points": active_points, "length_km": active_length})
			active_kind = kind
			active_start = a
			active_length = 0.0
			active_points = PackedVector2Array([a])
		active_length += distance
		if kind != "":
			active_points.append(b)
		match kind:
			"Bridge": bridge_km += distance
			"Tunnel": tunnel_km += distance
			"Earthwork": earthwork_km += distance
	if active_kind != "":
		spans.append({"kind": active_kind, "from": active_start, "to": samples[-1], "points": active_points, "length_km": active_length})
	if current_surface.size() >= 2:
		surface_paths.append(current_surface)
	var cost: int = roundi(bridge_km * (15000000.0 if road_class == Roads.HIGHWAY else 8000000.0) + tunnel_km * (30000000.0 if road_class == Roads.HIGHWAY else 18000000.0) + earthwork_km * 700000.0)
	return {"ok": true, "spans": spans, "surface_paths": surface_paths, "cost": cost, "bridge_km": bridge_km, "tunnel_km": tunnel_km, "earthwork_km": earthwork_km, "max_grade": max_grade}
