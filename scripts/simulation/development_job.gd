extends RefCounted
## Speculative work owns a detached snapshot; publication uses a planning stamp.
const Snapshot = preload("res://scripts/simulation/region_snapshot.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
var source
var request: Dictionary
var mutex := Mutex.new()
var copied := false
var cancelled := false

func status() -> Dictionary:
	mutex.lock()
	var result := {"snapshot_ready": copied, "cancelled": cancelled}
	mutex.unlock()
	return result

func cancel() -> void:
	mutex.lock()
	cancelled = true
	mutex.unlock()

static func publish_suggestions(region, result: Dictionary) -> bool:
	if result.get("kind", "") != "suggestions" or result.stamp != Planner.planning_stamp(region): return false
	for field in result.payload: region.set(field, result.payload[field])
	return true

func run() -> Dictionary:
	var region = Snapshot.copy_region(source)
	source = null
	mutex.lock()
	copied = true
	var stop := cancelled
	mutex.unlock()
	if stop: return {}
	var stamp := Planner.planning_stamp(region)
	if request.kind == "prepare":
		var id: int = int(region.development_candidate_keys.get(request.key, -1))
		var packet := Planner.prepare_approval(region, id, request.shares, request.density)
		return {"kind": "prepare", "key": request.key, "packet": packet}
	var cities: Array[int] = []
	cities.assign(request.cities)
	Planner.refresh_candidates(region, cities)
	var payload := {}
	for field in ["development_candidates", "development_candidate_keys", "development_candidate_cells", "development_candidate_city_ids", "urban_grid_domains", "urban_district_cells", "urban_sector_merges", "urban_sector_merge_members", "city_border_seams"]:
		payload[field] = region.get(field)
	return {"kind": "suggestions", "stamp": stamp, "payload": payload}
