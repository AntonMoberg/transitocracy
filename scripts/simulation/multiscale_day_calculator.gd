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
const RoadTrafficSummary = preload("res://scripts/simulation/road_traffic_summary.gd")


static func advance_day(region, day_key: int, previous_flow, previous_state) -> Dictionary:
	var stage_start: int = Time.get_ticks_usec()
	var timings: Dictionary = {}
	region.current_day_key = day_key
	FiscalCalculator.apply_due_policies(region, day_key * 86400)
	var roads_changed: bool = RoadPlanner.advance_day(region, day_key)
	if roads_changed:
		region.city_od_candidates.clear()
		AccessibilityCalculator.recalculate(region)
	elif previous_flow != null and previous_state != null:
		if region.is_large_scale:
			var costs := PackedVector2Array()
			costs.resize(region.road_links.size())
			for row in previous_state.profile.hourly_link_times:
				for link_index in range(costs.size()):
					costs[link_index] += row[link_index] / 24.0
			AccessibilityCalculator.recalculate_large_with_costs(region, costs)
		else:
			region.travel_times = RoadTrafficCalculator.generalized_travel_times(region, previous_flow, previous_state.profile)
			AccessibilityCalculator.recalculate_jobs(region)
	timings["accessibility"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	NeighborhoodDynamics.advance_day(region)
	timings["economy"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	var flow = TripFlowCalculator.build(region)
	timings["flow_build"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	TripFlowCalculator.populate_day(flow, region.generation_seed, day_key * 86400, CalendarClock.is_weekend_unix(day_key * 86400), previous_flow)
	timings["flow_hours"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	var traffic = MultiScaleTraffic.new_day(region, flow, day_key * 86400, previous_state)
	timings["traffic_new_day"] = Time.get_ticks_usec() - stage_start
	NeighborhoodDynamics.refresh_desirability(region)
	var totals: Dictionary = region.get_region_totals()
	var balance := 0.0
	var net := 0.0
	for area in region.jurisdictions:
		if area.kind == "Region":
			continue
		balance += area.treasury
		net += area.daily_revenue() - area.daily_road_upkeep
	var summary_stats := {"population": totals["population"], "jobs": totals["jobs"], "balance": balance, "net": net}
	return {"region": region, "flow": flow, "traffic_state": traffic, "traffic": traffic.profile, "summary_stats": summary_stats, "timings_us": timings}


static func produce_seven_day_windows(region, flow, traffic_state, buffer) -> void:
	# Publish each completed next-day snapshot while continuing to calculate
	# a seven-day window. The queue stays bounded so edits can invalidate it.
	region = DayCycleCalculator.copy_region(region)
	buffer.mark_snapshot_ready()
	if bool(buffer.status()["cancelled"]):
		return
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
			var stage_start: int = Time.get_ticks_usec()
			MultiScaleTraffic.advance(region, flow, traffic_state, (current_day + 1) * 86400, MultiScaleTraffic.DAY)
			var traffic_us: int = Time.get_ticks_usec() - stage_start
			var completed_road_day: Dictionary = RoadTrafficSummary.completed_day(traffic_state)
			if bool(buffer.status()["cancelled"]):
				buffer.discard_ready_on_worker()
				return
			var next_day: int = current_day + 1
			var result: Dictionary = advance_day(region, next_day, flow, traffic_state)
			result["timings_us"]["traffic_advance"] = traffic_us
			if bool(buffer.status()["cancelled"]):
				buffer.discard_ready_on_worker()
				return
			region = result["region"]
			flow = result["flow"]
			traffic_state = result["traffic_state"]
			stage_start = Time.get_ticks_usec()
			var snapshot: Dictionary = {
				"region": DayCycleCalculator.copy_region(region),
				"flow": flow,
				"traffic_state": MultiScaleTraffic.fork_for_week(traffic_state),
				"completed_road_day": completed_road_day,
				"summary_stats": result["summary_stats"],
				"timings_us": result["timings_us"],
			}
			snapshot["timings_us"]["snapshot"] = Time.get_ticks_usec() - stage_start
			if not buffer.publish(snapshot):
				buffer.discard_ready_on_worker()
				return
			current_day = next_day
