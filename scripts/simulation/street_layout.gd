extends RefCounted

const Roads = preload("res://scripts/simulation/road_link_data.gd")

var key: String = ""
var city_id: int = -1
var polygon: PackedVector2Array = PackedVector2Array()
var bounds: Rect2 = Rect2()
var nodes: PackedVector2Array = PackedVector2Array()
var edges: PackedVector2Array = PackedVector2Array()
var classes: PackedStringArray = PackedStringArray()
var phases: PackedInt32Array = PackedInt32Array()
var lengths: PackedFloat32Array = PackedFloat32Array()
var core_paths: Array = []
var arterial_nodes: PackedInt32Array = PackedInt32Array()
var blocks: Array = []
var phase_costs: PackedInt64Array = PackedInt64Array([0, 0, 0])
var phase_upkeep: PackedFloat64Array = PackedFloat64Array([0, 0, 0])


func total_cost() -> int:
	return phase_costs[0] + phase_costs[1] + phase_costs[2]


func total_upkeep() -> float:
	return phase_upkeep[0] + phase_upkeep[1] + phase_upkeep[2]


func local_upkeep(completed_phase: int, capacity_multiplier: float = 1.0) -> float:
	var upkeep := 0.0
	for edge_id in range(edges.size()):
		if classes[edge_id] == Roads.LOCAL and phases[edge_id] <= completed_phase:
			upkeep += lengths[edge_id] * Roads.upkeep(Roads.LOCAL)
	return upkeep * capacity_multiplier
