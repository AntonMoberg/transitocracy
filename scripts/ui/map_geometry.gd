extends RefCounted
## Pure CPU geometry preparation. Inputs are owned snapshots, never scene nodes.
const Style = preload("res://scripts/ui/map_style.gd")
const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const GRID = 64
const MAX_VERTICES = 12288

static func building_parts(feature:Dictionary) -> Array:
	var parts:Array=[]
	for polygon in feature.footprints:
		parts.append({"polygon":polygon,"indices":Geometry2D.triangulate_polygon(polygon),"color":Color("cdd1dc",.85)})
		for inset in Geometry2D.offset_polygon(polygon,-.00018):
			parts.append({"polygon":inset,"indices":Geometry2D.triangulate_polygon(inset),"color":Color("f3f2f1",.8) if feature.constructing else feature.color})
	return parts

static func bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var result := Rect2(points[0], Vector2.ZERO)
	for point in points:
		result = result.expand(point)
	return result

static func index_source(source: Dictionary) -> Dictionary:
	# A narrow land-cover skirt closes street-width gaps between completed
	# blocks. It never includes undeveloped administrative city polygons.
	for feature in source.features:
		if feature.get("urban_fill", false):
			var expanded: Array[PackedVector2Array] = Geometry2D.offset_polygon(feature.points, 0.012)
			if not expanded.is_empty(): feature.points = expanded[0]
	_prepare_junctions_and_crossings(source)
	preload("res://scripts/ui/street_detail_geometry.gd").prepare(source)
	var prepared:Dictionary={}
	var prepared_bytes:=0
	for feature in source.features:
		if feature.kind!="building_inventory": continue
		var stamp:int=hash([feature.footprints,feature.color,feature.constructing])
		var old:Dictionary=source.get("prepared_buildings",{}).get(feature.identity,{})
		var parts:Array=[]
		if old.get("stamp",0)==stamp: parts=old.parts
		else: parts=building_parts(feature)
		var bytes:=0
		for part in parts: bytes+=part.polygon.size()*8+part.indices.size()*4
		if prepared_bytes+bytes<=64*1024*1024:
			feature["render_parts"]=parts
			prepared[feature.identity]={"stamp":stamp,"parts":parts}
			prepared_bytes+=bytes
	source["prepared_buildings"]=prepared
	source["prepared_building_bytes"]=prepared_bytes
	var grid := {}
	var fingerprints := {}
	var changed := {}
	var previous: Dictionary = source.get("previous", {})
	var extent: Rect2 = source.bounds
	for i in range(source.features.size()):
		var feature: Dictionary = source.features[i]
		feature["bounds"] = bounds(feature.points).grow(0.04)
		var identity: String = feature.get("identity", "%s:%d" % [feature.layer, i])
		var fingerprint: int = hash(feature)
		fingerprints[identity] = {"hash": fingerprint, "bounds": feature.bounds, "layer": feature.layer}
		if not previous.has(identity) or previous[identity].hash != fingerprint:
			if not changed.has(feature.layer):
				changed[feature.layer] = []
			changed[feature.layer].append(feature.bounds)
			if previous.has(identity):
				changed[feature.layer].append(previous[identity].bounds)
		var first: Vector2i = cell(feature.bounds.position, extent)
		var last: Vector2i = cell(feature.bounds.end, extent)
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				var key := Vector2i(x, y)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(i)
	for identity in previous:
		if not fingerprints.has(identity):
			var old: Dictionary = previous[identity]
			if not changed.has(old.layer):
				changed[old.layer] = []
			changed[old.layer].append(old.bounds)
	source.erase("previous")
	source["fingerprints"] = fingerprints
	source["changed"] = changed
	source["grid"] = grid
	return source

static func cell(point: Vector2, extent: Rect2) -> Vector2i:
	var relative: Vector2 = (point - extent.position) / extent.size * GRID
	return Vector2i(clampi(floori(relative.x), 0, GRID - 1), clampi(floori(relative.y), 0, GRID - 1))

static func query(source: Dictionary, rect: Rect2) -> Array:
	var first := cell(rect.position, source.bounds)
	var last := cell(rect.end, source.bounds)
	var seen := {}
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for id in source.grid.get(Vector2i(x, y), []):
				if source.features[id].bounds.intersects(rect):
					seen[id] = true
	var ids := seen.keys()
	ids.sort()
	return ids

static func tile_rect(extent: Rect2, key: Vector3i) -> Rect2:
	var width: float = extent.size.x / pow(2.0, key.x)
	return Rect2(extent.position + Vector2(key.y, key.z) * width, Vector2.ONE * width)

static func build_batch(source: Dictionary, jobs: Array) -> Dictionary:
	var results: Array = []
	for job in jobs:
		results.append(build(source, job.key, job.layer))
	return {"results": results}

static func build(source: Dictionary, key: Vector3i, layer: String) -> Dictionary:
	var rect := tile_rect(source.bounds, key)
	var ppk: float = 512.0 / rect.size.x
	var chunks: Array = []
	var buffer := new_buffer()
	var count := 0
	var streets := 0
	var districts := 0
	# Clip in the fragment shader, retaining original joins and junction endpoints.
	# The buffer is split into small uploads, including within a single feature.
	for id in query(source, rect.grow(24.0 / ppk)):
		var feature: Dictionary = source.features[id]
		if feature.layer != layer or float(feature.get("min_ppk", 0.0)) > ppk * 2.0:
			continue
		if feature.get("local", false):
			streets += 1
		if str(feature.get("identity", "")).begins_with("border:") and float(feature.get("min_ppk", 0.0)) >= 25.0:
			districts += 1
		buffer["style"] = feature.get("style", Style.RoadStyle.HIGHWAY if feature.get("highway", false) else Style.RoadStyle.ARTERIAL)
		buffer["fade"] = feature.get("fade", Vector2(float(feature.get("min_ppk", 0.0)), float(feature.get("min_ppk", 0.0)) * 1.1))
		if feature.kind == "line":
			if not buffer.get("line", false) and not buffer.vertices.is_empty():
				flush(buffer, chunks)
			buffer["line"] = true
			var points: PackedVector2Array = simplify(feature.points, 0.65 / ppk, feature.get("fixed", PackedInt32Array()))
			var slot: int = feature.get("slot", -1)
			var width: float = feature.get("meters", 0.0)
			var pixel_width: float = feature.get("pixels", 1.0)
			if layer == "roads" or feature.get("elevated", false):
				var lanes: int = feature.get("lanes", 1)
				var highway: bool = feature.get("highway", false)
				var lane_m: float = 3.6 if highway else 3.25
				var median_m: float = 1.5 if highway else 0.35
				if feature.get("elevated", false):
					append_line(buffer, chunks, points, rect, Color(lanes * lane_m + median_m + 3.0, 4.5, -2.0, 0.0))
				var local: bool = feature.get("local", false)
				var body_min: float = 0.5 if local else (1.55 if highway else (0.7 if int(buffer.style) == Style.RoadStyle.COLLECTOR else 1.0))
				var road_half_m: float = preload("res://scripts/simulation/street_cross_section.gd").carriageway("Highway" if highway else "Local",lanes)*.5
				# A continuous road bed remains visible at every scale. Individual
				# lanes only appear when their physical widths are resolvable.
				append_line(buffer, chunks, points, rect, Color(road_half_m + (2.0 if highway else 0.8), body_min + (0.35 if local else 0.45), slot + 1, 1.0))
				append_line(buffer, chunks, points, rect, Color(road_half_m, body_min, slot + 1, 4.0))
				if ppk >= 500.0 and not local:
					for direction in range(2):
						for lane in range(lanes):
							var offset: float = (median_m + lane_m * (lane + 0.5)) * (-1.0 if direction == 0 else 1.0)
							append_line(buffer, chunks, points, rect, Color(lane_m * 0.43, 0.0, slot + 1, 2.0 + direction), offset)
					flush(buffer, chunks)
					buffer["line"] = false
					append_arrows(buffer, chunks, points, rect, ppk, lanes, highway)
			else:
				var widths = feature.get("widths", [])
				if layer == "water" and widths.size() == feature.points.size():
					for segment in range(1, feature.points.size()):
						var river_width: float = (widths[segment - 1] + widths[segment]) * 0.5
						buffer["fade"] = Style.river_range(river_width)
						append_line(buffer, chunks, PackedVector2Array([feature.points[segment - 1], feature.points[segment]]), rect, Color(river_width * 500.0, 0.35, slot + 1, 0.0))
				else:
					append_line(buffer, chunks, points, rect, Color(width * 0.5, pixel_width * 0.5, slot + 1, 0.0))
		elif feature.kind == "block":
			if buffer.get("line", false) and not buffer.vertices.is_empty():
				flush(buffer, chunks)
			buffer["line"] = false
			append_polygon(buffer, chunks, feature.points, feature.color, rect)
		elif feature.kind == "buildings":
			var buildings: Array = ParcelGeometry.buildings(feature.block, feature.zone, feature.density, feature.character, source.terrain)
			for building_id in range(buildings.size()):
				if float(posmod(int(feature.block.seed) + building_id * 7919, 1000)) / 1000.0 > float(feature.developed):
					continue
				var polygon: PackedVector2Array = buildings[building_id]
				if not bounds(polygon).intersects(rect) or RoadLand.polygon_intersects_masks(polygon, feature.masks):
					continue
				append_polygon(buffer, chunks, polygon, feature.color, rect)
				count += 1
		elif feature.kind == "building_inventory":
			var render_parts:Array=feature.render_parts if feature.has("render_parts") else building_parts(feature)
			for part in render_parts:
				if bounds(part.polygon).intersects(rect): append_polygon(buffer,chunks,part.polygon,part.color,rect,part.indices)
			count+=feature.footprints.size()
	flush(buffer, chunks)
	return {"key": key, "layer": layer, "parts": chunks, "buildings": count, "streets": streets, "districts": districts, "epoch": source.epoch}

static func new_buffer() -> Dictionary:
	return {"vertices": PackedVector2Array(), "uv": PackedVector2Array(), "colors": PackedColorArray(), "sides": PackedFloat32Array(), "styles": PackedFloat32Array()}

static func flush(buffer: Dictionary, chunks: Array) -> void:
	if buffer.vertices.is_empty():
		return
	chunks.append(buffer.duplicate())
	buffer.vertices = PackedVector2Array()
	buffer.uv = PackedVector2Array()
	buffer.colors = PackedColorArray()
	buffer.sides = PackedFloat32Array()
	buffer.styles = PackedFloat32Array()

static func emit_triangle(buffer: Dictionary, chunks: Array, points: Array, normals: Array, color: Color, sides: Array = []) -> void:
	for i in range(3):
		buffer.vertices.append(points[i])
		buffer.uv.append(normals[i])
		buffer.colors.append(color)
		var side: float = float(sides[i]) if not sides.is_empty() else 0.0
		buffer.sides.append(side)
		var fade: Vector2 = buffer.get("fade", Vector2.ZERO)
		buffer.styles.append(side)
		buffer.styles.append(float(buffer.get("style", 0)))
		buffer.styles.append(fade.x)
		buffer.styles.append(fade.y)
	if buffer.vertices.size() >= MAX_VERTICES:
		flush(buffer, chunks)

static func normal(points: PackedVector2Array, i: int) -> Vector2:
	var before := (points[i] - points[maxi(0, i - 1)]).normalized()
	var after := (points[mini(points.size() - 1, i + 1)] - points[i]).normalized()
	if before == Vector2.ZERO:
		before = after
	if after == Vector2.ZERO:
		after = before
	var bisector := (before.orthogonal() + after.orthogonal()).normalized()
	return after.orthogonal() if bisector == Vector2.ZERO else bisector / maxf(0.35, bisector.dot(after.orthogonal()))

static func append_line(buffer: Dictionary, chunks: Array, points: PackedVector2Array, rect: Rect2, color: Color, offset_m: float = 0.0) -> void:
	var expanded := rect.grow(maxf(0.04, rect.size.x * 0.05))
	for i in range(1, points.size()):
		if not Rect2(points[i - 1], Vector2.ZERO).expand(points[i]).grow(expanded.size.x * 0.001).intersects(expanded):
			continue
		var a_normal := normal(points, i - 1)
		var b_normal := normal(points, i)
		var a: Vector2 = points[i - 1] + a_normal * offset_m * 0.001
		var b: Vector2 = points[i] + b_normal * offset_m * 0.001
		emit_triangle(buffer, chunks, [a, a, b], [-a_normal, a_normal, b_normal], color, [-1.0, 1.0, 1.0])
		emit_triangle(buffer, chunks, [a, b, b], [-a_normal, b_normal, -b_normal], color, [-1.0, 1.0, -1.0])

static func append_polygon(buffer: Dictionary, chunks: Array, polygon: PackedVector2Array, color: Color, rect: Rect2, prepared:PackedInt32Array=PackedInt32Array()) -> void:
	# Clip triangles, not concave polygons, so disconnected pieces remain valid.
	var indices := prepared if not prepared.is_empty() else Geometry2D.triangulate_polygon(polygon)
	for i in range(0, indices.size(), 3):
		var triangle := PackedVector2Array([polygon[indices[i]], polygon[indices[i + 1]], polygon[indices[i + 2]]])
		var clipped := clip_polygon(triangle, rect)
		for j in range(1, clipped.size() - 1):
			emit_triangle(buffer, chunks, [clipped[0], clipped[j], clipped[j + 1]], [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO], color)

static func clip_polygon(polygon: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	for axis in range(2):
		for upper in [false, true]:
			if polygon.is_empty():
				return polygon
			var boundary: float = rect.end[axis] if upper else rect.position[axis]
			var output := PackedVector2Array()
			var previous := polygon[-1]
			var was_inside: bool = previous[axis] <= boundary if upper else previous[axis] >= boundary
			for point in polygon:
				var inside: bool = point[axis] <= boundary if upper else point[axis] >= boundary
				if inside != was_inside:
					output.append(previous.lerp(point, (boundary - previous[axis]) / (point[axis] - previous[axis])))
				if inside:
					output.append(point)
				previous = point
				was_inside = inside
			polygon = output
	return polygon

static func simplify(points: PackedVector2Array, tolerance: float, fixed: PackedInt32Array = PackedInt32Array()) -> PackedVector2Array:
	# Iterative Douglas-Peucker; endpoints are invariant across adjacent tiles.
	if points.size() < 3:
		return points
	var keep := {0: true, points.size() - 1: true}
	var boundaries: Array[int] = [0]
	for index in fixed:
		if index > 0 and index < points.size() - 1:
			keep[index] = true
			boundaries.append(index)
	boundaries.append(points.size() - 1)
	boundaries.sort()
	var stack: Array[Vector2i] = []
	for i in range(1, boundaries.size()):
		stack.append(Vector2i(boundaries[i - 1], boundaries[i]))
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var best := tolerance * tolerance
		var split := -1
		for i in range(span.x + 1, span.y):
			var distance := points[i].distance_squared_to(Geometry2D.get_closest_point_to_segment(points[i], points[span.x], points[span.y]))
			if distance > best:
				best = distance
				split = i
		if split >= 0:
			keep[split] = true
			stack.append(Vector2i(span.x, split))
			stack.append(Vector2i(split, span.y))
	var ids := keep.keys()
	ids.sort()
	var result := PackedVector2Array()
	for i in ids:
		result.append(points[i])
	return result

static func _prepare_junctions_and_crossings(source: Dictionary) -> void:
	var structures: Array = []
	for feature in source.features:
		if feature.layer != "roads" or not feature.has("slot"):
			continue
		var points: PackedVector2Array = feature.points
		var stations: Array[float] = []
		for junction in feature.get("junctions", []):
			stations.append(float(junction.station_km))
		stations.sort()
		var fixed := PackedInt32Array()
		var protected := PackedVector2Array()
		var station := 0.0
		var cursor := 0
		if not points.is_empty():
			protected.append(points[0])
		for i in range(1, points.size()):
			var distance := points[i - 1].distance_to(points[i])
			while cursor < stations.size() and stations[cursor] <= station + distance:
				if stations[cursor] > station + 0.000001 and distance > 0.000001:
					protected.append(points[i - 1].lerp(points[i], (stations[cursor] - station) / distance))
					fixed.append(protected.size() - 1)
				cursor += 1
			protected.append(points[i])
			# LOD simplification must retain the approach tangent at both ends.
			if i==1 or i==points.size()-2:
				fixed.append(protected.size()-1)
			station += distance
		feature.points = protected
		feature["fixed"] = fixed
		var crossing_index := 0
		for crossing in feature.get("crossings", []):
			if not crossing.above:
				continue
			var direction := Vector2.RIGHT
			var best := INF
			for i in range(1, points.size()):
				var distance: float = crossing.point.distance_squared_to(Geometry2D.get_closest_point_to_segment(crossing.point, points[i - 1], points[i]))
				if distance < best:
					best = distance
					direction = (points[i] - points[i - 1]).normalized()
			var line := PackedVector2Array([crossing.point - direction * 0.055, crossing.point + direction * 0.055])
			structures.append({"identity": "%s:crossing:%d" % [feature.identity, crossing_index], "kind": "line", "layer": "structures", "points": line, "lanes": feature.lanes, "highway": feature.get("highway",false), "elevated": true, "slot": feature.slot, "style": feature.get("style", Style.RoadStyle.HIGHWAY if feature.get("highway",false) else Style.RoadStyle.ARTERIAL), "fade": Vector2(maxf(60.0, feature.get("fade",Vector2.ZERO).x),maxf(66.0,feature.get("fade",Vector2.ZERO).y)), "min_ppk": maxf(60.0,feature.get("min_ppk",0.0))})
			crossing_index += 1
		var span_index := 0
		for span in feature.get("terrain_spans", []):
			if span.kind in ["Bridge", "Tunnel"]:
				var path: PackedVector2Array = span.get("points", PackedVector2Array([span["from"],span["to"]]))
				structures.append({"identity": "%s:span:%d" % [feature.identity,span_index], "kind":"line", "layer":"structures", "points":path, "pixels":2.2, "slot":-4 if span.kind == "Bridge" else -5, "min_ppk":60.0})
			span_index += 1
	source.features.append_array(structures)

static func append_arrows(buffer: Dictionary, chunks: Array, points: PackedVector2Array, rect: Rect2, ppk: float, lanes: int, highway: bool) -> void:
	var spacing: float = 180.0 / ppk
	var offset: float = (1.5 if highway else 0.35) * 0.001 + lanes * (3.6 if highway else 3.25) * 0.0005
	var length: float = maxf(5.0 / ppk, 0.0015)
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var traveled := 0.0
	for i in range(1, points.size()):
		var distance := points[i - 1].distance_to(points[i])
		if distance < 0.000001:
			continue
		var tangent := (points[i] - points[i - 1]) / distance
		var first := INF
		var last := -INF
		for corner in corners:
			var along: float = (corner - points[i - 1]).dot(tangent)
			first = minf(first, along)
			last = maxf(last, along)
		var begin := ceili((traveled + maxf(0.0, first)) / spacing)
		var end := floori((traveled + minf(distance, last)) / spacing)
		for arrow in range(begin, end + 1):
			var point := points[i - 1] + tangent * (arrow * spacing - traveled)
			for sign_value in [-1.0, 1.0]:
				var tip: Vector2 = point + tangent.orthogonal() * offset * sign_value
				var base: Vector2 = tip + tangent * length * sign_value
				var wing := tangent.orthogonal() * length * 0.4
				append_polygon(buffer, chunks, PackedVector2Array([tip,base + wing,base - wing]), Color("f1f7fa"), rect)
		traveled += distance
