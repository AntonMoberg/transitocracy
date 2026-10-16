extends RefCounted

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")


# The caller owns this region. A worker receives a detached copy, so UI reads
# and road or tax edits cannot race against the next day's calculations.
static func copy_region(source):
	return _copy_value(source)


static func advance_day(region, day_key: int, previous_flow, previous_traffic) -> Dictionary:
	var roads_changed: bool = RoadPlanner.advance_day(region, day_key)
	if roads_changed:
		AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.advance_day(region)
	var day_result: Dictionary = RoadTrafficCalculator.build_day(region, day_key * 86400, previous_flow, roads_changed, previous_traffic)
	NeighborhoodDynamics.refresh_desirability(region)
	return {"region": region, "flow": day_result["flow"], "traffic": day_result["traffic"]}


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
