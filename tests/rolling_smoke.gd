extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const RollingTrafficCalculator = preload("res://scripts/simulation/rolling_traffic_calculator.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures := 0


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, false)
	var first = RollingTrafficCalculator.new_day(region, flow)
	RollingTrafficCalculator.start_at_bin(first, 28)
	var repeated = DayCycleCalculator.copy_region(first)
	RollingTrafficCalculator.step_bin(region, flow, first)
	var held_checkpoint: Dictionary = first.checkpoints[29]
	var held_scheduled: float = _scheduled_total(held_checkpoint["scheduled"])
	for _step in range(7):
		RollingTrafficCalculator.step_bin(region, flow, first)
	RollingTrafficCalculator.advance_chunk(region, flow, repeated, 36)
	_check(first.next_bin == 36 and repeated.next_bin == 36, "rolling calculation must advance only the requested bins")
	_check(absf(_scheduled_total(held_checkpoint["scheduled"]) - held_scheduled) < 0.01, "later bins must not mutate an earlier traffic checkpoint")
	_check(first.first_recorded_bin == 28 and first.profile.recorded_bin == 36, "traffic profile must mark the calculated 15-minute window")
	_check(absf(first.departed_cars - repeated.departed_cars) < 0.01 and absf(first.completed_cars - repeated.completed_cars) < 0.01, "chunking must not change traffic outcomes")
	_check(absf(first.departed_cars - first.completed_cars - first.queued_cars() - first.scheduled_cars() - first.stranded_cars()) < 0.1, "cars must be conserved across completed, queued, moving, and stranded cohorts")
	_check(first.profile.quarter_hour_served[28].size() == region.road_links.size() and first.profile.quarter_hour_queues[35].size() == region.road_links.size(), "each recorded bin must contain directional road flow and queues")
	var fee_region = DayCycleCalculator.copy_region(region)
	for link in fee_region.road_links:
		link.toll_forward = 10.0
		link.toll_reverse = 10.0
	var fee_flow = TripFlowCalculator.build(fee_region)
	TripFlowCalculator.populate_day(fee_flow, fee_region.generation_seed, clock.unix_seconds, false)
	var tolled = RollingTrafficCalculator.new_day(fee_region, fee_flow)
	RollingTrafficCalculator.start_at_bin(tolled, 28)
	RollingTrafficCalculator.advance_chunk(fee_region, fee_flow, tolled, 36)
	_check(tolled.departed_cars < first.departed_cars, "road tolls must reduce car use")
	_check(_fee_revenue(tolled) > 0.0, "road users must pay directional tolls when a link serves them")
	var next_day = RollingTrafficCalculator.new_day(region, flow, first)
	_check(absf(next_day.queued_cars() + next_day.scheduled_cars() + next_day.stranded_cars() - (first.queued_cars() + first.scheduled_cars() + first.stranded_cars())) < 0.1, "overnight traffic must carry into the next day")
	var before_edit: float = first.queued_cars() + first.scheduled_cars() + first.stranded_cars()
	RoadPlanner.demolish(region, region.road_links[0].id)
	AccessibilityCalculator.recalculate(region)
	var edited_flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(edited_flow, region.generation_seed, clock.unix_seconds, false)
	var edited = RollingTrafficCalculator.after_network_edit(region, edited_flow, first, first.checkpoints[36])
	_check(absf(edited.queued_cars() + edited.scheduled_cars() + edited.stranded_cars() - before_edit) < 0.1, "demolition must reroute or strand existing cars without deleting them")
	if failures == 0:
		print("Rolling traffic smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _fee_revenue(state) -> float:
	var result := 0.0
	for bin_entries in state.revenue_by_bin.values():
		for entry in bin_entries.values():
			result += float(entry["fee"])
	return result


func _scheduled_total(scheduled: Dictionary) -> float:
	var total := 0.0
	for arrivals in scheduled.values():
		for cohort in arrivals:
			total += float(cohort["count"])
	return total


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
