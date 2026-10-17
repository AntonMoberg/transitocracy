extends RefCounted

const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")


static func build(source_region, previous_state, unix_seconds: int) -> Dictionary:
	var region = DayCycleCalculator.copy_region(source_region)
	DevelopmentPlanner.refresh_candidates(region)
	region.city_od_candidates.clear()
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.refresh_desirability(region)
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, unix_seconds, CalendarClock.is_weekend_unix(unix_seconds))
	var traffic_state = MultiScaleTraffic.new_day(region, flow, unix_seconds, previous_state)
	return {"region": region, "flow": flow, "traffic_state": traffic_state, "errors": region.validation_errors()}
