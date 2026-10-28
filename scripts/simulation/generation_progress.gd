extends RefCounted
var mutex:=Mutex.new()
var stage:="Preparing world"
var preview:Dictionary={}
var started:=Time.get_ticks_msec()
var timings:Dictionary={}
var stage_started:=Time.get_ticks_usec()
var revision:=0
var completed:=0
var total:=0
var failed:=false
var last_preview_ms:=-1000
const STAGES={"Shaping terrain and placing cities":1,"Placing city streets":2,"Routing highways":3,"Connecting regional roads":4,"Installing regional roads":4,"Refining road connections":5,"Preparing land and buildings":6,"Finding development opportunities":7,"Preparing simulation":8,"Drawing the map":9}
func advance(count:int, maximum:int) -> void:
	mutex.lock()
	completed+=count
	total=maximum
	mutex.unlock()
func report(label:String,region=null) -> void:
	var packet:Dictionary={}
	var now:=Time.get_ticks_msec()
	if region!=null and (STAGES.get(label,0)!=STAGES.get(stage,0) or now-last_preview_ms>=500):
		last_preview_ms=now
		packet={"outline":region.jurisdictions[0].polygon_km.duplicate(),"bounds":region.jurisdictions[0].bounds_km,"roads":[],"cities":[],"water":[]}
		for link in region.road_links: packet.roads.append(link.points.duplicate())
		for city in region.cities: packet.cities.append(city.center_km)
		if region.terrain!=null:
			for river in region.terrain.rivers: packet.water.append(river.points.duplicate())
	mutex.lock()
	timings[stage]=int(timings.get(stage,0))+Time.get_ticks_usec()-stage_started
	stage_started=Time.get_ticks_usec()
	stage=label
	completed=0
	total=0
	if not packet.is_empty():
		preview=packet
		revision+=1
	mutex.unlock()
func status() -> Dictionary:
	mutex.lock()
	var result:Dictionary={"stage":stage,"stage_number":STAGES.get(stage,0),"preview":preview,"revision":revision,"completed":completed,"total":total,"failed":failed,"timings":timings.duplicate(),"seconds":(Time.get_ticks_msec()-started)/1000.0}
	mutex.unlock()
	return result
