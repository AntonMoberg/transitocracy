extends RefCounted

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const RollingTrafficCalculator = preload("res://scripts/simulation/rolling_traffic_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")


# The caller owns this region. A worker receives a detached copy, so UI reads
# and road or tax edits cannot race against the next day's calculations.
static func copy_region(source):
	return _copy_value(source)


static func release_retired_data(payload: Dictionary) -> void:
	payload.clear()


static func advance_day(region, day_key: int, previous_flow, previous_traffic, previous_state = null) -> Dictionary:
	region.current_day_key = day_key
	FiscalCalculator.apply_due_policies(region, day_key * 86400)
	var roads_changed: bool = RoadPlanner.advance_day(region, day_key)
	if roads_changed:
		AccessibilityCalculator.recalculate(region)
	elif previous_flow != null and previous_traffic != null and previous_state != null and previous_state.next_bin >= 96:
		var weighted_times: Array[PackedFloat32Array] = RoadTrafficCalculator.generalized_travel_times(region, previous_flow, previous_traffic)
		region.travel_times = weighted_times
		AccessibilityCalculator.recalculate_jobs(region)
	NeighborhoodDynamics.advance_day(region)
	var flow_profile = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow_profile, region.generation_seed, day_key * 86400, CalendarClock.is_weekend_unix(day_key * 86400), previous_flow)
	var traffic_state = RollingTrafficCalculator.new_day(region, flow_profile, previous_state, roads_changed)
	RollingTrafficCalculator.advance_chunk(region, flow_profile, traffic_state, 1)
	NeighborhoodDynamics.refresh_desirability(region)
	return {"region": region, "flow": flow_profile, "traffic": traffic_state.profile, "traffic_state": traffic_state}


static func _copy_value(value):
	match typeof(value):
		TYPE_OBJECT:
			if value == null or value.get_script() == null:
				return value
			var copy = value.get_script().new()
			for property in value.get_property_list():
				if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					copy.set(property["name"], _copy_value(value.get(property["name"])))
			return copy
		TYPE_ARRAY:
			var copy: Array = value.duplicate(true)
			for index in range(value.size()):
				copy[index] = _copy_value(value[index])
			return copy
		TYPE_DICTIONARY:
			var copy: Dictionary = value.duplicate(true)
			for key in value:
				copy[key] = _copy_value(value[key])
			return copy
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return value.duplicate()
		_:
			return value
