extends RefCounted

var unix_seconds: int = 0
var day_key: int = -1
var next_bin: int = 0
var first_recorded_bin: int = 0
var link_ids: PackedInt32Array = PackedInt32Array()
var queues: PackedVector2Array = PackedVector2Array()
var last_arrivals: PackedVector2Array = PackedVector2Array()
var last_served: PackedVector2Array = PackedVector2Array()
var last_speed_kmh: PackedVector2Array = PackedVector2Array()
var profile
var cached_hour: int = -1
var cached_mode: int = -1
var cached_links: PackedVector2Array = PackedVector2Array()
var cached_revenue: Dictionary = {}
var paths_by_mode: Dictionary = {}
var compact_trees_by_mode: Dictionary = {}
var spoke_indices: PackedInt32Array = PackedInt32Array()
var link_capacity_hr: PackedFloat32Array = PackedFloat32Array()
var link_from_nodes: PackedInt32Array = PackedInt32Array()
var link_to_nodes: PackedInt32Array = PackedInt32Array()
var free_link_costs: PackedVector2Array = PackedVector2Array()
var free_pair_times: Array = []
var junction_capacity_hr: PackedFloat32Array = PackedFloat32Array()
var hourly_demand: Dictionary = {}
var hourly_fiscal_base: Array[Dictionary] = []
var departed_trips: float = 0.0
var served_cars: float = 0.0
var estimated: bool = false
var stage_totals_us: Dictionary = {}


func queued_cars() -> float:
	var result := 0.0
	for lane in queues:
		result += lane.x + lane.y
	return result


func visual_link(index: int) -> Dictionary:
	if index < 0 or index >= queues.size():
		return {}
	return {"arrival_vehicles_per_hour": last_arrivals[index], "served_vehicles_per_hour": last_served[index], "queue_vehicles": queues[index], "speed_kmh": last_speed_kmh[index], "estimated": estimated}
