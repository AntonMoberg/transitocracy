extends RefCounted

const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const StreetLayoutOps = preload("res://scripts/simulation/street_layout_ops.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadCorridorIndex = preload("res://scripts/simulation/road_corridor_index.gd")

const MIN_DIAGONAL_LENGTH_KM = 0.60
const MIN_SPLIT_DEPTH_KM = 0.03
const MIN_BLOCK_AREA_KM2 = 0.000015
const NODE_QUANTIZATION = 100000.0
const MIN_ROAD_FRONTAGE_KM = 0.12
const POLICY_VERSION = 4


# A straight arterial can separate two street families. Its city-facing side
# keeps the established grid; the other side owns one chart along the corridor.
static func separating_chart(region, city_id: int, outline: PackedVector2Array, base: Dictionary) -> Dictionary:
	if outline.size() < 3:
		return {}
	var city_center: Vector2 = region.cities[city_id]["center_km"]
	var base_axis: Vector2 = base["axis"]
	var best := -INF
	var result: Dictionary = {}
	for run in RoadCorridorIndex.straight_runs(region):
		var corridor_id: int = run.corridor_id
		var first: Vector2 = run.first
		var last: Vector2 = run.last
		var axis: Vector2 = (last - first).normalized()
		var nearest_axis_alignment: float = maxf(absf(axis.dot(base_axis)), absf(axis.dot(base_axis.orthogonal())))
		if nearest_axis_alignment > cos(deg_to_rad(20.0)):
			continue
		if not _physical_frontage(first,last,outline):
			continue
		var center_side: float = axis.cross(city_center - first)
		if absf(center_side) < 0.04:
			center_side = 1.0
		var positive_depth := 0.0
		var negative_depth := 0.0
		for point in outline:
			var side: float = axis.cross(point - first)
			positive_depth = maxf(positive_depth, side)
			negative_depth = maxf(negative_depth, -side)
		var crossings := 0
		for index in range(outline.size()):
			if Geometry2D.segment_intersects_segment(first, last, outline[index], outline[(index + 1) % outline.size()]) != null:
				crossings += 1
		var enters_from_inside: bool = crossings >= 1 and (Geometry2D.is_point_in_polygon(first, outline) or Geometry2D.is_point_in_polygon(last, outline))
		# Finite physical frontage was checked above. A real crossing remains
		# a separator even when it clips a shallow corner of a narrow district.
		var crosses_district: bool = positive_depth >= MIN_SPLIT_DEPTH_KM and negative_depth >= MIN_SPLIT_DEPTH_KM and (crossings >= 2 or enters_from_inside)
		var domain: Dictionary = _domain_for_corridor(region, city_id, corridor_id, first, last, axis, center_side, base, run.key)
		if domain.is_empty():
			continue
		var rotated_side: float = float(domain["far_side"])
		var reaches_far_side: bool = not crosses_district and _entirely_far(first,last,outline,rotated_side) and _corridor_reaches_outline(region, city_id, corridor_id, first, last, outline, rotated_side)
		if not crosses_district and not reaches_far_side:
			continue
		# A crossing is the strongest cue. Otherwise the closest unblocked
		# arterial-side chart wins, independent of district approval order.
		var distance: float = Geography._bounds(outline).get_center().distance_to(Geometry2D.get_closest_point_to_segment(Geography._bounds(outline).get_center(), first, last))
		var score: float = (10.0 + minf(1.0, minf(positive_depth, negative_depth)) if crosses_district else 2.0 / (1.0 + distance))
		if score <= best:
			continue
		best = score
		result = domain.duplicate(true)
		result["uniform_far"] = not crosses_district
	return result


# Choose the changed side once per road geometry. Later approvals cannot
# reverse an arterial's chart simply because a new neighbor has more frontage.
static func _domain_for_corridor(region, city_id: int, corridor_id: int, first: Vector2, last: Vector2, axis: Vector2, center_side: float, base: Dictionary, run_key: String = "") -> Dictionary:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	if not _corridor_touches_city(city, first, last):
		return {}
	var domain_key: String = "%d:%s" % [city_id, run_key if not run_key.is_empty() else str(corridor_id)]
	var cached: Dictionary = region.urban_grid_domains.get(domain_key, region.urban_grid_domains.get("%d:%d" % [city_id, corridor_id], {}))
	if not cached.is_empty() and cached["road_first"].distance_to(first) < 0.002 and cached["road_last"].distance_to(last) < 0.002:
		return cached
	var far_side: float = -signf(center_side)
	var base_axis: Vector2 = base["axis"]
	var long_along: bool = absf(axis.dot(base_axis)) >= absf(axis.dot(base_axis.orthogonal()))
	var domain := {
		"key": "city:%d:diagonal:%s:%d" % [city_id, run_key if not run_key.is_empty() else str(corridor_id), int(far_side)],
		"corridor_id": corridor_id,
		"axis": axis,
		"origin": region.cities[city_id]["center_km"],
		"column_spacing": float(base["column_spacing"] if long_along else base["row_spacing"]),
		"row_spacing": float(base["row_spacing"] if long_along else base["column_spacing"]),
		"road_first": first,
		"road_last": last,
		"far_side": far_side,
	}
	domain["far_chart"] = _projected_frontage(base, domain)
	region.urban_grid_domains[domain_key] = domain.duplicate(true)
	return domain


# A new family needs frontage on the finite road, not its projected heading.
# Districts beyond it inherit only through committed, road-anchored neighbors.
static func _corridor_reaches_outline(region, city_id: int, corridor_id: int, first: Vector2, last: Vector2, outline: PackedVector2Array, rotated_side: float) -> bool:
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	if not _corridor_touches_city(city, first, last):
		return false
	if not _physical_frontage(first, last, outline):
		return false
	var axis: Vector2 = (last - first).normalized()
	var center: Vector2 = Geography._bounds(outline).get_center()
	if axis.cross(center - first) * rotated_side < 0.06:
		return false
	var best_distance := INF
	var target := Vector2.ZERO
	for point in outline:
		if axis.cross(point - first) * rotated_side < 0.06:
			continue
		var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(point, first, last)
		var distance: float = point.distance_to(nearest)
		if distance < best_distance:
			best_distance = distance
			target = point
	if best_distance == INF:
		return false
	var source: Vector2 = Geometry2D.get_closest_point_to_segment(target, first, last)
	var low: Vector2 = source.min(target)
	var high: Vector2 = source.max(target)
	for link in region.road_links:
		if link.road_class not in [Roads.ARTERIAL, Roads.HIGHWAY] or link.points.size() < 2:
			continue
		var other_id: int = link.corridor_id if link.corridor_id >= 0 else link.id
		if link.road_class == Roads.ARTERIAL and other_id == corridor_id:
			continue
		for index in range(1, link.points.size()):
			var edge_low: Vector2 = link.points[index - 1].min(link.points[index])
			var edge_high: Vector2 = link.points[index - 1].max(link.points[index])
			if edge_high.x < low.x or edge_low.x > high.x or edge_high.y < low.y or edge_low.y > high.y:
				continue
			var hit = Geometry2D.segment_intersects_segment(source, target, link.points[index - 1], link.points[index])
			if hit != null and hit.distance_to(source) > 0.06 and hit.distance_to(target) > 0.06:
				return false
	for reservation in region.rail_reservations:
		var points: PackedVector2Array = reservation.get("points", PackedVector2Array())
		for index in range(1, points.size()):
			var edge_low: Vector2 = points[index - 1].min(points[index])
			var edge_high: Vector2 = points[index - 1].max(points[index])
			if edge_high.x < low.x or edge_low.x > high.x or edge_high.y < low.y or edge_low.y > high.y:
				continue
			var hit = Geometry2D.segment_intersects_segment(source, target, points[index - 1], points[index])
			if hit != null and hit.distance_to(source) > 0.06 and hit.distance_to(target) > 0.06:
				return false
	# An older built fabric is an immutable island. Do not jump a rotated chart
	# across it merely because both districts lie on the same geometric side.
	var base: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	var city_neighborhood_ids: Array = region.cities[city_id].get("neighborhood_ids", [])
	var neighborhood_count: int = city_neighborhood_ids.size() if not city_neighborhood_ids.is_empty() else region.neighborhoods.size()
	for neighborhood_index in range(neighborhood_count):
		var id: int = int(city_neighborhood_ids[neighborhood_index]) if not city_neighborhood_ids.is_empty() else neighborhood_index
		if id < 0 or id >= region.neighborhoods.size():
			continue
		var neighborhood = region.neighborhoods[id]
		if neighborhood.city_id != city_id or neighborhood.street_layout == null:
			continue
		var layout = neighborhood.street_layout
		if layout.bounds.end.x < low.x or layout.bounds.position.x > high.x or layout.bounds.end.y < low.y or layout.bounds.position.y > high.y:
			continue
		for fraction in [0.25, 0.5, 0.75]:
			var sample: Vector2 = source.lerp(target, fraction)
			if not layout.bounds.has_point(sample) or not Geometry2D.is_point_in_polygon(sample, layout.polygon):
				continue
			var chart: Dictionary = _chart_at(layout, sample, base)
			if int(chart.get("corridor_id", -1)) != corridor_id or int(chart.get("far_side", 0)) != int(rotated_side):
				return false
	return true


static func _physical_frontage(first: Vector2, last: Vector2, outline: PackedVector2Array) -> bool:
	var length := first.distance_to(last)
	if length < MIN_ROAD_FRONTAGE_KM or outline.size() < 3: return false
	var axis := (last-first)/length
	var stations: Array[float] = [0.0,length]
	for i in range(outline.size()):
		stations.append(clampf((outline[i]-first).dot(axis),0.0,length))
		var hit = Geometry2D.segment_intersects_segment(first,last,outline[i],outline[(i+1)%outline.size()])
		if hit != null: stations.append(clampf((hit-first).dot(axis),0.0,length))
	stations.sort()
	var frontage := 0.0
	for i in range(1,stations.size()):
		var span: float = stations[i]-stations[i-1]
		if span < .00001: continue
		var point := first+axis*((stations[i]+stations[i-1])*.5)
		var touches := Geometry2D.is_point_in_polygon(point,outline)
		if not touches:
			for j in range(outline.size()):
				if point.distance_to(Geometry2D.get_closest_point_to_segment(point,outline[j],outline[(j+1)%outline.size()])) <= .03:
					touches = true
					break
		if touches: frontage += span
	return frontage >= MIN_ROAD_FRONTAGE_KM


static func _entirely_far(first: Vector2, last: Vector2, outline: PackedVector2Array, side: float) -> bool:
	var axis := (last-first).normalized()
	for point in outline:
		if axis.cross(point-first)*side < -.03: return false
	return true


static func _has_road_anchor(region, chart: Dictionary, outline: PackedVector2Array) -> bool:
	for run in RoadCorridorIndex.straight_runs(region):
		if int(run.corridor_id) != int(chart.corridor_id): continue
		var axis: Vector2 = (run.last-run.first).normalized()
		var chart_axis: Vector2 = (chart.road_last-chart.road_first).normalized()
		if absf(axis.dot(chart_axis)) < cos(deg_to_rad(4.0)): continue
		if chart.road_first.distance_to(Geometry2D.get_closest_point_to_segment(chart.road_first,run.first,run.last)) > .03 or chart.road_last.distance_to(Geometry2D.get_closest_point_to_segment(chart.road_last,run.first,run.last)) > .03: continue
		if _physical_frontage(run.first,run.last,outline): return true
	return false


# Cache a flood through actual shared rotated frontage. A legacy floating
# district cannot seed more floating districts, even if it stores a domain ID.
static func _anchored_neighbors(region, city_id: int, base: Dictionary) -> Dictionary:
	var stamp := hash([POLICY_VERSION,region.road_geometry_revision,region.road_links.size(),region.urban_sector_claims,region.rail_reservations])
	var cache_key := "anchors:%d" % city_id
	var cached: Dictionary = region.urban_grid_domains.get(cache_key,{})
	if cached.get("stamp",-1) == stamp: return cached.anchored
	var members := {}
	var sectors := {}
	var families := {}
	for key in region.urban_sector_claims:
		var pieces := String(key).split(":")
		if pieces.size()!=3 or int(pieces[0])!=city_id: continue
		var id: int = int(region.urban_sector_claims[key])
		if id<0 or id>=region.neighborhoods.size(): continue
		var layout = region.neighborhoods[id].street_layout
		if layout==null: continue
		members[id] = layout
		sectors[id] = Vector2i(int(pieces[1]),int(pieces[2]))
		for chart in layout.grid_families:
			if not chart.has("corridor_id") or not chart.has("road_first") or not chart.has("road_last"): continue
			var family: String = str(chart.key)
			if not families.has(family): families[family] = {"chart":chart,"roots":[]}
			if _has_road_anchor(region,chart,layout.polygon): families[family].roots.append(id)
	var anchored := {}
	var boundaries := {}
	for family in families:
		var reached := {}
		var queue: Array = families[family].roots.duplicate()
		for id in queue: reached[id] = true
		var cursor := 0
		while cursor<queue.size():
			var id: int = queue[cursor]
			cursor += 1
			var sector: Vector2i = sectors[id]
			for step in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN,Vector2i(-1,-1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(1,1)]:
				var adjacent: Vector2i = sector+step
				var other: int = int(region.urban_sector_claims.get("%d:%d:%d" % [city_id,adjacent.x,adjacent.y],-1))
				if reached.has(other) or not members.has(other): continue
				if not boundaries.has(other): boundaries[other] = _nearby_major_boundaries(region,members[other].polygon)
				for frontage in _shared_frontages(members[other].polygon,members[id].polygon):
					if _major_boundary_at(boundaries[other],frontage.point,frontage.axis): continue
					if _chart_at(members[id],frontage.neighbor_point,base).get("key","")!=family or _chart_at(members[other],frontage.candidate_point,base).get("key","")!=family: continue
					reached[other] = true
					queue.append(other)
					break
		anchored[family] = reached
	region.urban_grid_domains[cache_key] = {"stamp":stamp,"anchored":anchored}
	return anchored


static func _corridor_touches_city(city, first: Vector2, last: Vector2) -> bool:
	if city.contains_point(first) or city.contains_point(last) or city.contains_point((first + last) * 0.5):
		return true
	var outline: PackedVector2Array = city.polygon_km
	for index in range(outline.size()):
		if Geometry2D.segment_intersects_segment(first, last, outline[index], outline[(index + 1) % outline.size()]) != null:
			return true
	return false


# An approved chart owns its phase along a shared district edge, provided
# its contiguous street fabric is anchored to an actual arterial.
static func continue_chart(region, city_id: int, sector: Vector2i, outline: PackedVector2Array, selected: Dictionary) -> Dictionary:
	var base: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	if base.is_empty():
		return selected
	var contacts: Array[Dictionary] = []
	var major_boundaries: Array[Dictionary] = []
	var checked_boundaries := false
	for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN, Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		var adjacent: Vector2i = sector + step
		var sector_key: String = "%d:%d:%d" % [city_id, adjacent.x, adjacent.y]
		if not region.urban_sector_claims.has(sector_key):
			continue
		var neighborhood_id: int = int(region.urban_sector_claims[sector_key])
		if neighborhood_id < 0 or neighborhood_id >= region.neighborhoods.size():
			continue
		var neighbor = region.neighborhoods[neighborhood_id]
		if neighbor.street_layout == null:
			continue
		var neighbor_outline: PackedVector2Array = neighbor.street_layout.polygon
		if neighbor_outline.size() < 3:
			continue
		var frontages: Array[Dictionary] = _shared_frontages(outline, neighbor_outline)
		if frontages.is_empty():
			continue
		if not checked_boundaries:
			major_boundaries = _nearby_major_boundaries(region, outline)
			checked_boundaries = true
		for frontage in frontages:
			if _major_boundary_at(major_boundaries, frontage["point"], frontage["axis"]):
				continue
			var chart: Dictionary = _chart_at(neighbor.street_layout, frontage["neighbor_point"], base)
			contacts.append({"chart": chart, "neighbor_id": neighborhood_id, "length": frontage["length"], "point": frontage["neighbor_point"], "candidate_point": frontage["candidate_point"]})
	if selected.is_empty():
		var inherited_by_key: Dictionary = {}
		var anchored: Dictionary = {}
		var anchors_loaded := false
		for contact in contacts:
			var chart: Dictionary = contact["chart"]
			if not chart.has("corridor_id") or not chart.has("road_first") or not chart.has("road_last") or not chart.has("far_side"):
				continue
			if not anchors_loaded:
				anchored = _anchored_neighbors(region,city_id,base)
				anchors_loaded = true
			if not anchored.get(str(chart.key),{}).has(contact.neighbor_id): continue
			var key: String = str(chart["key"])
			var record: Dictionary = inherited_by_key.get(key, {"chart": chart, "length": 0.0, "longest_edge": 0.0})
			record["length"] += float(contact["length"])
			if float(contact["length"]) > float(record["longest_edge"]):
				record["chart"] = chart
				record["longest_edge"] = float(contact["length"])
			inherited_by_key[key] = record
		var inherited: Dictionary = {}
		var longest := 0.0
		var winning_key := ""
		for key in inherited_by_key:
			var record: Dictionary = inherited_by_key[key]
			var length: float = record["length"]
			if length > longest + 0.0001 or (absf(length - longest) <= 0.0001 and (winning_key.is_empty() or str(key) < winning_key)):
				longest = length
				winning_key = str(key)
				inherited = record["chart"].duplicate(true)
		if inherited.is_empty():
			return {}
		# An approved neighbor owns this shared frontage. Its original straight
		# road may have ended or bent before reaching this district, so that
		# road's infinite half-plane cannot delimit the continuing fabric.
		# A real road/rail through the district still stops uniform inheritance.
		if _has_interior_boundary(major_boundaries, outline):
			return {}
		inherited["base_chart"] = base
		inherited["far_chart"] = _clean_chart(inherited)
		inherited["uniform_far"] = true
		return inherited
	selected = selected.duplicate(true)
	selected["base_chart"] = base
	var road_axis: Vector2 = (selected["road_last"] - selected["road_first"]).normalized()
	var far: float = float(selected["far_side"])
	var best_base := -1.0
	var best_far := -1.0
	for contact in contacts:
		var side: float = road_axis.cross(contact["point"] - selected["road_first"]) * far
		if absf(side) < 0.035:
			continue
		var chart: Dictionary = contact["chart"]
		if side > 0.0 and chart.get("key", "") == selected["key"] and float(contact["length"]) > best_far:
			best_far = float(contact["length"])
			selected["far_chart"] = chart
		elif side < 0.0 and _same_grid(chart, base) and float(contact["length"]) > best_base:
			best_base = float(contact["length"])
			selected["base_chart"] = chart
	if not selected.has("far_chart"):
		selected["far_chart"] = _projected_frontage(selected.get("base_chart", base), selected)
	return selected


static func _shared_frontages(outline: PackedVector2Array, neighbor_outline: PackedVector2Array) -> Array[Dictionary]:
	var frontages: Array[Dictionary] = []
	for neighbor_index in range(neighbor_outline.size()):
		var first: Vector2 = neighbor_outline[neighbor_index]
		var last: Vector2 = neighbor_outline[(neighbor_index + 1) % neighbor_outline.size()]
		var length: float = first.distance_to(last)
		if length < 0.06:
			continue
		var axis: Vector2 = (last - first) / length
		for index in range(outline.size()):
			var candidate_first: Vector2 = outline[index]
			var candidate_last: Vector2 = outline[(index + 1) % outline.size()]
			var candidate_edge: Vector2 = candidate_last - candidate_first
			if candidate_edge.length() < 0.06 or absf(axis.cross(candidate_edge.normalized())) > 0.015:
				continue
			var start: float = maxf(0.0, minf((candidate_first - first).dot(axis), (candidate_last - first).dot(axis)))
			var end: float = minf(length, maxf((candidate_first - first).dot(axis), (candidate_last - first).dot(axis)))
			if end - start < 0.06:
				continue
			# Three probes retain usable frontage when a road occupies only part
			# of a long edge, and work when adjacent polygons split that edge.
			for part in range(3):
				var midpoint: Vector2 = first + axis * lerpf(start, end, (float(part) + 0.5) / 3.0)
				if midpoint.distance_to(Geometry2D.get_closest_point_to_segment(midpoint, candidate_first, candidate_last)) > 0.015:
					continue
				var neighbor_point: Vector2 = _inside_edge(midpoint, axis, neighbor_outline)
				var candidate_point: Vector2 = _inside_edge(midpoint, candidate_edge.normalized(), outline)
				if not neighbor_point.is_finite() or not candidate_point.is_finite():
					continue
				if axis.cross(neighbor_point - midpoint) * axis.cross(candidate_point - midpoint) >= 0.0:
					continue
				frontages.append({"point": midpoint, "axis": axis, "neighbor_point": neighbor_point, "candidate_point": candidate_point, "length": (end - start) / 3.0})
	return frontages


static func _inside_edge(point: Vector2, axis: Vector2, outline: PackedVector2Array) -> Vector2:
	for distance in [0.025, 0.008]:
		var offset: Vector2 = axis.orthogonal() * distance
		for sample in [point + offset, point - offset]:
			if Geometry2D.is_point_in_polygon(sample, outline):
				return sample
	return Vector2.INF


static func _nearby_major_boundaries(region, outline: PackedVector2Array) -> Array[Dictionary]:
	var bounds: Rect2 = Geography._bounds(outline).grow(0.03)
	var edges: Array[Dictionary] = []
	for link in region.road_links:
		if link.road_class not in [Roads.ARTERIAL, Roads.HIGHWAY]:
			continue
		_add_nearby_edges(edges, link.points, bounds)
	for reservation in region.rail_reservations:
		_add_nearby_edges(edges, reservation.get("points", PackedVector2Array()), bounds)
	return edges


static func _add_nearby_edges(edges: Array[Dictionary], points: PackedVector2Array, bounds: Rect2) -> void:
	for index in range(1, points.size()):
		var first: Vector2 = points[index - 1]
		var last: Vector2 = points[index]
		if not Rect2(first.min(last), (last - first).abs()).intersects(bounds):
			continue
		var edge: Vector2 = last - first
		if edge.length() < 0.00001:
			continue
		edges.append({"first": first, "last": last, "axis": edge.normalized()})


static func _has_interior_boundary(edges: Array[Dictionary], outline: PackedVector2Array) -> bool:
	for edge in edges:
		var first: Vector2 = edge.first
		var last: Vector2 = edge.last
		var length: float = first.distance_to(last)
		var stations: Array[float] = [0.0, length]
		for index in range(outline.size()):
			var hit = Geometry2D.segment_intersects_segment(first,last,outline[index],outline[(index+1)%outline.size()])
			if hit != null:
				stations.append(clampf((hit-first).dot(edge.axis),0.0,length))
		stations.sort()
		for index in range(1,stations.size()):
			if stations[index]-stations[index-1] < 0.00001:
				continue
			var point: Vector2 = first+edge.axis*((stations[index]+stations[index-1])*.5)
			if not Geometry2D.is_point_in_polygon(point,outline):
				continue
			var depth := INF
			for corner in range(outline.size()):
				depth = minf(depth,point.distance_to(Geometry2D.get_closest_point_to_segment(point,outline[corner],outline[(corner+1)%outline.size()])))
			if depth > 0.03:
				return true
	return false


static func _major_boundary_at(edges: Array[Dictionary], point: Vector2, axis: Vector2) -> bool:
	for edge in edges:
		if absf(axis.dot(edge["axis"])) < cos(deg_to_rad(15.0)):
			continue
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, edge["first"], edge["last"])) <= 0.025:
			return true
	return false


static func _chart_at(layout, point: Vector2, base: Dictionary) -> Dictionary:
	if layout.grid_families.is_empty():
		return _clean_chart(base)
	if layout.grid_families.size() == 1:
		return _clean_chart(layout.grid_families[0])
	var rotated: Dictionary = layout.grid_families[1]
	var road_axis: Vector2 = (rotated["road_last"] - rotated["road_first"]).normalized()
	var side: float = road_axis.cross(point - rotated["road_first"]) * float(rotated["far_side"])
	var chart: Dictionary = layout.grid_families[1] if side > 0.0 else layout.grid_families[0]
	return _clean_chart(chart)


static func _clean_chart(chart: Dictionary) -> Dictionary:
	var result := {
		"axis": chart["axis"],
		"origin": chart["origin"],
		"column_spacing": chart["column_spacing"],
		"row_spacing": chart["row_spacing"],
	}
	for key in ["key", "plan_key", "column_coordinates", "corridor_id", "road_first", "road_last", "far_side"]:
		if chart.has(key):
			result[key] = chart[key]
	return result


static func _same_grid(first: Dictionary, second: Dictionary) -> bool:
	if first.get("key", "") == second.get("key", "") and first.has("key"):
		return true
	var a: Vector2 = first["axis"]
	var b: Vector2 = second["axis"]
	return absf(a.dot(b)) > cos(deg_to_rad(5.0))


# Intersect the established grid's straight streets with the arterial. These
# locations become the perpendicular street columns on the new side, so the
# two fabrics meet at the same junctions. Very close intersections are thinned
# to avoid strips too narrow to hold a useful block.
static func _projected_frontage(established: Dictionary, selected: Dictionary) -> Dictionary:
	var road_axis: Vector2 = (selected["road_last"] - selected["road_first"]).normalized()
	var road_first: Vector2 = selected["road_first"]
	var road_length: float = road_first.distance_to(selected["road_last"])
	var extension := 4.0
	var old_axis: Vector2 = established["axis"]
	var old_normal: Vector2 = old_axis.orthogonal()
	var old_origin: Vector2 = established["origin"]
	var crossings: Array[float] = []
	for family in [
		{"normal": old_axis, "spacing": float(established["column_spacing"]), "coordinates": established.get("column_coordinates", PackedFloat32Array())},
		{"normal": old_normal, "spacing": float(established["row_spacing"])},
	]:
		var direction: Vector2 = family["normal"]
		var denominator: float = road_axis.dot(direction)
		if absf(denominator) < 0.08:
			continue
		var spacing: float = family["spacing"]
		var coordinates: PackedFloat32Array = family.get("coordinates", PackedFloat32Array())
		if coordinates.is_empty():
			var first_index: int = floori((road_first - road_axis * extension - old_origin).dot(direction) / spacing) - 2
			var last_index: int = ceili((road_first + road_axis * (road_length + extension) - old_origin).dot(direction) / spacing) + 2
			for index in range(mini(first_index, last_index), maxi(first_index, last_index) + 1):
				coordinates.append(float(index))
		for coordinate in coordinates:
			var distance: float = (coordinate * spacing - (road_first - old_origin).dot(direction)) / denominator
			if distance >= -extension and distance <= road_length + extension:
				crossings.append(distance)
	crossings.sort()
	var selected_crossings: Array[float] = []
	for crossing in crossings:
		if selected_crossings.is_empty() or crossing - selected_crossings[-1] >= 0.105:
			selected_crossings.append(crossing)
	if selected_crossings.size() < 3:
		var fallback: Dictionary = _clean_chart(selected)
		fallback["road_first"] = selected["road_first"]
		fallback["road_last"] = selected["road_last"]
		fallback["far_side"] = selected["far_side"]
		return fallback
	var total_gap := 0.0
	for index in range(1, selected_crossings.size()):
		total_gap += selected_crossings[index] - selected_crossings[index - 1]
	var spacing: float = total_gap / float(selected_crossings.size() - 1)
	var chart: Dictionary = _clean_chart(selected)
	chart["origin"] = road_first
	chart["column_spacing"] = spacing
	chart["road_first"] = selected["road_first"]
	chart["road_last"] = selected["road_last"]
	chart["far_side"] = selected["far_side"]
	var coordinates := PackedFloat32Array()
	for crossing in selected_crossings:
		coordinates.append(crossing / spacing)
	chart["column_coordinates"] = coordinates
	return chart


# The district remains the same claimed land. Street charts are clipped to
# that land and to the arterial itself, so chart changes cannot create a bend
# at a district seam or move a neighboring district's street addresses.
static func fill(layout, base: Dictionary, rotated: Dictionary, variant: int, road_context: Dictionary, seed_value: int) -> Dictionary:
	if rotated.get("uniform_far", false):
		var whole_chart: Dictionary = rotated.get("far_chart", rotated)
		var whole_nodes: Dictionary = {}
		var whole_boundary: Dictionary = {}
		var whole_edges: Dictionary = {}
		var whole_families: Array[Dictionary] = []
		whole_families.append(whole_chart.duplicate(true))
		layout.grid_families = whole_families
		_add_lattice(layout, layout.polygon, whole_chart, variant, road_context, seed_value, whole_nodes, whole_boundary, whole_edges)
		layout.grid_axis = whole_chart["axis"]
		layout.grid_origin = whole_chart["origin"]
		layout.grid_column_spacing_km = whole_chart["column_spacing"]
		layout.grid_row_spacing_km = whole_chart["row_spacing"]
		return {"node_ids": whole_nodes, "boundary_nodes": whole_boundary}
	var road_axis: Vector2 = (rotated["road_last"] - rotated["road_first"]).normalized()
	var normal: Vector2 = road_axis.orthogonal() * float(rotated["far_side"])
	var anchor: Vector2 = rotated["road_first"]
	var half_plane := PackedVector2Array([anchor - road_axis * 100.0, anchor + road_axis * 100.0, anchor + road_axis * 100.0 + normal * 100.0, anchor - road_axis * 100.0 + normal * 100.0])
	# Geometry2D's clipping operations use the polygon winding to choose its
	# interior. Reversing the positive side keeps the requested side inside.
	if float(rotated["far_side"]) > 0.0:
		half_plane.reverse()
	var rotated_parts: Array[PackedVector2Array] = Geometry2D.intersect_polygons(layout.polygon, half_plane)
	var base_parts: Array[PackedVector2Array] = Geometry2D.clip_polygons(layout.polygon, half_plane)
	# Geometry2D may return the opposite half depending on the winding of the
	# source polygon. Identify sides from the actual clipped geometry.
	var probe_parts: Array[PackedVector2Array] = rotated_parts if not rotated_parts.is_empty() else base_parts
	if not probe_parts.is_empty():
		var probe := Vector2.ZERO
		for point in probe_parts[0]:
			probe += point
		probe /= float(probe_parts[0].size())
		var probe_far: bool = road_axis.cross(probe - anchor) * float(rotated["far_side"]) > 0.0
		if probe_far == rotated_parts.is_empty():
			var swapped: Array[PackedVector2Array] = rotated_parts
			rotated_parts = base_parts
			base_parts = swapped
	var base_chart: Dictionary = rotated.get("base_chart", base)
	var far_chart: Dictionary = rotated.get("far_chart", rotated)
	if far_chart != rotated:
		far_chart = far_chart.duplicate(true)
		far_chart["road_first"] = rotated["road_first"]
		far_chart["road_last"] = rotated["road_last"]
		far_chart["far_side"] = rotated["far_side"]
	var node_ids: Dictionary = {}
	var boundary_nodes: Dictionary = {}
	var edge_ids: Dictionary = {}
	var families: Array[Dictionary] = []
	families.append(base_chart.duplicate(true))
	families.append(far_chart.duplicate(true))
	layout.grid_families = families
	for part in base_parts:
		_add_lattice(layout, part, base_chart, variant, road_context, seed_value, node_ids, boundary_nodes, edge_ids)
	for part in rotated_parts:
		_add_lattice(layout, part, far_chart, variant, road_context, seed_value, node_ids, boundary_nodes, edge_ids)
	var rotated_area := 0.0
	var base_area := 0.0
	for part in rotated_parts:
		rotated_area += Geography.polygon_area(part)
	for part in base_parts:
		base_area += Geography.polygon_area(part)
	if rotated_area > base_area:
		layout.grid_axis = far_chart["axis"]
		layout.grid_origin = far_chart["origin"]
		layout.grid_column_spacing_km = far_chart["column_spacing"]
		layout.grid_row_spacing_km = far_chart["row_spacing"]
	else:
		layout.grid_axis = base_chart["axis"]
		layout.grid_origin = base_chart["origin"]
		layout.grid_column_spacing_km = base_chart["column_spacing"]
		layout.grid_row_spacing_km = base_chart["row_spacing"]
	return {"node_ids": node_ids, "boundary_nodes": boundary_nodes}


static func _add_lattice(layout, part: PackedVector2Array, chart: Dictionary, variant: int, road_context: Dictionary, seed_value: int, node_ids: Dictionary, boundary_nodes: Dictionary, edge_ids: Dictionary) -> void:
	if part.size() < 3 or Geography.polygon_area(part) < MIN_BLOCK_AREA_KM2:
		return
	var axis: Vector2 = chart["axis"]
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = chart["origin"]
	var x_spacing: float = chart["column_spacing"]
	var y_spacing: float = chart["row_spacing"]
	var chart_key: String = str(chart.get("key", chart.get("plan_key", "city")))
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in part:
		var local := Vector2((point - origin).dot(axis) / x_spacing, (point - origin).dot(normal) / y_spacing)
		low = low.min(local)
		high = high.max(local)
	var columns: Array[int] = []
	var rows: Array[int] = []
	var column_coordinates: PackedFloat32Array = chart.get("column_coordinates", PackedFloat32Array())
	if column_coordinates.is_empty():
		for x in range(floori(low.x) - 1, ceili(high.x) + 2):
			if variant != 2 or posmod(x, 2) == 0 or posmod(x, 4) == 0:
				columns.append(x)
	else:
		# Portal columns are irregular near the arterial. Beyond their projected
		# range, continue the same chart at its average spacing.
		var first_index: int = _nearest_column_index(column_coordinates, low.x) - 3
		var last_index: int = _nearest_column_index(column_coordinates, high.x) + 3
		for x in range(first_index, last_index + 1):
			var coordinate: float = _column_coordinate(column_coordinates, x)
			if coordinate < low.x - 2.0 or coordinate > high.x + 2.0:
				continue
			if variant != 2 or posmod(x, 2) == 0 or posmod(x, 4) == 0:
				columns.append(x)
	for y in range(floori(low.y) - 1, ceili(high.y) + 2):
		if variant != 1 or posmod(y, 2) == 0 or posmod(y, 4) == 0:
			rows.append(y)
	for row in range(rows.size() - 1):
		for column in range(columns.size() - 1):
			var x0: int = columns[column]
			var x1: int = columns[column + 1]
			var y0: int = rows[row]
			var y1: int = rows[row + 1]
			var x0_coordinate: float = float(x0) if column_coordinates.is_empty() else _column_coordinate(column_coordinates, x0)
			var x1_coordinate: float = float(x1) if column_coordinates.is_empty() else _column_coordinate(column_coordinates, x1)
			var quad := PackedVector2Array([
				origin + axis * (x0_coordinate * x_spacing) + normal * (float(y0) * y_spacing),
				origin + axis * (x1_coordinate * x_spacing) + normal * (float(y0) * y_spacing),
				origin + axis * (x1_coordinate * x_spacing) + normal * (float(y1) * y_spacing),
				origin + axis * (x0_coordinate * x_spacing) + normal * (float(y1) * y_spacing),
			])
			var piece_index := 0
			for clipped in Geometry2D.intersect_polygons(quad, part):
				piece_index += 1
				if clipped.size() < 3 or Geography.polygon_area(clipped) < MIN_BLOCK_AREA_KM2 or StreetLayoutOps.triangulate(clipped).is_empty():
					continue
				var vertices := PackedInt32Array()
				for point in clipped:
					var key: String = _chart_node_key(layout.city_id, point, chart)
					if not node_ids.has(key):
						var local_id: int = layout.nodes.size()
						node_ids[key] = local_id
						layout.nodes.append(point)
						layout.canonical_nodes[local_id] = key
					vertices.append(node_ids[key])
					if _point_on_outline(point, layout.polygon) or _point_on_arterial(point, road_context):
						boundary_nodes[key] = true
				for index in range(vertices.size()):
					var first_id: int = vertices[index]
					var last_id: int = vertices[(index + 1) % vertices.size()]
					var first: Vector2 = layout.nodes[first_id]
					var last: Vector2 = layout.nodes[last_id]
					if first_id == last_id or first.distance_to(last) < 0.015:
						continue
					var first_key: String = layout.canonical_nodes[first_id]
					var last_key: String = layout.canonical_nodes[last_id]
					var edge_key: String = "%s|%s" % [first_key, last_key] if first_key < last_key else "%s|%s" % [last_key, first_key]
					if edge_ids.has(edge_key):
						continue
					edge_ids[edge_key] = true
					if _road_already_covers(first, last, road_context) or _on_chart_divider(first, last, chart):
						continue
					var road_class: String = Roads.COLLECTOR if _collector_line(first, last, chart) else Roads.LOCAL
					StreetLayoutOps._append_edge(layout, first_id, last_id, road_class, 1 if road_class == Roads.COLLECTOR else 2)
					layout.canonical_edges[layout.edges.size() - 1] = edge_key
				StreetLayoutOps._append_block_polygon(layout, clipped, vertices, 2, hash("%d:%s:%d:%d:%d" % [seed_value, chart_key, x0, y0, variant]), false, false)
				var block: Dictionary = layout.blocks[-1]
				block["canonical_id"] = "%s:%d:%d:%d:%d" % [chart_key, x0, y0, variant, piece_index]
				layout.blocks[-1] = block


static func _column_coordinate(coordinates: PackedFloat32Array, index: int) -> float:
	if index < 0:
		return coordinates[0] + float(index)
	if index >= coordinates.size():
		return coordinates[-1] + float(index - coordinates.size() + 1)
	return coordinates[index]


static func _nearest_column_index(coordinates: PackedFloat32Array, value: float) -> int:
	if value < coordinates[0]:
		return roundi(value - coordinates[0])
	if value > coordinates[-1]:
		return coordinates.size() - 1 + roundi(value - coordinates[-1])
	var low := 0
	var high: int = coordinates.size() - 1
	while low < high:
		var middle: int = (low + high) / 2
		if coordinates[middle] < value:
			low = middle + 1
		else:
			high = middle
	if low > 0 and absf(coordinates[low - 1] - value) < absf(coordinates[low] - value):
		return low - 1
	return low


static func _point_key(city_id: int, point: Vector2) -> String:
	return "%d:p:%d:%d" % [city_id, roundi(point.x * NODE_QUANTIZATION), roundi(point.y * NODE_QUANTIZATION)]


static func _chart_node_key(city_id: int, point: Vector2, chart: Dictionary) -> String:
	if chart.has("plan_key"):
		var address: Vector2i = CityPlan.address(point, chart)
		if point.distance_to(CityPlan.base_junction(chart, address)) < 0.00001:
			return "%d:%d:%d" % [city_id, address.x, address.y]
	return _point_key(city_id, point)


static func _point_on_outline(point: Vector2, outline: PackedVector2Array) -> bool:
	for index in range(outline.size()):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[index], outline[(index + 1) % outline.size()])) < 0.001:
			return true
	return false


static func _point_on_arterial(point: Vector2, road_context: Dictionary) -> bool:
	for road in road_context.get("roads", []):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(point, road["first"], road["last"])) < 0.02:
			return true
	return false


static func _road_already_covers(first: Vector2, last: Vector2, road_context: Dictionary) -> bool:
	return StreetLayoutOps._near_field_arterial(first, last, road_context, 0.075)


static func _on_chart_divider(first: Vector2, last: Vector2, chart: Dictionary) -> bool:
	if not chart.has("road_first"):
		return false
	var axis: Vector2 = (chart["road_last"] - chart["road_first"]).normalized()
	var anchor: Vector2 = chart["road_first"]
	return absf(axis.cross(first - anchor)) < 0.002 and absf(axis.cross(last - anchor)) < 0.002


static func _collector_line(first: Vector2, last: Vector2, chart: Dictionary) -> bool:
	var axis: Vector2 = chart["axis"]
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = chart["origin"]
	var delta: Vector2 = last - first
	if absf(delta.normalized().dot(axis)) > 0.998:
		var row: float = (first - origin).dot(normal) / float(chart["row_spacing"])
		return absf(row - roundf(row)) < 0.01 and posmod(roundi(row), 4) == 0
	if absf(delta.normalized().dot(normal)) > 0.998:
		var column: float = (first - origin).dot(axis) / float(chart["column_spacing"])
		var coordinates: PackedFloat32Array = chart.get("column_coordinates", PackedFloat32Array())
		if not coordinates.is_empty():
			var nearest: int = _nearest_column_index(coordinates, column)
			return absf(column - _column_coordinate(coordinates, nearest)) < 0.01 and posmod(nearest, 4) == 0
		return absf(column - roundf(column)) < 0.01 and posmod(roundi(column), 4) == 0
	return false
