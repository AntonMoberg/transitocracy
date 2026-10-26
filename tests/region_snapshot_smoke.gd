extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const NeighborhoodSpatialIndex = preload("res://scripts/simulation/neighborhood_spatial_index.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(1729, 256, 0.1)["region"]
	region.dev_mode = true
	var copy = RegionSnapshot.copy_region(region)
	for property in region.get_property_list():
		if not int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			continue
		var name: String = property["name"]
		if name in ["street_spatial_cache", "road_corridor_cache", "neighborhood_spatial_cache", "urban_district_owner_cache", "urban_valid_junction_cache"]:
			continue
		var original = region.get(name)
		var copied = copy.get(name)
		if typeof(original) == TYPE_ARRAY or typeof(original) == TYPE_DICTIONARY:
			if original.size() != copied.size():
				_fail("Snapshot omitted region field %s" % name)
				return
		elif typeof(original) != TYPE_OBJECT and original != copied:
			_fail("Snapshot changed region field %s" % name)
			return
	if copy.neighborhoods[0] == region.neighborhoods[0] or copy.road_links[0] == region.road_links[0]:
		_fail("Worker snapshots still own live mutable objects")
		return
	for index in range(region.road_links.size()):
		if copy.road_links[index].map_major != region.road_links[index].map_major or copy.road_links[index].trunk_route_id != region.road_links[index].trunk_route_id:
			_fail("Snapshot lost cartographic road importance or trunk identity")
			return
	copy.neighborhoods[0].households += 17
	copy.cities[0]["name"] = "Snapshot only"
	if region.neighborhoods[0].households == copy.neighborhoods[0].households or region.cities[0]["name"] == "Snapshot only":
		_fail("Worker snapshot edits leaked into the live region")
		return
	for city_id in range(0, region.cities.size(), 17):
		var center: Vector2 = region.cities[city_id]["center_km"]
		var viewport := Rect2(center - Vector2.ONE * 1.5, Vector2.ONE * 3.0)
		var nearby_ids: Array[int] = NeighborhoodSpatialIndex.in_bounds(region, viewport)
		for neighborhood in region.neighborhoods:
			var extent: Rect2 = region.jurisdictions[neighborhood.jurisdiction_id].bounds_km
			if neighborhood.street_layout != null:
				extent = extent.merge(neighborhood.street_layout.bounds)
			if extent.intersects(viewport) and not nearby_ids.has(neighborhood.id):
				_fail("Spatial index omitted a visible neighborhood")
				return
	print("Large worker snapshots are detached and neighborhood queries cover visible districts.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
