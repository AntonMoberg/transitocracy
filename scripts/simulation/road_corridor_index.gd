extends RefCounted

const Roads = preload("res://scripts/simulation/road_link_data.gd")


# Group and order arterial pieces once per road geometry. District previews
# query the same corridors many times while building their street charts.
static func arterials(region) -> Dictionary:
	var cached: Dictionary = region.road_corridor_cache
	if cached.get("revision", -1) == region.road_geometry_revision and cached.get("link_count", -1) == region.road_links.size():
		return cached["corridors"]
	var corridors: Dictionary = {}
	for link in region.road_links:
		if link.road_class != Roads.ARTERIAL or link.points.size() < 2:
			continue
		var corridor_id: int = link.corridor_id if link.corridor_id >= 0 else link.id
		if not corridors.has(corridor_id):
			corridors[corridor_id] = []
		corridors[corridor_id].append(link)
	for corridor_id in corridors:
		corridors[corridor_id].sort_custom(func(a, b) -> bool:
			if not is_equal_approx(a.corridor_start_km, b.corridor_start_km):
				return a.corridor_start_km < b.corridor_start_km
			return a.id < b.id
		)
	region.road_corridor_cache = {"revision": region.road_geometry_revision, "link_count": region.road_links.size(), "corridors": corridors}
	return corridors


# Local straight stretches survive an unrelated bend and physical link splits.
static func straight_runs(region) -> Array[Dictionary]:
	var corridors := arterials(region)
	if region.road_corridor_cache.has("runs"):
		return region.road_corridor_cache.runs
	var runs: Array[Dictionary] = []
	for corridor_id in corridors:
		var points := PackedVector2Array()
		for link in corridors[corridor_id]:
			if not points.is_empty() and points[-1].distance_to(link.points[0]) > .05:
				_append_run(runs, corridor_id, points)
				points.clear()
			for point in link.points:
				if not points.is_empty() and points[-1].distance_to(point) < .00001: continue
				if points.size() >= 2 and not _fits_run(points, point):
					_append_run(runs, corridor_id, points)
					points = PackedVector2Array([points[-1]])
				points.append(point)
		_append_run(runs, corridor_id, points)
	region.road_corridor_cache["runs"] = runs
	return runs


static func _fits_run(points: PackedVector2Array, end: Vector2) -> bool:
	var axis := (end - points[0]).normalized()
	for i in range(1, points.size() + 1):
		var a := points[i - 1]
		var b := points[i] if i < points.size() else end
		if a.distance_squared_to(b) > .0001 and (b - a).normalized().dot(axis) < cos(deg_to_rad(4.0)): return false
		if b.distance_to(Geometry2D.get_closest_point_to_segment(b, points[0], end)) > .03: return false
	return true


static func _append_run(runs: Array[Dictionary], corridor_id: int, points: PackedVector2Array) -> void:
	if points.size() < 2 or points[0].distance_to(points[-1]) < .60: return
	var a := points[0]
	var b := points[-1]
	runs.append({"corridor_id": corridor_id, "first": a, "last": b, "key": "%d:%d:%d:%d:%d" % [corridor_id, roundi(a.x*1000), roundi(a.y*1000), roundi(b.x*1000), roundi(b.y*1000)]})
