extends SceneTree

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var deadline: int = Time.get_ticks_msec() + 10000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		push_error("Large region did not generate.")
		quit(1)
		return
	main.playing = false
	var arterial_id := -1
	for link in main.region.road_links:
		if link.road_class == "Arterial":
			arterial_id = link.id
			break
	var initial_links: int = main.region.road_links.size()
	main.pending_road_preview = RoadPlanner.demolish_preview(main.region, arterial_id)
	var started: int = Time.get_ticks_usec()
	main._on_road_build_pressed()
	var action_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	deadline = Time.get_ticks_msec() + 10000
	while main.road_rebuild_thread != null and Time.get_ticks_msec() < deadline:
		await process_frame
	var errors := PackedStringArray()
	if action_ms >= 100.0:
		errors.append("Road action blocked the UI for %.1f ms." % action_ms)
	if main.road_rebuild_thread != null:
		errors.append("Road recalculation did not finish.")
	elif main.region.road_links.size() != initial_links - 1 or main.region.neighborhood_accessible[0] == 0 or main.flow_profile.compact_origin_daily["Work"][0] <= 0.0:
		errors.append("Road recalculation must remove the selected arterial while retaining alternate street access.")
	elif main.map_view.region != main.region or main.traffic_state.link_ids.size() != main.region.road_links.size():
		errors.append("Road map or traffic state is stale after demolition.")
	print("Large road UI action: %.1f ms" % action_ms)
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
