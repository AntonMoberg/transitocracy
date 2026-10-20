extends RefCounted

# Road directions are axial: a street heading east is the same street heading
# west. Blending doubled angles avoids a false cancellation at 180 degrees.
static func axis(seed_value: int, city_id: int, point: Vector2, base: Vector2, inherited: Vector2 = Vector2.ZERO, organic: bool = false, radial_center: Vector2 = Vector2.INF) -> Vector2:
	var reference: Vector2 = base.normalized() if base.length_squared() > 0.000001 else Vector2.RIGHT
	var base_angle: float = reference.angle()
	var doubled := Vector2(cos(base_angle * 2.0), sin(base_angle * 2.0))
	if inherited.length_squared() > 0.000001:
		var guide_angle: float = inherited.angle()
		var guide := Vector2(cos(guide_angle * 2.0), sin(guide_angle * 2.0))
		doubled += guide * (3.0 if not organic else 0.5)
	if organic and radial_center.is_finite() and point.distance_squared_to(radial_center) > 0.04:
		var radial_angle: float = (point - radial_center).angle()
		doubled += Vector2(cos(radial_angle * 2.0), sin(radial_angle * 2.0)) * 0.35
	doubled = doubled.normalized()
	var phase: float = float(posmod(hash("%d:field:%d" % [seed_value, city_id]), 100000)) * TAU / 100000.0
	var wave: float = sin(point.x * 1.15 + phase) * 0.6 + sin(point.y * 1.05 - phase * 1.31) * 0.4
	var angle: float = atan2(doubled.y, doubled.x) * 0.5 + wave * (0.24 if organic else 0.11)
	var result := Vector2.from_angle(angle)
	return result if result.dot(reference) >= 0.0 else -result


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
	var reference: Vector2 = blend.normalized() if blend.length_squared() > 0.01 else chord
	var phase: float = float(posmod(hash("%d:regional-field:%d" % [seed_value, corridor_index]), 100000)) * TAU / 100000.0
	var turn: float = sin(point.x * 0.018 + phase) * 0.075 + sin(point.y * 0.023 - phase) * 0.03
	return reference.rotated(turn)
