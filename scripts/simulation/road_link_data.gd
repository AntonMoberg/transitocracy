extends RefCounted

const ARTERIAL = "Arterial"
const HIGHWAY = "Highway"
const COLLECTOR = "Collector"
const LOCAL = "Local"
const RURAL = COLLECTOR
const CONSTRUCTION_COSTS = {HIGHWAY: 1800000.0, ARTERIAL: 600000.0, COLLECTOR: 200000.0, LOCAL: 120000.0}
const UPKEEP_COSTS = {HIGHWAY: 600.0, ARTERIAL: 200.0, COLLECTOR: 50.0, LOCAL: 40.0}

var id: int = -1
var from_node_id: int = -1
var to_node_id: int = -1
var road_class: String = ARTERIAL
var lanes_per_direction: int = 1
var points: PackedVector2Array = PackedVector2Array()
var elevation_profile_m: PackedFloat32Array = PackedFloat32Array()
var length_km: float = 0.0
var owner_jurisdiction_id: int = 0
var toll_forward: float = 0.0
var toll_reverse: float = 0.0
var corridor_id: int = -1
var corridor_start_km: float = 0.0
var managed_neighborhood_id: int = -1
var crossings: Array[Dictionary] = []
var terrain_spans: Array[Dictionary] = []
# Interior junctions keep a road a single multipoint curve: each entry holds
# {"node_id": int, "station_km": float} and the list stays sorted by station.
# Routing synthesizes sub-edges from this chain; links are never split for
# countryside or highway junctions.
var junctions: Array[Dictionary] = []
var border_city_ids: Vector2i = Vector2i(-1, -1)
var border_seam_key: String = ""


static func junction_station(junctions: Array[Dictionary], node_id: int) -> float:
	for junction in junctions:
		if int(junction["node_id"]) == node_id:
			return float(junction["station_km"])
	return -1.0


static func construction_cost(link_class: String) -> float:
	return CONSTRUCTION_COSTS.get(link_class, 600000.0)


static func upkeep(link_class: String) -> float:
	return UPKEEP_COSTS.get(link_class, 200.0)


func recalculate_length() -> void:
	length_km = 0.0
	for index in range(1, points.size()):
		length_km += points[index - 1].distance_to(points[index])
