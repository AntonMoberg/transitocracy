extends RefCounted
## Protect source copying with the same edit gate as simulation snapshots.
const Snapshot=preload("res://scripts/simulation/region_snapshot.gd")
const Planner=preload("res://scripts/simulation/road_planner.gd")
var source
var request:Dictionary
var serial:int
var mutex:=Mutex.new()
var copied:=false

func snapshot_ready() -> bool:
	mutex.lock()
	var ready:=copied
	mutex.unlock()
	return ready

func run() -> Dictionary:
	var detached=Snapshot.copy_region(source)
	mutex.lock()
	copied=true
	mutex.unlock()
	var result:=Planner.link_preview(detached,request.from,request.to,request.road_class,request.waypoints,request.day_key,request.draw_mode,request.end_position,request.crossing_choices,request.start_position)
	return {"serial":serial,"seed":detached.generation_seed,"revision":detached.road_geometry_revision,"preview":result}
