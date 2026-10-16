extends RefCounted

const ARTERIAL = "Arterial"
const HIGHWAY = "Highway"

var id: int = -1
var from_node_id: int = -1
var to_node_id: int = -1
var road_class: String = ARTERIAL
var lanes_per_direction: int = 1
var points: PackedVector2Array = PackedVector2Array()
var length_km: float = 0.0
var owner_jurisdiction_id: int = 0
var toll_forward: float = 0.0
var toll_reverse: float = 0.0


func recalculate_length() -> void:
	length_km = 0.0
	for index in range(1, points.size()):
		length_km += points[index - 1].distance_to(points[index])
