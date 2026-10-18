extends RefCounted

var reserved: int = 0
var spent: int = 0
var completed_phase: int = 0
var constructing_phase: int = 0
var constructing_multiplier: float = 1.0
var open_day: int = -1
var active: bool = true
var status: String = "Awaiting funds"
var core_node_ids: Dictionary = {}
var core_link_ids: Dictionary = {}
var pending_zoning: Dictionary = {}
var zoning_day: int = -1
var target_housing: int = 0
var target_jobs: int = 0
var target_jobs_by_skill: Dictionary = {}
var target_retail_share: float = 0.0
var capacity_multiplier: float = 1.0
var installed_multiplier: float = 1.0
var design_demand: float = 1.0
var upgrade_open_day: int = -1
var upgrade_target: float = 1.0


func serviced_fraction() -> float:
	return [0.0, 0.35, 0.70, 1.0][completed_phase] * minf(1.0, installed_multiplier / capacity_multiplier)


func copy():
	var duplicate_plan = get_script().new()
	for property in get_property_list():
		if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value = get(property["name"])
			duplicate_plan.set(property["name"], value.duplicate(true) if value is Dictionary else value)
	return duplicate_plan
