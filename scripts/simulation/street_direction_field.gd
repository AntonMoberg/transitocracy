extends RefCounted

const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")

const ROAD_INFLUENCE_KM = 0.8
const MAX_ROAD_SEGMENTS = 24


# The city axis is fixed when its starter streets are laid out. Built arterials
# are local constraints on that persistent, seeded field; adding one changes
# future plans nearby without moving streets in approved districts.
static func city_context(region, city_id: int, bounds: Rect2) -> Dictionary:
	var city: Dictionary = region.cities[city_id]
	var base_axis: Vector2 = city.get("street_axis", Vector2.ZERO)
	if base_axis.length_squared() < 0.01:
		var phase: float = float(posmod(hash("%d:city-field:%d" % [region.generation_seed, city_id]), 100000)) / 100000.0
		base_axis = Vector2.from_angle(phase * PI)
	var context := {"base_axis": base_axis.normalized(), "roads": []}
	if region.road_links.is_empty():
		return context
	var search: Rect2 = bounds.grow(ROAD_INFLUENCE_KM)
	var index: Dictionary = Spatial.cache(region)
	var seen: Dictionary = {}
	var segments: Array[Dictionary] = []
	for cell_y in range(floori(search.position.y), ceili(search.end.y) + 1):
		for cell_x in range(floori(search.position.x), ceili(search.end.x) + 1):
			for link_index in index["arterials"].get(Vector2i(cell_x, cell_y), []):
				if seen.has(link_index):
					continue
				seen[link_index] = true
				var link = region.road_links[link_index]
				if link.road_class != Roads.ARTERIAL:
					continue
				for segment in range(1, link.points.size()):
					var first: Vector2 = link.points[segment - 1]
					var last: Vector2 = link.points[segment]
					if first.distance_squared_to(last) < 0.0001 or not Rect2(first.min(last), (last - first).abs()).grow(ROAD_INFLUENCE_KM).intersects(bounds):
						continue
					var near: Vector2 = Geometry2D.get_closest_point_to_segment(bounds.get_center(), first, last)
					segments.append({"first": first, "last": last, "axis": (last - first).normalized(), "distance": near.distance_squared_to(bounds.get_center())})
	segments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["distance"]) < float(b["distance"]))
	if segments.size() > MAX_ROAD_SEGMENTS:
		segments.resize(MAX_ROAD_SEGMENTS)
	context["roads"] = segments
	return context

# Road directions are axial: a street heading east is the same street heading
# west. Blending doubled angles avoids a false cancellation at 180 degrees.
static func axis(seed_value: int, city_id: int, point: Vector2, base: Vector2, inherited: Vector2 = Vector2.ZERO, organic: bool = false, radial_center: Vector2 = Vector2.INF, context: Dictionary = {}) -> Vector2:
	var reference_axis: Vector2 = base.normalized() if base.length_squared() > 0.000001 else Vector2.RIGHT
	var doubled: Vector2 = _axial(reference_axis) * (2.6 if not organic else 1.1)
	if context.has("base_axis"):
		doubled += _axial(_family_axis(context["base_axis"], reference_axis)) * (1.1 if not organic else 1.3)
	if inherited.length_squared() > 0.000001:
		doubled += _axial(_family_axis(inherited, reference_axis)) * (3.0 if not organic else 0.85)
	var nearest_weight := 0.0
	var nearest_axis := Vector2.ZERO
	for road in context.get("roads", []):
		var distance: float = point.distance_to(Geometry2D.get_closest_point_to_segment(point, road["first"], road["last"]))
		if distance >= ROAD_INFLUENCE_KM:
			continue
		var strength: float = pow(1.0 - distance / ROAD_INFLUENCE_KM, 2.0)
		if strength > nearest_weight:
			nearest_weight = strength
			nearest_axis = road["axis"]
	if nearest_weight > 0.0:
		doubled += _axial(_family_axis(nearest_axis, reference_axis)) * nearest_weight * (2.0 if not organic else 2.4)
	if organic and radial_center.is_finite() and point.distance_squared_to(radial_center) > 0.04:
		doubled += _axial(_family_axis(point - radial_center, reference_axis)) * 0.38
	doubled = doubled.normalized()
	var phase: float = float(posmod(hash("%d:field:%d" % [seed_value, city_id]), 100000)) * TAU / 100000.0
	var wave: float = sin(point.x * 2.3 + phase) * 0.55 + sin(point.y * 3.1 - phase * 1.31) * 0.45
	var angle: float = atan2(doubled.y, doubled.x) * 0.5 + wave * (0.46 if organic else 0.055)
	var result := Vector2.from_angle(angle)
	return result if result.dot(reference_axis) >= 0.0 else -result


static func _family_axis(candidate: Vector2, reference_axis: Vector2) -> Vector2:
	var direction: Vector2 = candidate.normalized()
	return direction.orthogonal() if absf(direction.dot(reference_axis)) < 0.707 else direction


static func _axial(direction: Vector2) -> Vector2:
	var angle: float = direction.angle() * 2.0
	return Vector2(cos(angle), sin(angle))


# Trace a regional corridor through a much broader field than district
# streets. The endpoint correction makes the trace meet selected interchange
# sites exactly while preserving the integrated direction changes between them.
static func trace_regional(first: Vector2, last: Vector2, start_tangent: Vector2, end_tangent: Vector2, seed_value: int, corridor_index: int) -> PackedVector2Array:
	var span: float = first.distance_to(last)
	if span < 0.2:
		return PackedVector2Array([first, last])
	var steps: int = clampi(ceili(span / 2.0), 8, 90)
	var step_length: float = span / float(steps)
	var chord: Vector2 = (last - first) / span
	var traced := PackedVector2Array([first])
	for index in range(steps):
		var fraction: float = float(index) / float(steps)
		var point: Vector2 = traced[-1]
		var a: Vector2 = _regional_direction(point, fraction, chord, start_tangent, end_tangent, seed_value, corridor_index)
		var b: Vector2 = _regional_direction(point + a * step_length * 0.5, fraction + 0.5 / float(steps), chord, start_tangent, end_tangent, seed_value, corridor_index)
		var c: Vector2 = _regional_direction(point + b * step_length * 0.5, fraction + 0.5 / float(steps), chord, start_tangent, end_tangent, seed_value, corridor_index)
		var d: Vector2 = _regional_direction(point + c * step_length, fraction + 1.0 / float(steps), chord, start_tangent, end_tangent, seed_value, corridor_index)
		traced.append(point + (a + b * 2.0 + c * 2.0 + d) * (step_length / 6.0))
	var residual: Vector2 = last - traced[-1]
	for index in range(1, steps):
		var fraction: float = float(index) / float(steps)
		traced[index] += residual * fraction * fraction * (3.0 - 2.0 * fraction)
	traced[-1] = last
	return traced


static func _regional_direction(point: Vector2, fraction: float, chord: Vector2, start_tangent: Vector2, end_tangent: Vector2, seed_value: int, corridor_index: int) -> Vector2:
	var entry: Vector2 = start_tangent.normalized() if start_tangent.length_squared() > 0.01 else chord
	var exit: Vector2 = end_tangent.normalized() if end_tangent.length_squared() > 0.01 else chord
	var blend: Vector2 = entry.lerp(exit, clampf(fraction, 0.0, 1.0))
	var reference_axis: Vector2 = blend.normalized() if blend.length_squared() > 0.01 else chord
	var phase: float = float(posmod(hash("%d:regional-field:%d" % [seed_value, corridor_index]), 100000)) * TAU / 100000.0
	var turn: float = sin(point.x * 0.018 + phase) * 0.075 + sin(point.y * 0.023 - phase) * 0.03
	return reference_axis.rotated(turn)
