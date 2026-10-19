extends SceneTree

const Generator = preload("res://scripts/simulation/region_generator.gd")
const RoadGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Generator.generate_large_region(5424046, 256)
	RoadGenerator.generate(region)
	Planner.refresh_candidates(region)
	if region.cities[98]["name"] != "Northbank 7":
		_fail("Seed 5424046 no longer places Northbank 7 at city 98.")
		return
	var gap := Vector2(515.9, 221.4)
	var candidate_id: int = region.development_candidate_at_point(gap)
	if candidate_id < 0 or region.development_candidates[candidate_id]["city_id"] != 98:
		_fail("The small wedge beside Northbank 7 still has no candidate zone.")
		return
	var candidate: Dictionary = region.development_candidates[candidate_id]
	if Geography.polygon_area(candidate["polygon"]) < 0.4:
		_fail("The previously empty wedge should be part of a usable neighborhood zone.")
		return
	var has_block := false
	for block in candidate["layout"].blocks:
		if Jurisdiction.polygon_contains_point(gap, block["polygon"]):
			has_block = true
			break
	if not has_block:
		_fail("The Northbank wedge needs buildable street blocks, not only a zone outline.")
		return
	for other in region.development_candidates:
		if other["id"] == candidate_id or other["city_id"] != 98:
			continue
		for overlap in Geometry2D.intersect_polygons(candidate["polygon"], other["polygon"]):
			if Geography.polygon_area(overlap) > 0.001:
				_fail("The Northbank wedge overlaps another district.")
				return
	var small_plans := 0
	var first_small_id := -1
	for other in region.development_candidates:
		if other["neighborhood_id"] >= 0 or Geography.polygon_area(other["polygon"]) >= 0.4:
			continue
		small_plans += 1
		if first_small_id < 0:
			first_small_id = other["id"]
		if other["layout"].arterial_nodes.is_empty() or other["layout"].core_paths.is_empty() or other["layout"].blocks.is_empty():
			_fail("A separate small plan needs arterial access and buildable blocks.")
			return
	if small_plans == 0:
		_fail("Valid small leftovers should remain available when they cannot join a neighbor.")
		return
	var small_city_id: int = region.development_candidates[first_small_id]["city_id"]
	region.jurisdictions[region.city_jurisdiction_ids[small_city_id]].treasury = 1000000000.0
	if not Planner.set_approval(region, first_small_id, true).get("ok", false):
		_fail("A small plan with road access should be approvable.")
		return
	region.jurisdictions[region.city_jurisdiction_ids[98]].treasury = 1000000000.0
	if not Planner.set_approval(region, candidate_id, true).get("ok", false):
		_fail("The Northbank wedge plan should be approvable.")
		return
	var neighborhood_id: int = region.development_candidates[candidate_id]["neighborhood_id"]
	if neighborhood_id < 0 or not Jurisdiction.polygon_contains_point(gap, region.neighborhoods[neighborhood_id].street_layout.polygon):
		_fail("Approving the plan must keep the wedge in the neighborhood.")
		return
	print("Northbank 7's wedge belongs to a buildable plan; %d other small gaps remain usable plans." % small_plans)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
