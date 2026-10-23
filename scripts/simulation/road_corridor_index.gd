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
