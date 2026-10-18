extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = RegionSetup.build(1729, 256, 0.1)
	var region = result["region"]
	var arterial_ids: Array[int] = []
	for link in region.road_links:
		if link.road_class == "Arterial" and region.road_nodes[link.from_node_id].city_id == 0:
			arterial_ids.append(link.id)
	var started: int = Time.get_ticks_usec()
	var removed := 0
	for link_id in arterial_ids:
		if RoadPlanner.demolish(region, link_id).get("ok", false):
			removed += 1
	var demolition_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	AccessibilityCalculator.recalculate(region)
	region.city_od_candidates.clear()
	var flow = TripFlowCalculator.build(region)
	var errors := PackedStringArray()
	if removed != arterial_ids.size() or removed == 0:
		errors.append("Road demolition did not remove the city's arterial access.")
	if region.neighborhood_accessible[0] != 0 or region.accessibility[0] != 0.0:
		errors.append("Disconnected neighborhood retained job access.")
	if region.travel_time_between(0, 1) < 1000000.0:
		errors.append("Disconnected neighborhood retained a route.")
	if flow.compact_origin_daily["Work"][0] != 0.0 or flow.compact_destination_daily["Work"][0] != 0.0:
		errors.append("Disconnected neighborhood retained commute demand.")
	print("Large road demolition: %.1f ms; %d arterial segments removed" % [demolition_ms, removed])
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
