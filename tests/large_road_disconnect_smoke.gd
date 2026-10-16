extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = RegionSetup.build(1729, 128, 0.1)
	var region = result["region"]
	var first_spoke_id: int = region.neighborhood_spoke_link_ids[0]
	var started: int = Time.get_ticks_usec()
	var demolition: Dictionary = RoadPlanner.demolish(region, first_spoke_id)
	var demolition_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	AccessibilityCalculator.recalculate(region)
	region.city_od_candidates.clear()
	var flow = TripFlowCalculator.build(region)
	var errors := PackedStringArray()
	if not demolition.get("ok", false) or demolition.get("components_after", 0) < 2:
		errors.append("Road demolition did not disconnect its gateway.")
	if region.neighborhood_accessible[0] != 0 or region.accessibility[0] != 0.0:
		errors.append("Disconnected neighborhood retained job access.")
	if region.travel_time_between(0, 1) < 1000000.0:
		errors.append("Disconnected neighborhood retained a route.")
	if flow.compact_origin_daily["Work"][0] != 0.0 or flow.compact_destination_daily["Work"][0] != 0.0:
		errors.append("Disconnected neighborhood retained commute demand.")
	print("Large road demolition: %.1f ms; %d components" % [demolition_ms, demolition.get("components_after", 0)])
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
