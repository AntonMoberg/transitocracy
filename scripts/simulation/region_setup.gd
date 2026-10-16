extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")


static func build(seed_value: int, city_count: int, state_tax_rate: float) -> Dictionary:
	var region = RegionGenerator.generate_region(seed_value) if city_count == 16 else RegionGenerator.generate_large_region(seed_value, city_count, 40)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	region.jurisdictions[0].income_tax_rate = state_tax_rate
	NeighborhoodDynamics.initialize(region)
	RoadPlanner.refresh_upkeep(region)
	var clock = CalendarClock.new()
	region.current_day_key = floori(float(clock.unix_seconds) / 86400.0)
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, seed_value, clock.unix_seconds, clock.is_weekend())
	var traffic_state = MultiScaleTraffic.new_day(region, flow, clock.unix_seconds)
	NeighborhoodDynamics.refresh_desirability(region)
	return {"region": region, "flow": flow, "traffic_state": traffic_state, "clock": clock, "errors": region.validation_errors()}
