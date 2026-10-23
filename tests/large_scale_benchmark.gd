extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var city_count := 256
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--cities="):
			city_count = int(argument.trim_prefix("--cities="))
	var start_us: int = Time.get_ticks_usec()
	var result: Dictionary = RegionSetup.build(1729, city_count, 0.1)
	print("Initial build: %.1f ms" % (float(Time.get_ticks_usec() - start_us) / 1000.0))
	var region = result["region"]
	var flow = result["flow"]
	var state = result["traffic_state"]
	print("Work OD build stages: ", flow.build_timings_us)
	var work_matrix: Array = flow.compact_city_od["Work"]
	var max_origin_error := 0.0
	var total_origin_error := 0.0
	var total_origin_target := 0.0
	for city in region.cities:
		var city_id: int = city["id"]
		var target := 0.0
		for neighborhood_id in city["neighborhood_ids"]:
			target += flow.compact_origin_daily["Work"][neighborhood_id]
		var actual := 0.0
		for value in work_matrix[city_id]:
			actual += value
		max_origin_error = maxf(max_origin_error, absf(actual - target) / maxf(1.0, target))
		total_origin_error += absf(actual - target)
		total_origin_target += target
	print("Work OD max origin error: %.3f%%; aggregate absolute error: %.3f%%" % [max_origin_error * 100.0, total_origin_error / maxf(1.0, total_origin_target) * 100.0])
	if max_origin_error > 0.01:
		push_error("The compact commuter matrix did not balance within 1%.")
		quit(1)
		return
	start_us = Time.get_ticks_usec()
	var copy = RegionSnapshot.copy_region(region)
	print("Region copy: %.1f ms" % (float(Time.get_ticks_usec() - start_us) / 1000.0))
	if copy.neighborhoods[0] == region.neighborhoods[0]:
		push_error("Region snapshot shares mutable neighborhoods.")
		quit(1)
		return
	start_us = Time.get_ticks_usec()
	MultiScaleTraffic.advance(copy, flow, state, (state.day_key + 1) * 86400, MultiScaleTraffic.DAY)
	var advance_us: int = Time.get_ticks_usec() - start_us
	var next: Dictionary = MultiScaleDayCalculator.advance_day(copy, state.day_key + 1, flow, state)
	var elapsed_us: int = Time.get_ticks_usec() - start_us
	print("Day advance: %.1f ms; with next-day rebuild: %.1f ms" % [float(advance_us) / 1000.0, float(elapsed_us) / 1000.0])
	print("Next-day stages: ", next["timings_us"])
	print("Traffic stages: ", state.stage_totals_us)
	print("Size: %d neighborhoods, %d cities, %d roads" % [region.neighborhoods.size(), region.cities.size(), region.road_links.size()])
	quit(0)
