extends SceneTree

const Fixture=preload("res://tests/ui_fixture.gd")
const Planner=preload("res://scripts/simulation/road_planner.gd")
var errors:=PackedStringArray()

func _initialize() -> void:
	call_deferred("_run")

func _wait_edit(main,label:String) -> void:
	var deadline:=Time.get_ticks_msec()+120000
	var frames:=0
	var maximum:=0.0
	while (main.road_rebuild_thread!=null or not main.deferred_region_edits.is_empty() or not main.development_waiting_approval.is_empty()) and Time.get_ticks_msec()<deadline:
		var start:=Time.get_ticks_usec()
		await process_frame
		maximum=maxf(maximum,(Time.get_ticks_usec()-start)/1000.0)
		if (Time.get_ticks_usec()-start)>33000:
			print("Slow frame: map %.2f ms, draw %.2f ms, chunk %.2f ms, publication %.2f ms"%[main.map_view.last_frame_process_us/1000.0,main.map_view.last_draw_us/1000.0,main.map_view.chunk_renderer.last_tick_us/1000.0,main.last_road_rebuild_publish_us/1000.0])
		frames+=1
	print("%s: %d responsive frames; maximum frame interval %.2f ms"%[label,frames,maximum])
	print("Publication %.2f ms; worker stages (us): %s"%[main.last_road_rebuild_publish_us/1000.0,main.last_road_rebuild_stages_us])
	if main.road_rebuild_thread!=null or not main.deferred_region_edits.is_empty() or not main.development_waiting_approval.is_empty(): errors.append(label+" timed out")
	if frames<2: errors.append(label+" did not allow UI frames")
	if maximum>=100.0: errors.append("%s stalled a frame for %.2f ms"%[label,maximum])

func _run() -> void:
	var main=await Fixture.attach(self,2 if OS.get_cmdline_user_args().has("--large") else 0)
	main.playing=false
	main.dev_mode_enabled=true
	main.region.dev_mode=true
	await process_frame
	var candidate_id:=-1
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id<0 and candidate.frontage_link_id>=0:
			candidate_id=candidate.id
			break
	if candidate_id<0:
		push_error("No approval fixture")
		quit(1)
		return
	main._on_map_mode_selected(2)
	main._on_candidate_selected(candidate_id)
	await Fixture.settle_map(self,main.map_view)
	await create_timer(.25).timeout
	var before=main.region
	var count:int=before.neighborhoods.size()
	var start:=Time.get_ticks_usec()
	main._apply_candidate_approval(candidate_id,true,-1,{},{})
	var action_ms:=(Time.get_ticks_usec()-start)/1000.0
	print("Approval handler %.2f ms"%action_ms)
	if action_ms>33.4: errors.append("Approval handler blocked")
	await _wait_edit(main,"Approval")
	if before.neighborhoods.size()!=count or main.region.neighborhoods.size()!=count+1:
		errors.append("Approval must publish a new world without mutating the old world")
	elif main.region.neighborhoods[-1].buildings.is_empty():
		errors.append("Approved district must contain its planned building inventory")
	main._on_map_mode_selected(0)
	var preview:Dictionary={}
	for link in main.region.road_links:
		if link.road_class!="Collector": continue
		var trial:Dictionary=Planner.link_preview(main.region,link.from_node_id,link.to_node_id,"Arterial",PackedVector2Array(),main._current_day_key())
		if trial.get("ok",false):
			preview=trial
			break
	if preview.is_empty(): errors.append("No arterial fixture")
	else:
		before=main.region
		var projects:int=before.road_projects.size()
		main.pending_road_preview=preview
		start=Time.get_ticks_usec()
		main._on_road_build_pressed()
		action_ms=(Time.get_ticks_usec()-start)/1000.0
		print("Arterial handler %.2f ms"%action_ms)
		if action_ms>33.4: errors.append("Arterial handler blocked")
		await _wait_edit(main,"Arterial")
		if before.road_projects.size()!=projects or main.region.road_projects.size()<=projects:
			errors.append("Arterial must publish funded projects without changing old world")
		if main.map_view.region!=main.region: errors.append("Map has stale world")
	# A rejected transaction must leave the live world and funds untouched.
	before=main.region
	main.pending_road_preview={"ok":false,"reason":"Regression rejection"}
	main._on_road_build_pressed()
	await _wait_edit(main,"Rejected road")
	if main.region!=before or not main.road_status_label.text.contains("Regression rejection"):
		errors.append("Rejected road must retain the live world and explain its failure")
	var keys:Array[String]=[]
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id<0 and candidate.frontage_link_id>=0:
			keys.append(candidate.key)
			if keys.size()==2: break
	count=main.region.neighborhoods.size()
	main._approve_review_keys(keys)
	await _wait_edit(main,"Batch approval")
	if main.region.neighborhoods.size()!=count+keys.size(): errors.append("Batch approval lost a district")
	keys.clear()
	var queued_ids:Array[int]=[]
	for candidate in main.region.development_candidates:
		if candidate.neighborhood_id<0 and candidate.frontage_link_id>=0:
			keys.append(candidate.key)
			queued_ids.append(candidate.id)
			if keys.size()==2: break
	count=main.region.neighborhoods.size()
	for id in queued_ids:
		main._apply_candidate_approval(id,true,-1,{},{})
	await _wait_edit(main,"Queued approvals")
	if main.region.neighborhoods.size()!=count+keys.size(): errors.append("Queued approval lost a district")
	for key in keys:
		var id:int=main.region.development_candidate_keys.get(key,-1)
		if id<0 or main.region.development_candidates[id].neighborhood_id<0:
			errors.append("Queued approval changed target: "+key)
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
