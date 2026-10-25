extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = await UiFixture.attach(self, 1)
	var deadline: int = Time.get_ticks_msec() + 300000
	while main.region == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.region == null:
		_fail("Region generation timed out")
		return
	main.playing = false
	main._on_mode_selected(MultiScaleTraffic.MINUTE)
	main.playing = true
	main._process(0.5)
	main.playing = false
	var link = main.region.road_links[0]
	var live: Vector4 = main.map_view._road_sample(0, link)
	if main.map_view.road_traffic_mode != RegionMap.ROAD_LIVE or not live.is_finite() or Vector2(live.x, live.y).distance_to(main.traffic_state.last_served[0]) > 0.001:
		_fail("Minute mode did not color roads from live hourly rates")
		return
	var metrics: Dictionary = main.map_view.get_road_traffic_metrics(0, link)
	if metrics.get("label", "") != "LIVE TRAFFIC" or metrics["served"].distance_to(main.traffic_state.last_served[0]) > 0.001:
		_fail("Road inspector did not match the live road colors")
		return
	main._on_mode_selected(MultiScaleTraffic.SECOND)
	main.playing = true
	main._process(1.0)
	main.playing = false
	live = main.map_view._road_sample(0, link)
	if main.map_view.road_traffic_mode != RegionMap.ROAD_LIVE or Vector2(live.x, live.y).distance_to(main.traffic_state.last_served[0]) > 0.001:
		_fail("Second mode did not color roads from live hourly rates")
		return
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	main.playing = true
	main.simulation_credit = float((main.traffic_state.unix_seconds / 3600 + 1) * 3600 - main.traffic_state.unix_seconds)
	main._process(0.0)
	main.playing = false
	var completed_hour: int = (main.traffic_state.unix_seconds % 86400) / 3600 - 1
	var hourly: Vector4 = main.map_view._road_sample(0, link)
	if main.map_view.road_traffic_mode != RegionMap.ROAD_HOUR or main.map_view.road_history_current_hour != completed_hour or Vector2(hourly.x, hourly.y).distance_to(main.traffic_profile.hourly_served[completed_hour][0]) > 0.001:
		_fail("Hour mode did not use the completed directional hour")
		return
	main.inspected_hour = completed_hour
	main.inspected_minute = 0
	main._sync_clock_view()
	if main.map_view.road_traffic_mode != RegionMap.ROAD_HISTORY or not main.map_view._road_sample(0, link).is_finite():
		_fail("Inspecting completed traffic did not use recorded road data")
		return
	main.inspected_hour = -1
	main._sync_clock_view()
	main._on_mode_selected(MultiScaleTraffic.DAY)
	deadline = Time.get_ticks_msec() + 15000
	while main.pending_day_result_key < 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.pending_day_result_key < 0 or main.map_view.current_day_road_summary.is_empty():
		_fail("Day mode did not receive a road estimate from its worker")
		return
	var current: Dictionary = main.map_view.current_day_road_summary
	var busy_index: int = -1
	for index in range(current["served"].size()):
		if current["served"][index].length() > 0.1:
			busy_index = index
			break
	if busy_index < 0:
		_fail("Daily road estimate contained no traffic")
		return
	var road_index: int = -1
	for index in range(main.region.road_links.size()):
		if main.region.road_links[index].id == current["link_ids"][busy_index]:
			road_index = index
			break
	if road_index < 0:
		_fail("Daily estimate could not be matched to a road")
		return
	link = main.region.road_links[road_index]
	var daily: Vector4 = main.map_view._road_sample(road_index, link)
	if main.map_view.road_traffic_mode != RegionMap.ROAD_DAY or Vector2(daily.x, daily.y).distance_to(current["served"][busy_index]) > 0.001 or main.map_view._road_load_ratio(road_index, link).z < 1.0:
		_fail("Day mode did not color the actual road from its daily estimate")
		return
	metrics = main.map_view.get_road_traffic_metrics(road_index, link)
	if metrics.get("label", "") != "DAILY AVERAGE ESTIMATE" or metrics["served"].distance_to(current["served"][busy_index]) > 0.001:
		_fail("Road inspector did not match the daily road colors")
		return
	main.playing = true
	main.simulation_credit = float((main.traffic_state.day_key + 1) * 86400 - main.traffic_state.unix_seconds)
	main._process(0.0)
	main.playing = false
	if main.map_view.previous_day_road_summary.is_empty():
		_fail("Day handoff dropped the previous road colors")
		return
	deadline = Time.get_ticks_msec() + 15000
	while main.map_view.current_day_road_summary.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.map_view.current_day_road_summary.is_empty():
		_fail("Following day did not receive a road estimate")
		return
	var previous: Dictionary = main.map_view.previous_day_road_summary
	current = main.map_view.current_day_road_summary
	var previous_index: int = int(previous["by_link_id"].get(link.id, -1))
	var current_index: int = int(current["by_link_id"].get(link.id, -1))
	if previous_index >= 0 and current_index >= 0:
		main.map_view.set_day_road_fraction(0.5)
		var blended: Vector4 = main.map_view._road_sample(road_index, main.region.road_links[road_index])
		var expected: Vector2 = previous["served"][previous_index].lerp(current["served"][current_index], 0.5)
		if Vector2(blended.x, blended.y).distance_to(expected) > 0.001:
			_fail("Daily directional colors did not interpolate")
			return
	main._on_mode_selected(MultiScaleTraffic.MINUTE)
	if main.map_view.road_traffic_mode != RegionMap.ROAD_LIVE or main.map_view.current_day_road_summary.is_empty() or not main.map_view._road_sample(road_index, main.region.road_links[road_index]).is_finite():
		_fail("Minute mode lost the last valid road colors during the switch")
		return
	main.playing = true
	main._process(0.5)
	main.playing = false
	if not main.traffic_state.has_live_sample:
		_fail("Minute mode did not replace the daily estimate with live traffic")
		return
	main.map_view.set_road_traffic_mode(RegionMap.ROAD_DAY, main.traffic_state)
	main.traffic_state.day_key += 3
	var stale_day_sample: Vector4 = main.map_view._road_sample(0, main.region.road_links[0])
	if Vector2(stale_day_sample.x, stale_day_sample.y).distance_to(main.traffic_state.last_served[0]) > 0.001:
		_fail("Day mode reused a stale daily estimate after the calendar moved on")
		return
	main.map_size_selector.select(0)
	main._generate_region(1729)
	deadline = Time.get_ticks_msec() + 300000
	while main.generation_thread != null and Time.get_ticks_msec() < deadline:
		await process_frame
	if main.generation_thread != null or main.region.is_large_scale:
		_fail("Small region generation timed out")
		return
	main.playing = false
	main._on_mode_selected(MultiScaleTraffic.HOUR)
	main.playing = true
	for step in range(4):
		main._process(0.25)
	main.playing = false
	var small_hour: int = (main.traffic_state.unix_seconds % 86400) / 3600 - 1
	if main.map_view.road_history_current_hour != small_hour or absf(main.map_view._road_sample(0, main.region.road_links[0]).x - main.traffic_profile.hourly_served[small_hour][0].x) > 0.001:
		_fail("Small-region Hour mode did not use completed road traffic: hour %d/%d, flow %.3f/%.3f" % [main.map_view.road_history_current_hour, small_hour, main.map_view._road_sample(0, main.region.road_links[0]).x, main.traffic_profile.hourly_served[small_hour][0].x])
		return
	metrics = main.map_view.get_road_traffic_metrics(0, main.region.road_links[0])
	if metrics.get("label", "") != "COMPLETED HOURS" or metrics["served"].x != main.traffic_profile.hourly_served[small_hour][0].x:
		_fail("Road inspector did not match the completed-hour road colors")
		return
	print("Road colors use live, recorded, completed-hour, and daily traffic in the correct modes")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
