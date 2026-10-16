extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	var day: Dictionary = RoadTrafficCalculator.build_day(region, clock.unix_seconds)
	var serial_flow = TripFlowCalculator.build(region)
	var parallel_flow = TripFlowCalculator.build(region)
	var next_day_seconds: int = clock.unix_seconds + 86400
	var weekend: bool = CalendarClock.is_weekend_unix(next_day_seconds)
	var serial_flow_start := Time.get_ticks_usec()
	TripFlowCalculator.populate_day(serial_flow, region.generation_seed, next_day_seconds, weekend, day["flow"], false)
	var serial_flow_ms := float(Time.get_ticks_usec() - serial_flow_start) / 1000.0
	var parallel_flow_start := Time.get_ticks_usec()
	TripFlowCalculator.populate_day(parallel_flow, region.generation_seed, next_day_seconds, weekend, day["flow"], true)
	var parallel_flow_ms := float(Time.get_ticks_usec() - parallel_flow_start) / 1000.0
	print("Hourly trip demand: serial %.1f ms, parallel %.1f ms" % [serial_flow_ms, parallel_flow_ms])
	for hour in range(24):
		var same_matrices := true
		for origin_id in range(region.neighborhoods.size()):
			same_matrices = same_matrices and serial_flow.hourly_od[hour][origin_id] == parallel_flow.hourly_od[hour][origin_id]
			same_matrices = same_matrices and serial_flow.hourly_work_od[hour][origin_id] == parallel_flow.hourly_work_od[hour][origin_id]
			same_matrices = same_matrices and serial_flow.hourly_shopping_od[hour][origin_id] == parallel_flow.hourly_shopping_od[hour][origin_id]
			same_matrices = same_matrices and serial_flow.hourly_social_od[hour][origin_id] == parallel_flow.hourly_social_od[hour][origin_id]
		_check(same_matrices, "parallel hourly trip matrices must match serial hour %d" % hour)
		_check(serial_flow.hourly_trips[hour] == parallel_flow.hourly_trips[hour], "parallel hourly total must match serial hour %d" % hour)
	_check(serial_flow.peak_net_trips_by_purpose == parallel_flow.peak_net_trips_by_purpose, "parallel trip peaks must match serial peaks")
	var serial_start := Time.get_ticks_usec()
	var serial_traffic = RoadTrafficCalculator.assign_day(region, day["flow"], 24, null, false)
	var serial_ms := float(Time.get_ticks_usec() - serial_start) / 1000.0
	var parallel_start := Time.get_ticks_usec()
	var parallel_traffic = RoadTrafficCalculator.assign_day(region, day["flow"], 24, null, true)
	var parallel_ms := float(Time.get_ticks_usec() - parallel_start) / 1000.0
	print("Hourly traffic assignment: serial %.1f ms, parallel %.1f ms" % [serial_ms, parallel_ms])
	for hour in range(24):
		_check(is_equal_approx(serial_traffic.hourly_peak_ratio[hour], parallel_traffic.hourly_peak_ratio[hour]), "parallel peak ratio must match serial hour %d" % hour)
		for link_index in range(region.road_links.size()):
			_check(serial_traffic.hourly_volumes[hour][link_index].distance_to(parallel_traffic.hourly_volumes[hour][link_index]) < 0.001, "parallel volume must match serial hour %d link %d" % [hour, link_index])
			_check(serial_traffic.hourly_link_times[hour][link_index].distance_to(parallel_traffic.hourly_link_times[hour][link_index]) < 0.001, "parallel travel time must match serial hour %d link %d" % [hour, link_index])
		for origin_id in range(region.neighborhoods.size()):
			for destination_id in range(region.neighborhoods.size()):
				_check(absf(serial_traffic.hourly_pair_times[hour][origin_id][destination_id] - parallel_traffic.hourly_pair_times[hour][origin_id][destination_id]) < 0.001, "parallel route times must match serial hour %d pair %d-%d" % [hour, origin_id, destination_id])
	var current_day_key := floori(float(clock.unix_seconds) / 86400.0)
	var shortcut: Dictionary = RoadPlanner.link_preview(region, 0, 1, "Arterial", PackedVector2Array(), current_day_key)
	_check(shortcut["ok"] and RoadPlanner.commit(region, shortcut, current_day_key)["ok"], "cycle fixture must allow a second route")
	RoadPlanner.advance_day(region, int(shortcut["open_day_key"]))
	AccessibilityCalculator.recalculate(region)
	_check(not RoadGraph.is_forest(region), "cycle fixture must exercise congestion-based rerouting")
	var serial_cycle = RoadTrafficCalculator.assign_day(region, day["flow"], 4, null, false)
	var parallel_cycle = RoadTrafficCalculator.assign_day(region, day["flow"], 4, null, true)
	for hour in range(4):
		for link_index in range(region.road_links.size()):
			_check(serial_cycle.hourly_volumes[hour][link_index].distance_to(parallel_cycle.hourly_volumes[hour][link_index]) < 0.001, "parallel cycle volume must match serial hour %d link %d" % [hour, link_index])
			_check(serial_cycle.hourly_link_times[hour][link_index].distance_to(parallel_cycle.hourly_link_times[hour][link_index]) < 0.001, "parallel cycle cost must match serial hour %d link %d" % [hour, link_index])
	var snapshot = DayCycleCalculator.copy_region(region)
	snapshot.neighborhoods[0].households += 10
	snapshot.travel_times[0][1] += 2.0
	snapshot.road_links[0].lanes_per_direction += 1
	_check(snapshot.neighborhoods[0].households != region.neighborhoods[0].households and snapshot.travel_times[0][1] != region.travel_times[0][1] and snapshot.road_links[0].lanes_per_direction != region.road_links[0].lanes_per_direction, "next-day snapshot must not share mutable region data")
	var next_day_key := int(shortcut["open_day_key"]) + 1
	var expected: Dictionary = DayCycleCalculator.advance_day(DayCycleCalculator.copy_region(region), next_day_key, day["flow"], day["traffic"])
	var worker := Thread.new()
	var worker_snapshot = DayCycleCalculator.copy_region(region)
	var start_error: Error = worker.start(Callable(DayCycleCalculator, "advance_day").bind(worker_snapshot, next_day_key, day["flow"], day["traffic"]))
	_check(start_error == OK, "next-day worker must start")
	if start_error == OK:
		var calculated: Dictionary = worker.wait_to_finish()
		_check(calculated["region"].get_region_totals() == expected["region"].get_region_totals(), "background day must match synchronous migration")
		_check(is_equal_approx(calculated["region"].treasury, expected["region"].treasury), "background day must match synchronous finances")
		_check(is_equal_approx(calculated["region"].travel_times[0][1], expected["region"].travel_times[0][1]), "background day must match synchronous accessibility")
		_check(is_equal_approx(calculated["flow"].get_hourly_total(8), expected["flow"].get_hourly_total(8)), "background day must match synchronous trips")
		_check(calculated["traffic"].hourly_volumes[8][0].distance_to(expected["traffic"].hourly_volumes[8][0]) < 0.001, "background day must match synchronous road traffic")
		_check(calculated["region"].validation_errors().is_empty(), "background day must leave a valid region")
	if failures == 0:
		print("Parallel simulation smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
