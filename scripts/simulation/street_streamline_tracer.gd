extends RefCounted

const DirectionField = preload("res://scripts/simulation/street_direction_field.gd")


# Trace both street families through the same axial field. Their crossings,
# rather than a displaced rectangular lattice, become the street junctions.
# The supplied perimeter is held fixed so adjacent districts retain shared
# streets and the player's drawn zoning outline stays exact.
static func trace_grid(positions: Dictionary, columns: int, rows: int, seed_value: int, city_id: int, guide: Vector2, organic: bool, radial_center: Vector2, maximum_shift: float, fixed_row: int = -1) -> Dictionary:
	var horizontal: Array = []
	var vertical: Array = []
	for row in range(rows + 1):
		var seeds := PackedVector2Array()
		for column in range(columns + 1):
			seeds.append(positions[Vector2i(column, row)])
		horizontal.append(seeds if row == 0 or row == rows or row == fixed_row else _trace_family(seeds, seed_value, city_id, guide, organic, radial_center))
	for column in range(columns + 1):
		var seeds := PackedVector2Array()
		for row in range(rows + 1):
			seeds.append(positions[Vector2i(column, row)])
		vertical.append(seeds if column == 0 or column == columns else _trace_family(seeds, seed_value, city_id, guide, organic, radial_center))
	var result: Dictionary = positions.duplicate()
	for row in range(1, rows):
		if row == fixed_row:
			continue
		for column in range(1, columns):
			var address := Vector2i(column, row)
			var original: Vector2 = positions[address]
			var row_path: PackedVector2Array = horizontal[row]
			var column_path: PackedVector2Array = vertical[column]
			var crossing := Vector2.INF
			var nearest := INF
			for along in range(maxi(0, column - 1), mini(columns - 1, column) + 1):
				for across in range(maxi(0, row - 1), mini(rows - 1, row) + 1):
					var hit = Geometry2D.segment_intersects_segment(row_path[along], row_path[along + 1], column_path[across], column_path[across + 1])
					if hit == null:
						continue
					var distance: float = original.distance_squared_to(hit)
					if distance < nearest:
						crossing = hit
						nearest = distance
			if not crossing.is_finite():
				crossing = (row_path[column] + column_path[row]) * 0.5
			var shift: Vector2 = crossing - original
			if shift.length() > maximum_shift:
				crossing = original + shift.normalized() * maximum_shift
			result[address] = crossing
	return result


static func _trace_family(seeds: PackedVector2Array, seed_value: int, city_id: int, guide: Vector2, organic: bool, radial_center: Vector2) -> PackedVector2Array:
	var traced := PackedVector2Array([seeds[0]])
	for index in range(1, seeds.size()):
		var base: Vector2 = seeds[index] - seeds[index - 1]
		var length: float = base.length()
		if length < 0.000001:
			traced.append(traced[-1])
			continue
		var local_guide: Vector2 = guide.orthogonal() if guide != Vector2.ZERO and absf(guide.dot(base / length)) < 0.5 else guide
		var step: Vector2 = _rk4_step(traced[-1], base / length, length, seed_value, city_id, local_guide, organic, radial_center)
		traced.append(traced[-1] + step)
	# A linear endpoint correction preserves both perimeter anchors without
	# replacing the field's integrated bends in the middle of the street.
	var correction: Vector2 = seeds[-1] - traced[-1]
	var distance := 0.0
	var total := 0.0
	for index in range(1, seeds.size()):
		total += seeds[index - 1].distance_to(seeds[index])
	for index in range(1, seeds.size()):
		distance += seeds[index - 1].distance_to(seeds[index])
		traced[index] += correction * (distance / maxf(total, 0.000001))
	traced[-1] = seeds[-1]
	return traced


static func _rk4_step(point: Vector2, reference: Vector2, distance: float, seed_value: int, city_id: int, guide: Vector2, organic: bool, radial_center: Vector2) -> Vector2:
	var first: Vector2 = DirectionField.axis(seed_value, city_id, point, reference, guide, organic, radial_center)
	var second: Vector2 = DirectionField.axis(seed_value, city_id, point + first * distance * 0.5, reference, guide, organic, radial_center)
	var third: Vector2 = DirectionField.axis(seed_value, city_id, point + second * distance * 0.5, reference, guide, organic, radial_center)
	var fourth: Vector2 = DirectionField.axis(seed_value, city_id, point + third * distance, reference, guide, organic, radial_center)
	return (first + second * 2.0 + third * 2.0 + fourth) * (distance / 6.0)
