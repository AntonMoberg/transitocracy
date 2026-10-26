extends RefCounted

const NEW_LINK = "New road"
const WIDEN = "Widen"
const INTERCHANGE_NODE = "Interchange junction"
const INTERCHANGE_EXIT = "Highway exit"

var id: int = -1
var kind: String = ""
var road_class: String = ""
var from_node_id: int = -1
var to_node_id: int = -1
var target_link_id: int = -1
var target_node_id: int = -1
var lanes_per_direction: int = 0
var points: PackedVector2Array = PackedVector2Array()
var position_km: Vector2 = Vector2.ZERO
var cost: int = 0
var start_day_key: int = 0
var open_day_key: int = 0
var owner_jurisdiction_id: int = 0
var crossings: Array[Dictionary] = []
var terrain_spans: Array[Dictionary] = []
var terrain_surface_paths: Array[PackedVector2Array] = []
var redevelopment_impact: Array[Dictionary] = []
var build_plan: Dictionary = {}


func days_remaining(day_key: int) -> int:
	return maxi(0, open_day_key - day_key)
