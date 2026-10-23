extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = Setup.build(8752568, 32, 0.1)
	var region = result["region"]
	if not result["errors"].is_empty():
		_fail("Starting region is invalid: %s" % result["errors"])
		return
	var chosen: Dictionary = {}
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and candidate.has("urban_sector"):
			chosen = candidate
			break
	if chosen.is_empty():
		_fail("No connected growth project was proposed")
		return
	var city_id: int = int(chosen["city_id"])
	var key: String = chosen["key"]
	var base_priority: float = float(chosen["priority"])
	var center: Vector2 = chosen["center_km"]
	region.urban_corridors.append({"city_id": city_id, "points": PackedVector2Array([center + Vector2(-0.3, 0), center + Vector2(0.3, 0)])})
	Planner.refresh_candidates(region)
	if not region.development_candidate_keys.has(key) or float(region.development_candidates[region.development_candidate_keys[key]]["priority"]) <= base_priority:
		_fail("A planned corridor did not increase priority for its adjacent project")
		return
	var initial_count: int = region.neighborhoods.size()
	if region.neighborhoods.size() != initial_count:
		_fail("Growth happened without player approval")
		return
	region.dev_mode = true
	var candidate_id: int = int(region.development_candidate_keys[key])
	var sector: Vector2i = region.development_candidates[candidate_id]["urban_sector"]
	if not Planner.set_approval(region, candidate_id, true).get("ok", false):
		_fail("Player approval did not open the growth project")
		return
	if region.neighborhoods.size() != initial_count + 1 or not region.urban_sector_claims.has(UrbanGraph.sector_key(city_id, sector)):
		_fail("Approved project did not claim its street graph blocks")
		return
	print("Growth needs manual approval; planned corridors rank connected projects.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
