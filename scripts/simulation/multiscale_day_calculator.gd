extends RefCounted

const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")


static func advance_day(region, day_key: int, previous_flow, previous_state) -> Dictionary:
	region.current_day_key = day_key
	FiscalCalculator.apply_due_policies(region, day_key * 86400)
	var roads_changed: bool = RoadPlanner.advance_day(region, day_key)
	if roads_changed:
		AccessibilityCalculator.recalculate(region)
	elif previous_flow != null and previous_state != null:
		region.travel_times = RoadTrafficCalculator.generalized_travel_times(region, previous_flow, previous_state.profile)
		AccessibilityCalculator.recalculate_jobs(region)
	NeighborhoodDynamics.advance_day(region)
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, day_key * 86400, CalendarClock.is_weekend_unix(day_key * 86400), previous_flow)
	var traffic = MultiScaleTraffic.new_day(region, flow, day_key * 86400, previous_state)
	NeighborhoodDynamics.refresh_desirability(region)
	return {"region": region, "flow": flow, "traffic_state": traffic, "traffic": traffic.profile}


static func produce_seven_day_windows(region, flow, traffic_state, buffer) -> void:
	# Publish each completed next-day snapshot while continuing to calculate
	# a seven-day window. The queue stays bounded so edits can invalidate it.
	var current_day: int = traffic_state.day_key
	while not bool(buffer.status()["cancelled"]):
		for _day_in_window in range(7):
			var status: Dictionary = buffer.status()
			while int(status["ready"]) >= 7 and not bool(status["cancelled"]):
				OS.delay_msec(10)
				status = buffer.status()
			if bool(status["cancelled"]):
				buffer.discard_ready_on_worker()
				return
			buffer.begin_day()
			MultiScaleTraffic.advance(region, flow, traffic_state, (current_day + 1) * 86400, MultiScaleTraffic.DAY)
			if bool(buffer.status()["cancelled"]):
				buffer.discard_ready_on_worker()
				return
			var next_day: int = current_day + 1
			var result: Dictionary = advance_day(region, next_day, flow, traffic_state)
			if bool(buffer.status()["cancelled"]):
				buffer.discard_ready_on_worker()
				return
			region = result["region"]
			flow = result["flow"]
			traffic_state = result["traffic_state"]
			var snapshot: Dictionary = {
				"region": DayCycleCalculator.copy_region(region),
				"flow": flow,
				"traffic_state": MultiScaleTraffic.fork_for_week(traffic_state),
			}
			if not buffer.publish(snapshot):
				buffer.discard_ready_on_worker()
				return
			current_day = next_day
	buffer.discard_ready_on_worker()
