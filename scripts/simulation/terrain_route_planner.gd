extends RefCounted

# Terrain-weighted route search for generated highways, arterials, and rural
# roads. Navigation states are (cell, heading) pairs stored in flat typed
# arrays; cell terrain and directed edge costs fill lazily so repeated routes
# in the same area cost array reads. Curve samples stay out of the graph.
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const DIRECTIONS = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
const HEADINGS := 9


var region
var step_km: float
var origin_cell: Vector2i
var field_width: int
var field_height: int
var cell_filled: PackedByteArray = PackedByteArray()
var cell_land: PackedByteArray = PackedByteArray()
var cell_water: PackedByteArray = PackedByteArray()
var cell_height_m: PackedFloat32Array = PackedFloat32Array()
var cell_slope: PackedFloat32Array = PackedFloat32Array()
var edge_computed: PackedByteArray = PackedByteArray()
var edge_costs: PackedFloat32Array = PackedFloat32Array()
var tunnel_cache: Dictionary = {}
var generated_highway := false
var valley_weight := 0.0
var tunnel_limit_km := 20.0
var corridor_search := false
var cached_grade := -1.0
var valley_heights := {}
var fine_planner
# Read-only penalty grid stamped from already-built trunk corridors, so later
# routes prefer their own valley instead of braiding alongside a highway.
var avoid_costs: PackedFloat32Array = PackedFloat32Array()
var avoid_origin := Vector2i.ZERO
var avoid_step: float = 4.0
var avoid_size := Vector2i.ZERO
var avoid_endpoints: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]

# Per-search state; a planner instance runs one search at a time.
var heap_states := PackedInt32Array()
var heap_priorities := PackedFloat32Array()
var heap_size := 0
var search_costs := PackedFloat32Array()
var search_parents := PackedInt32Array()
var search_tunnel_marks := PackedByteArray()
var search_closed := PackedByteArray()
var block_x0 := 0
var block_y0 := 0
var block_width := 1


func _init(source, spacing: float = 4.0) -> void:
	region = source
	step_km = spacing
	var bounds: Rect2 = region.jurisdictions[0].bounds_km.grow(step_km)
	origin_cell = Vector2i(floori(bounds.position.x / step_km), floori(bounds.position.y / step_km))
	field_width = maxi(1, ceili(bounds.end.x / step_km) - origin_cell.x + 1)
	field_height = maxi(1, ceili(bounds.end.y / step_km) - origin_cell.y + 1)
	var cells := field_width * field_height
	cell_filled.resize(cells)
	cell_land.resize(cells)
	cell_water.resize(cells)
	cell_height_m.resize(cells)
	cell_slope.resize(cells)
	edge_computed.resize(cells * 8)
	edge_costs.resize(cells * 8)


func set_avoidance(costs: PackedFloat32Array, origin: Vector2i, step: float, size: Vector2i) -> void:
	avoid_costs = costs
	avoid_origin = origin
	avoid_step = step
	avoid_size = size
	if not edge_computed.is_empty():
		edge_computed.fill(0)


func _avoid_at(point: Vector2) -> float:
	if avoid_costs.is_empty():
		return 0.0
	var cell := Vector2i(floori(point.x / avoid_step) - avoid_origin.x, floori(point.y / avoid_step) - avoid_origin.y)
	if cell.x < 0 or cell.y < 0 or cell.x >= avoid_size.x or cell.y >= avoid_size.y:
		return 0.0
	return avoid_costs[cell.y * avoid_size.x + cell.x]


func _avoid_penalty_km(a: Vector2, b: Vector2) -> float:
	if avoid_costs.is_empty():
		return 0.0
	var middle: Vector2 = (a + b) * 0.5
	var fade := 1.0
	for endpoint in avoid_endpoints:
		fade = minf(fade, middle.distance_to(endpoint) / 4.0)
	fade = clampf(fade, 0.0, 1.0)
	if fade <= 0.0:
		return 0.0
	return _avoid_at(middle) * fade * a.distance_to(b)


func route(first: Vector2, last: Vector2, road_class: String, start_tangent: Vector2 = Vector2.ZERO, end_tangent: Vector2 = Vector2.ZERO, allow_fine: bool = true, long_range: bool = false) -> Dictionary:
	if first.distance_to(last) < 0.05:
		return {}
	avoid_endpoints = [first, last]
	if cached_grade != (0.06 if road_class == Roads.HIGHWAY else 0.08):
		edge_computed.fill(0)
		cached_grade = 0.06 if road_class == Roads.HIGHWAY else 0.08
	var lead: float = minf(4.0 if generated_highway else 0.35, first.distance_to(last) * 0.1)
	var start: Vector2 = first + start_tangent.normalized() * lead
	var finish: Vector2 = last - end_tangent.normalized() * lead
	var gentle := not generated_highway
	var direct_samples: int = maxi(8, ceili(first.distance_to(last)))
	for index in range(direct_samples + 1) if gentle else []:
		var point: Vector2 = first.lerp(last, float(index) / float(direct_samples))
		if not region.jurisdictions[0].contains_point(point) or region.terrain.slope_at(point) > 0.028 or region.terrain.water_at(point) or _avoid_at(point) > 0.15:
			gentle = false
			break
	if gentle:
		var direct := PackedVector2Array([first])
		if start_tangent != Vector2.ZERO:
			direct.append(start)
		if end_tangent != Vector2.ZERO:
			direct.append(finish)
		direct.append(last)
		var points: PackedVector2Array = _smooth(direct, road_class, [])
		if not points.is_empty():
			var result: Dictionary = _profile(points, road_class, [])
			if not result.is_empty():
				return result
	var traced: Dictionary = _search(start, finish, road_class, start_tangent, long_range)
	if not traced.is_empty():
		var trace: PackedVector2Array = traced["points"]
		if start_tangent != Vector2.ZERO:
			trace.insert(0, first)
		else:
			trace[0] = first
		if end_tangent != Vector2.ZERO:
			trace.append(last)
		else:
			trace[-1] = last
		var points: PackedVector2Array = _smooth(trace, road_class, traced["tunnels"])
		if not points.is_empty():
			var result: Dictionary = _profile(points, road_class, traced["tunnels"])
			if not result.is_empty():
				return result
	if allow_fine and step_km > 1.0 and not long_range:
		if fine_planner == null:
			fine_planner = get_script().new(region, 1.0)
			fine_planner.set_avoidance(avoid_costs, avoid_origin, avoid_step, avoid_size)
		fine_planner.generated_highway = generated_highway
		fine_planner.valley_weight = valley_weight
		fine_planner.tunnel_limit_km = tunnel_limit_km
		fine_planner.edge_computed.fill(0)
		return fine_planner.route(first, last, road_class, start_tangent, end_tangent)
	return {}


func _cell_data(cell: Vector2i) -> int:
	var x: int = cell.x - origin_cell.x
	var y: int = cell.y - origin_cell.y
	if x < 0 or y < 0 or x >= field_width or y >= field_height:
		return -1
	var index: int = y * field_width + x
	if cell_filled[index] == 0:
		cell_filled[index] = 1
		var point: Vector2 = Vector2(cell) * step_km
		if region.jurisdictions[0].contains_point(point):
			cell_land[index] = 1
			cell_height_m[index] = region.terrain.elevation_at(point)
			cell_slope[index] = region.terrain.slope_at(point)
			cell_water[index] = 1 if region.terrain.water_at(point) else 0
	return index


func _travel_cost(first_cell: Vector2i, last_cell: Vector2i, direction: int, grade_limit: float) -> float:
	var first_index: int = _cell_data(first_cell)
	var last_index: int = _cell_data(last_cell)
	if first_index < 0 or last_index < 0:
		return INF
	var slot: int = first_index * 8 + direction
	if edge_computed[slot] != 0:
		return edge_costs[slot] + _avoid_penalty_km(Vector2(first_cell) * step_km, Vector2(last_cell) * step_km)
	var cost := INF
	if cell_land[first_index] != 0 and cell_land[last_index] != 0:
		var a: Vector2 = Vector2(first_cell) * step_km
		var b: Vector2 = Vector2(last_cell) * step_km
		var middle_index: int = _cell_data(Vector2i(roundi((a.x + b.x) * 0.5 / step_km), roundi((a.y + b.y) * 0.5 / step_km)))
		if middle_index >= 0 and cell_land[middle_index] != 0:
			var maximum := 0.0
			var previous: float = cell_height_m[first_index]
			var water_length := 0.0
			var longest_water := 0.0
			var parts: int = maxi(2, ceili(a.distance_to(b)))
			for part in range(1, parts + 1):
				var point: Vector2 = a.lerp(b, float(part) / float(parts))
				var height: float = region.terrain.elevation_at(point)
				maximum = maxf(maximum, absf(height - previous) / (a.distance_to(b) * 1000.0 / float(parts)))
				previous = height
				water_length = water_length + a.distance_to(b) / float(parts) if region.terrain.water_at(point) else 0.0
				longest_water = maxf(longest_water, water_length)
			if maximum <= grade_limit * 1.25 and longest_water <= 2.0:
				cost = Vector2(first_cell - last_cell).length() * step_km * (1.0 + maximum * maximum * 180.0 + (cell_slope[first_index] + cell_slope[last_index]) * 2.0) + longest_water * 8.0
				if valley_weight > 0.0:
					var relief: float = maxf(0.0, (cell_height_m[first_index] + cell_height_m[last_index]) * 0.5 - minf(_valley_floor(first_cell), _valley_floor(last_cell)))
					cost += valley_weight * (a.distance_to(b) * minf(2.0, relief / 400.0) + absf(cell_height_m[last_index] - cell_height_m[first_index]) * 0.008)
	edge_costs[slot] = cost
	edge_computed[slot] = 1
	var reverse_slot: int = last_index * 8 + (direction + 4) % 8
	edge_costs[reverse_slot] = cost
	edge_computed[reverse_slot] = 1
	return cost + _avoid_penalty_km(Vector2(first_cell) * step_km, Vector2(last_cell) * step_km)


func _search(first: Vector2, last: Vector2, road_class: String, start_tangent: Vector2, long_range: bool = false) -> Dictionary:
	var start_cell := Vector2i(roundi(first.x / step_km), roundi(first.y / step_km))
	var goal := Vector2i(roundi(last.x / step_km), roundi(last.y / step_km))
	if start_cell == goal:
		return {"points": PackedVector2Array([first, last]), "tunnels": []}
	var highway: bool = road_class == Roads.HIGHWAY
	var grade_limit: float = 0.06 if highway else 0.08
	var max_turn: int = 1 if highway else 2
	var turn_weight: float = step_km * (0.6 if highway else 0.18)
	var tunnel_grade: float = 0.04 if highway else 0.06
	var expansion_budget: int = 16000 if step_km > 1.0 else 7500
	# Hopeless searches would explore the whole block before failing; abort
	# once the best remaining path cannot beat a generous detour multiple.
	var coarse: bool = step_km > 1.0
	var cost_ceiling: float = first.distance_to(last) * (4.0 if coarse else 3.2) + (15.0 if coarse else 12.0)
	if long_range:
		# Settlement-rescue routes can span a hundred kilometres of mountains;
		# the hop-sized budget above gives up before crossing the range.
		expansion_budget = 32000
		cost_ceiling = first.distance_to(last) * 4.5 + 20.0
	if corridor_search:
		expansion_budget = 180000
		cost_ceiling = first.distance_to(last) * 12.0 + 100.0
	var padding: float = maxf(24.0, first.distance_to(last) * (0.8 if generated_highway else 0.4))
	var rect := Rect2(first.min(last), (last - first).abs()).grow(padding)
	block_x0 = maxi(origin_cell.x, floori(rect.position.x / step_km))
	block_y0 = maxi(origin_cell.y, floori(rect.position.y / step_km))
	block_width = mini(origin_cell.x + field_width, floori(rect.end.x / step_km) + 1) - block_x0
	var block_height: int = mini(origin_cell.y + field_height, floori(rect.end.y / step_km) + 1) - block_y0
	if block_width <= 0 or block_height <= 0:
		return {}
	var state_count: int = block_width * block_height * HEADINGS
	search_costs.resize(state_count)
	search_costs.fill(INF)
	search_parents.resize(state_count)
	search_parents.fill(-1)
	search_tunnel_marks.resize(state_count)
	search_tunnel_marks.fill(0)
	search_closed.resize(state_count)
	search_closed.fill(0)
	heap_size = 0
	var heading := -1
	if start_tangent != Vector2.ZERO:
		heading = posmod(roundi(start_tangent.angle() / (PI * 0.25)), 8)
	var start_state: int = _state_index(start_cell, heading)
	search_costs[start_state] = 0.0
	_heap_push(start_state, first.distance_to(last))
	var found := -1
	var expansions := 0
	while heap_size > 0:
		if heap_priorities[0] > cost_ceiling:
			break
		var current: int = _heap_pop()
		if search_closed[current] != 0:
			continue
		search_closed[current] = 1
		var cell := _state_cell(current)
		if cell == goal:
			found = current
			break
		expansions += 1
		if expansions > expansion_budget:
			break
		var heading_slot: int = current % HEADINGS - 1
		var prior_tunnel: bool = search_tunnel_marks[current] != 0
		var cell_index: int = _cell_data(cell)
		if cell_index < 0:
			continue
		var cell_dry: bool = cell_water[cell_index] == 0
		var slope_here: float = cell_slope[cell_index]
		for direction in range(8):
			var turn := 0
			if heading_slot >= 0:
				turn = mini(absi(direction - heading_slot), 8 - absi(direction - heading_slot))
			if turn > max_turn or (prior_tunnel and turn != 0):
				continue
			var other: Vector2i = cell + DIRECTIONS[direction]
			if other.x < block_x0 or other.y < block_y0 or other.x >= block_x0 + block_width or other.y >= block_y0 + block_height:
				continue
			var other_index: int = _cell_data(other)
			if other_index < 0 or cell_land[other_index] == 0:
				continue
			var step_cost: float = _travel_cost(cell, other, direction, grade_limit)
			var other_state: int = _state_index(other, direction)
			if step_cost < INF and search_costs[current] + step_cost + float(turn * turn) * turn_weight < search_costs[other_state]:
				_relax(other_state, current, search_costs[current] + step_cost + float(turn * turn) * turn_weight, false, other, goal)
			# Tunnels continue the approach heading and emerge on dry ground.
			if tunnel_limit_km <= 0.0 or heading_slot != direction or not cell_dry or slope_here > 0.15 or (step_cost < INF and slope_here < 0.04):
				continue
			for span_cells in range(2, floori(tunnel_limit_km / (Vector2(DIRECTIONS[direction]).length() * step_km)) + 1, (1 if generated_highway else maxi(1, roundi(4.0 / step_km)))):
				var exit_cell: Vector2i = cell + DIRECTIONS[direction] * span_cells
				if exit_cell == goal or cell == start_cell or exit_cell.x < block_x0 or exit_cell.y < block_y0 or exit_cell.x >= block_x0 + block_width or exit_cell.y >= block_y0 + block_height:
					continue
				var tunnel_cost: float = _tunnel_cost(cell, exit_cell, tunnel_grade)
				if tunnel_cost >= INF:
					continue
				var exit_state: int = _state_index(exit_cell, direction)
				var tunnel_candidate: float = search_costs[current] + tunnel_cost
				if tunnel_candidate < search_costs[exit_state]:
					_relax(exit_state, current, tunnel_candidate, true, exit_cell, goal)
	if found < 0:
		return {}
	var trace := PackedVector2Array([Vector2(goal) * step_km])
	var tunnels: Array[Dictionary] = []
	var cursor: int = found
	while search_parents[cursor] >= 0:
		var previous: int = search_parents[cursor]
		var point: Vector2 = Vector2(_state_cell(cursor)) * step_km
		var before: Vector2 = Vector2(_state_cell(previous)) * step_km
		if trace[-1].distance_to(point) > 0.01:
			trace.append(point)
		if search_tunnel_marks[cursor] != 0:
			tunnels.append({"from": before, "to": point})
		cursor = previous
	var grid_start: Vector2 = Vector2(start_cell) * step_km
	if trace[-1].distance_to(grid_start) > 0.01:
		trace.append(grid_start)
	trace.reverse()
	trace[0] = first
	trace[-1] = last
	return {"points": trace, "tunnels": tunnels}


func _state_index(cell: Vector2i, heading: int) -> int:
	return ((cell.y - block_y0) * block_width + (cell.x - block_x0)) * HEADINGS + heading + 1


func _state_cell(state: int) -> Vector2i:
	var cell_slot: int = state / HEADINGS
	return Vector2i(block_x0 + cell_slot % block_width, block_y0 + cell_slot / block_width)


func _relax(state: int, parent: int, cost: float, tunnel: bool, cell: Vector2i, goal: Vector2i) -> void:
	search_costs[state] = cost
	search_parents[state] = parent
	search_tunnel_marks[state] = 1 if tunnel else 0
	_heap_push(state, cost + _heuristic(cell, goal))


func _heuristic(cell: Vector2i, goal: Vector2i) -> float:
	var dx: int = absi(cell.x - goal.x)
	var dy: int = absi(cell.y - goal.y)
	return (maxf(dx, dy) + 0.41421356 * minf(dx, dy)) * step_km


func _heap_push(state: int, priority: float) -> void:
	if heap_size == heap_states.size():
		heap_states.resize(heap_size + 256)
		heap_priorities.resize(heap_size + 256)
	heap_states[heap_size] = state
	heap_priorities[heap_size] = priority
	var child := heap_size
	heap_size += 1
	while child > 0:
		var parent_index: int = (child - 1) / 2
		if heap_priorities[parent_index] <= heap_priorities[child]:
			break
		var moved_state: int = heap_states[parent_index]
		var moved_priority: float = heap_priorities[parent_index]
		heap_states[parent_index] = heap_states[child]
		heap_priorities[parent_index] = heap_priorities[child]
		heap_states[child] = moved_state
		heap_priorities[child] = moved_priority
		child = parent_index


func _heap_pop() -> int:
	var root: int = heap_states[0]
	heap_size -= 1
	if heap_size == 0:
		return root
	var last_state: int = heap_states[heap_size]
	var last_priority: float = heap_priorities[heap_size]
	var sift := 0
	while true:
		var left: int = sift * 2 + 1
		if left >= heap_size:
			break
		var right: int = left + 1
		var smaller: int = right if right < heap_size and heap_priorities[right] < heap_priorities[left] else left
		if heap_priorities[smaller] >= last_priority:
			break
		heap_states[sift] = heap_states[smaller]
		heap_priorities[sift] = heap_priorities[smaller]
		sift = smaller
	heap_states[sift] = last_state
	heap_priorities[sift] = last_priority
	return root


func _tunnel_cost(first: Vector2i, last: Vector2i, grade_limit: float) -> float:
	var key := Vector4i(first.x, first.y, last.x, last.y)
	if tunnel_cache.has(key):
		var cached: Vector2 = tunnel_cache[key]
		return cached.x if cached.y <= grade_limit else INF
	var result: Vector2 = _measure_tunnel(first, last)
	tunnel_cache[key] = result
	return result.x if result.y <= grade_limit else INF


func _measure_tunnel(first: Vector2i, last: Vector2i) -> Vector2:
	var a_index: int = _cell_data(first)
	var b_index: int = _cell_data(last)
	if a_index < 0 or b_index < 0:
		return Vector2(INF, INF)
	var a_height: float = cell_height_m[a_index]
	var b_height: float = cell_height_m[b_index]
	var distance: float = Vector2(last - first).length() * step_km
	var grade: float = absf(a_height - b_height) / (distance * 1000.0)
	if cell_land[b_index] == 0 or cell_water[b_index] != 0 or cell_slope[b_index] > 0.15 or grade > 0.06:
		return Vector2(INF, INF)
	var cover := 0.0
	for index in range(1, 8):
		var t: float = float(index) / 8.0
		var point: Vector2 = (Vector2(first).lerp(Vector2(last), t)) * step_km
		if not region.jurisdictions[0].contains_point(point) or region.terrain.water_at(point):
			return Vector2(INF, INF)
		var depth: float = region.terrain.elevation_at(point) - lerpf(a_height, b_height, t)
		if depth < -5.0:
			return Vector2(INF, INF)
		cover = maxf(cover, depth)
	return Vector2(distance * 7.0 + 8.0, grade) if cover >= 60.0 else Vector2(INF, INF)


func _smooth(trace: PackedVector2Array, road_class: String, tunnels: Array, broad_radius: float = 0.0) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point in trace:
		if points.is_empty() or points[-1].distance_to(point) > 0.01:
			points.append(point)
	for index in range(points.size() - 2, 0, -1):
		var portal := false
		for tunnel in tunnels:
			portal = portal or points[index].distance_to(tunnel["from"]) < 0.01 or points[index].distance_to(tunnel["to"]) < 0.01
		if not portal and (points[index] - points[index - 1]).normalized().dot((points[index + 1] - points[index]).normalized()) > 0.99999:
			points.remove_at(index)
	if points.size() < 2:
		return PackedVector2Array()
	var result := PackedVector2Array([points[0]])
	for index in range(1, points.size() - 1):
		var point: Vector2 = points[index]
		var incoming: Vector2 = (point - points[index - 1]).normalized()
		var outgoing: Vector2 = (points[index + 1] - point).normalized()
		var turn: float = acos(clampf(incoming.dot(outgoing), -1.0, 1.0))
		var portal := false
		for tunnel in tunnels:
			portal = portal or point.distance_to(tunnel["from"]) < 0.01 or point.distance_to(tunnel["to"]) < 0.01
		if turn < 0.01 or portal:
			_append_line(result, point)
			continue
		if turn > PI * 0.90:
			return PackedVector2Array()
		var adjacent: float = minf(point.distance_to(points[index - 1]), point.distance_to(points[index + 1]))
		var minimum: float = 2.1 if road_class == Roads.HIGHWAY else (0.4 if road_class == Roads.ARTERIAL else 0.15)
		var radius: float = maxf(minimum, minf(broad_radius, adjacent * 0.7)) if broad_radius > 0.0 else maxf(minimum, minf(1.4, adjacent * 0.35))
		var trim: float = radius * tan(turn * 0.5)
		if trim > adjacent * 0.45:
			trim = adjacent * 0.45
			radius = trim / tan(turn * 0.5)
			if road_class == Roads.HIGHWAY and radius < minimum:
				return PackedVector2Array()
		var a: Vector2 = point - incoming * trim
		var b: Vector2 = point + outgoing * trim
		_append_line(result, a)
		_arc(result, a, b, incoming, outgoing, radius)
	_append_line(result, points[-1])
	for index in range(1, result.size()):
		if not _segment_on_land(result[index - 1], result[index]):
			return PackedVector2Array()
	return result


# Fast coast check: trust the cell field when a 1-cell band around the segment
# is solid land; fall back to the exact polygon test near any water or edge.
func _segment_on_land(first: Vector2, last: Vector2) -> bool:
	var distance: float = first.distance_to(last)
	var samples: int = maxi(2, ceili(distance / (step_km * 0.5)))
	for index in range(samples + 1):
		var point: Vector2 = first.lerp(last, float(index) / float(samples))
		var cell := Vector2i(roundi(point.x / step_km), roundi(point.y / step_km))
		for offset_y in range(-1, 2):
			for offset_x in range(-1, 2):
				var neighbor_index: int = _cell_data(cell + Vector2i(offset_x, offset_y))
				if neighbor_index < 0 or cell_land[neighbor_index] == 0:
					return Geography.segment_on_land(region.jurisdictions[0].polygon_km, first, last)
	return true


static func _append_line(points: PackedVector2Array, last: Vector2) -> void:
	var first: Vector2 = points[-1]
	var parts: int = maxi(1, ceili(first.distance_to(last) / 0.5))
	for index in range(1, parts + 1):
		var point: Vector2 = first.lerp(last, float(index) / float(parts))
		if points[-1].distance_to(point) > 0.00001:
			points.append(point)


static func _bezier(points: PackedVector2Array, a: Vector2, b: Vector2, c: Vector2, d: Vector2, depth: int) -> void:
	var error: float = maxf(b.distance_to(Geometry2D.get_closest_point_to_segment(b, a, d)), c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, d)))
	if error <= 0.002 or depth >= 12:
		points.append(d)
		return
	var ab: Vector2 = (a + b) * 0.5
	var bc: Vector2 = (b + c) * 0.5
	var cd: Vector2 = (c + d) * 0.5
	var left: Vector2 = (ab + bc) * 0.5
	var right: Vector2 = (bc + cd) * 0.5
	var middle: Vector2 = (left + right) * 0.5
	_bezier(points, a, ab, left, middle, depth + 1)
	_bezier(points, middle, right, cd, d, depth + 1)


# Exact circular-arc sampling for smoothing bends: a cubic Bezier
# approximation of the same arc undershoots the target radius by a few
# percent, which the curve-radius checks in the specs are written against.
static func _arc(points: PackedVector2Array, a: Vector2, b: Vector2, incoming: Vector2, outgoing: Vector2, radius: float) -> void:
	var side: float = signf(incoming.cross(outgoing))
	if side == 0.0 or a.distance_to(b) < 0.0001:
		points.append(b)
		return
	var center: Vector2 = a - incoming.orthogonal() * side * radius
	if absf(center.distance_to(b) - radius) > maxf(0.01, radius * 0.01) or signf((b - center).cross(outgoing)) != side:
		var handle: float = radius * 4.0 / 3.0 * tan(acos(clampf(incoming.dot(outgoing), -1.0, 1.0)) * 0.25)
		_bezier(points, a, a + incoming * handle, b - outgoing * handle, b, 0)
		return
	var start: float = (a - center).angle()
	var finish: float = (b - center).angle()
	var delta: float = fposmod((finish - start) * side, TAU)
	if delta > PI:
		delta -= TAU
	var limit: float = 2.0 * acos(clampf(1.0 - 0.002 / radius, -1.0, 1.0))
	var pieces: int = maxi(1, ceili(absf(delta) / maxf(limit, 0.02)))
	for piece in range(1, pieces):
		points.append(center + Vector2.from_angle(start + side * delta * float(piece) / float(pieces)) * radius)
	points.append(b)


func _profile(points: PackedVector2Array, road_class: String, tunnels: Array) -> Dictionary:
	var heights := PackedFloat32Array()
	var kinds := PackedStringArray()
	var limit: float = 0.06 if road_class == Roads.HIGHWAY else 0.08
	for point in points:
		var height: float = region.terrain.elevation_at(point)
		var kind: String = "Bridge" if region.terrain.water_at(point) else ""
		for tunnel in tunnels:
			var a: Vector2 = tunnel["from"]
			var b: Vector2 = tunnel["to"]
			var near: Vector2 = Geometry2D.get_closest_point_to_segment(point, a, b)
			if near.distance_to(point) < 0.01:
				height = lerpf(region.terrain.elevation_at(a), region.terrain.elevation_at(b), a.distance_to(near) / a.distance_to(b))
				kind = "Tunnel"
				break
		heights.append(height)
		kinds.append(kind)
	# Grade the road bed through small noise and river-bank discontinuities.
	var ground: PackedFloat32Array = heights.duplicate()
	for _pass_index in range(3):
		for index in range(1, heights.size()):
			var rise: float = points[index - 1].distance_to(points[index]) * 1000.0 * limit
			heights[index] = clampf(heights[index], heights[index - 1] - rise, heights[index - 1] + rise)
		for index in range(heights.size() - 2, -1, -1):
			var rise: float = points[index + 1].distance_to(points[index]) * 1000.0 * limit
			heights[index] = clampf(heights[index], heights[index + 1] - rise, heights[index + 1] + rise)
	for index in range(points.size()):
		if kinds[index] == "" and absf(heights[index] - ground[index]) > 55.0:
			return {}
		if kinds[index] == "" and absf(heights[index] - ground[index]) > 3.0:
			kinds[index] = "Earthwork"
	var spans: Array[Dictionary] = []
	var length := 0.0
	for index in range(1, points.size()):
		var distance: float = points[index - 1].distance_to(points[index])
		length += distance
		var kind: String = kinds[index] if kinds[index] != "" else kinds[index - 1]
		if kind == "":
			continue
		if not spans.is_empty() and spans[-1]["kind"] == kind and spans[-1]["to"].distance_to(points[index - 1]) < 0.001:
			spans[-1]["points"].append(points[index])
			spans[-1]["elevations_m"].append(heights[index])
			spans[-1]["to"] = points[index]
			spans[-1]["length_km"] += distance
		else:
			spans.append({"kind": kind, "from": points[index - 1], "to": points[index], "points": PackedVector2Array([points[index - 1], points[index]]), "elevations_m": PackedFloat32Array([heights[index - 1], heights[index]]), "length_km": distance})
	var tunnel_total := 0.0
	for span in spans:
		if span.kind == "Bridge" and float(span.length_km) > 2.0:
			return {}
		if span.kind == "Tunnel":
			tunnel_total += float(span.length_km)
			if generated_highway and float(span.length_km) > 3.05:
				return {}
	if generated_highway and tunnel_total > length * 0.05:
		return {}
	return {"points": points, "elevations_m": heights, "terrain_spans": spans, "length_km": length}


func _valley_floor(cell: Vector2i) -> float:
	if valley_heights.has(cell): return valley_heights[cell]
	var low := INF
	var stride: int = maxi(1, roundi(16.0 / step_km))
	for y in [-stride, 0, stride]:
		for x in [-stride, 0, stride]:
			var index := _cell_data(cell + Vector2i(x,y))
			if index >= 0 and cell_land[index] != 0 and cell_water[index] == 0:
				low = minf(low, cell_height_m[index])
	valley_heights[cell] = low
	return low


func plan_corridor(first: Vector2, last: Vector2) -> Dictionary:
	if not generated_highway or valley_weight != 1.5: edge_computed.fill(0)
	generated_highway = true
	corridor_search = true
	tunnel_limit_km = 0.0
	valley_weight = 1.5
	avoid_endpoints = [first, last]
	var trace := _search(first, last, Roads.HIGHWAY, Vector2.ZERO, true)
	if trace.is_empty():
		# A steeper macro guide may locate a saddle or a short tunnel opportunity.
		# Detailed highway profiling still enforces highway grades and limits.
		edge_computed.fill(0)
		trace = _search(first, last, Roads.ARTERIAL, Vector2.ZERO, true)
		edge_computed.fill(0)
	if trace.is_empty(): return {}
	var cost := 0.0
	var points: PackedVector2Array = trace.points
	for index in range(1, points.size()):
		var a := Vector2i((points[index-1] / step_km).round())
		var b := Vector2i((points[index] / step_km).round())
		cost += points[index-1].distance_to(points[index]) + absf(region.terrain.elevation_at(points[index]) - region.terrain.elevation_at(points[index-1])) * 0.012
		cost += points[index-1].distance_to(points[index]) * maxf(0.0, region.terrain.elevation_at(points[index]) - minf(_valley_floor(a), _valley_floor(b))) / 400.0
	trace["cost"] = cost
	return trace


func align_corridor(guide: PackedVector2Array) -> Dictionary:
	generated_highway = true
	tunnel_limit_km = 0.0
	valley_weight = 1.5
	# The coarse guide is often already a valid surface alignment.
	for radius in [24.0, 8.0, 0.0]:
		var smooth := _smooth(guide, Roads.HIGHWAY, [], radius)
		if not smooth.is_empty():
			var direct := _profile(smooth, Roads.HIGHWAY, [])
			if not direct.is_empty(): return direct
	# Refine bounded windows. No partial route is published if a window fails.
	var anchors := PackedInt32Array([0])
	var distance := 0.0
	for i in range(1, guide.size()):
		distance += guide[i-1].distance_to(guide[i])
		if distance >= 120.0 and i < guide.size()-2:
			anchors.append(i)
			distance = 0.0
	anchors.append(guide.size()-1)
	var combined := PackedVector2Array()
	var tunnels: Array[Dictionary] = []
	for i in range(1, anchors.size()):
		var first: int = anchors[i-1]
		var last: int = anchors[i]
		var incoming := Vector2.ZERO if first == 0 else (guide[first+1] - guide[first-1]).normalized()
		var outgoing := Vector2.ZERO if last == guide.size()-1 else (guide[last+1] - guide[last-1]).normalized()
		var part: Dictionary = route(guide[first], guide[last], Roads.HIGHWAY, incoming, outgoing, true, false)
		if part.is_empty():
			part = route(guide[first], guide[last], Roads.HIGHWAY, incoming, outgoing, false, true)
		if part.is_empty():
			var tunnel_planner = get_script().new(region, 1.0)
			tunnel_planner.generated_highway = true
			tunnel_planner.valley_weight = 1.5
			tunnel_planner.tunnel_limit_km = 3.0
			part = tunnel_planner.route(guide[first], guide[last], Roads.HIGHWAY, incoming, outgoing, false, true)
		if part.is_empty(): return {}
		combined.append_array(part.points if combined.is_empty() else part.points.slice(1))
		for span in part.terrain_spans:
			if span.kind == "Tunnel": tunnels.append({"from":span.from, "to":span.to})
	return _profile(combined, Roads.HIGHWAY, tunnels)
