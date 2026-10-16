extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const RollingTrafficCalculator = preload("res://scripts/simulation/rolling_traffic_calculator.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")

var failures := 0


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var route_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
	var serial_routes: Dictionary = RoadGraph.route_pairs(region, route_costs, [], true, false)
	var parallel_routes: Dictionary = RoadGraph.route_pairs(region, route_costs, [], true, true)
	_check(serial_routes["times"] == parallel_routes["times"] and serial_routes["paths"] == parallel_routes["paths"], "parallel route search must preserve every travel time and path")
	var clock = CalendarClock.new()
	var serial_flow = TripFlowCalculator.build(region)
	var parallel_flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(serial_flow, region.generation_seed, clock.unix_seconds, false, null, false)
	TripFlowCalculator.populate_day(parallel_flow, region.generation_seed, clock.unix_seconds, false, null, true)
	for hour in range(24):
		_check(is_equal_approx(serial_flow.hourly_trips[hour], parallel_flow.hourly_trips[hour]), "parallel demand must equal serial demand at hour %d" % hour)
		for origin_id in range(region.neighborhoods.size()):
			_check(serial_flow.hourly_od[hour][origin_id] == parallel_flow.hourly_od[hour][origin_id], "parallel OD rows must equal serial rows at hour %d origin %d" % [hour, origin_id])
	var state = RollingTrafficCalculator.new_day(region, serial_flow)
	RollingTrafficCalculator.start_at_bin(state, 28)
	var serial_templates = RollingTrafficCalculator.fork_for_worker(state)
	var parallel_templates = RollingTrafficCalculator.fork_for_worker(state)
	serial_templates.route_paths = serial_routes["paths"]
	parallel_templates.route_paths = parallel_routes["paths"]
	RollingTrafficCalculator._build_departure_templates(region, serial_flow, serial_templates, 7, false)
	RollingTrafficCalculator._build_departure_templates(region, serial_flow, parallel_templates, 7, true)
	_check(serial_templates.departure_templates == parallel_templates.departure_templates and serial_templates.noncar_sales == parallel_templates.noncar_sales, "multi-core departure templates must match serial traffic demand and sales credits")
	var region_snapshot = DayCycleCalculator.copy_region(region)
	var state_snapshot = RollingTrafficCalculator.fork_for_worker(state)
	region_snapshot.neighborhoods[0].households += 1
	region_snapshot.jurisdictions[0].treasury += 100.0
	_check(region_snapshot.neighborhoods[0].households != region.neighborhoods[0].households and region_snapshot.jurisdictions[0].treasury != region.jurisdictions[0].treasury, "worker snapshots must not mutate the live region")
	state_snapshot.checkpoints[-1] = {}
	_check(state_snapshot.profile != state.profile and not state.checkpoints.has(-1), "traffic worker must own its mutable profile and checkpoint index")
	state_snapshot.checkpoints.erase(-1)
	var expected = RollingTrafficCalculator.advance_chunk(DayCycleCalculator.copy_region(region), serial_flow, DayCycleCalculator.copy_region(state), 32)
	var worker := Thread.new()
	var status: Error = worker.start(Callable(RollingTrafficCalculator, "advance_chunk").bind(DayCycleCalculator.copy_region(region), serial_flow, state_snapshot, 32))
	_check(status == OK, "traffic worker must start")
	if status == OK:
		var actual = worker.wait_to_finish()
		_check(state.next_bin == 28 and state.profile.recorded_bin == 28, "worker advancement must leave the live traffic checkpoint untouched")
		_check(actual.next_bin == expected.next_bin and absf(actual.departed_cars - expected.departed_cars) < 0.01 and absf(actual.completed_cars - expected.completed_cars) < 0.01, "background traffic must match serial checkpoints")
		_check(actual.profile.quarter_hour_served[31] == expected.profile.quarter_hour_served[31], "background directional flow must match serial flow")
	FiscalCalculator.queue_policy(region, region.city_jurisdiction_ids[0], "parking_fee", 8.0, clock.unix_seconds)
	var serial_region = DayCycleCalculator.copy_region(region)
	var worker_region = DayCycleCalculator.copy_region(region)
	var continuous = RollingTrafficCalculator.advance_chunk(serial_region, serial_flow, DayCycleCalculator.copy_region(state), 36)
	var first_chunk: Dictionary = RollingTrafficCalculator.advance_chunk_with_fork(worker_region, serial_flow, RollingTrafficCalculator.fork_for_worker(state), 32)
	_check(first_chunk["state"].next_bin == 32 and first_chunk["next"].next_bin == 32 and first_chunk["state"].profile != first_chunk["next"].profile, "worker must prepare the next mutable traffic fork off the UI thread")
	var chunked = RollingTrafficCalculator.advance_chunk(worker_region, serial_flow, first_chunk["next"], 36)
	_check(absf(continuous.departed_cars - chunked.departed_cars) < 0.01 and absf(continuous.completed_cars - chunked.completed_cars) < 0.01 and continuous.profile.quarter_hour_served[35] == chunked.profile.quarter_hour_served[35], "reusing a worker region across chunks must preserve due policy and traffic outcomes")
	var next_day_key: int = clock.unix_seconds / 86400 + 1
	var expected_day: Dictionary = DayCycleCalculator.advance_day(DayCycleCalculator.copy_region(region), next_day_key, serial_flow, expected.profile, expected)
	var day_worker := Thread.new()
	status = day_worker.start(Callable(DayCycleCalculator, "advance_day").bind(DayCycleCalculator.copy_region(region), next_day_key, serial_flow, expected.profile, expected))
	_check(status == OK, "day worker must start")
	if status == OK:
		var actual_day: Dictionary = day_worker.wait_to_finish()
		_check(actual_day["region"].get_region_totals() == expected_day["region"].get_region_totals(), "background daily migration must match serial migration")
		_check(is_equal_approx(actual_day["region"].jurisdictions[0].treasury, expected_day["region"].jurisdictions[0].treasury), "background daily finances must match serial finances")
		_check(actual_day["flow"].hourly_trips == expected_day["flow"].hourly_trips, "background daily demand must match serial demand")
	if failures == 0:
		print("Parallel simulation smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
