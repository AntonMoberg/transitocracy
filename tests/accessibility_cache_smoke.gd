extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const Accessibility = preload("res://scripts/simulation/accessibility_calculator.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(1729, 256, 0.1)["region"]
	var reused = RegionSnapshot.copy_region(region)
	var full = RegionSnapshot.copy_region(region)
	var costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	Accessibility.recalculate_large_with_costs(reused, costs)
	full.accessibility_cost_revision = -1
	Accessibility.recalculate_large_with_costs(full, costs)
	if not _same_access(reused, full):
		_fail("Reused free-flow city routes differ from a full recalculation")
		return
	costs[0] += Vector2(2.0, 2.0)
	Accessibility.recalculate_large_with_costs(reused, costs)
	full.accessibility_cost_revision = -1
	Accessibility.recalculate_large_with_costs(full, costs)
	if reused.accessibility_link_costs != costs or not _same_access(reused, full):
		_fail("Changed link costs did not invalidate the city route cache")
		return
	print("Reused and invalidated city accessibility match full recalculation.")
	quit(0)


func _same_access(first, second) -> bool:
	if first.accessibility != second.accessibility or first.neighborhood_accessible != second.neighborhood_accessible:
		return false
	for city_id in range(first.cities.size()):
		if first.city_travel_times[city_id] != second.city_travel_times[city_id]:
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
