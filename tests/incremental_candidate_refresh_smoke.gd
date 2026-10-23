extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(8752568)
	RoadNetworkGenerator.generate(region)
	DevelopmentPlanner.refresh_candidates(region)
	var candidate_id := -1
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0:
			candidate_id = int(candidate["id"])
			break
	if candidate_id < 0 or not DevelopmentPlanner.set_approval(region, candidate_id, true).get("ok", false):
		_fail("Fixture district could not be approved.")
		return
	var city_id: int = int(region.development_candidates[candidate_id]["city_id"])
	var full = DayCycleCalculator.copy_region(region)
	DevelopmentPlanner.refresh_candidates(region, [city_id])
	DevelopmentPlanner.refresh_candidates(full)
	if region.development_candidates.size() != full.development_candidates.size():
		_fail("Incremental refresh changed the candidate count.")
		return
	for expected in full.development_candidates:
		var id: int = int(region.development_candidate_keys.get(expected["key"], -1))
		if id < 0:
			_fail("Incremental refresh lost %s." % expected["key"])
			return
		var actual: Dictionary = region.development_candidates[id]
		if actual["polygon"] != expected["polygon"] or actual["frontage_link_id"] != expected["frontage_link_id"] or actual["neighborhood_id"] != expected["neighborhood_id"]:
			_fail("Incremental refresh changed %s." % expected["key"])
			return
	print("Affected-city candidate refresh matches a full rebuild.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
