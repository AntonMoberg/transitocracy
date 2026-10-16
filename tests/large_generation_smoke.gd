extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var start: int = Time.get_ticks_msec()
	var region = RegionGenerator.generate_large_region(1729, 128, 40)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	var clock = CalendarClock.new()
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	var traffic = MultiScaleTraffic.new_day(region, flow, clock.unix_seconds)
	var independent_fork = MultiScaleTraffic.fork_for_week(traffic)
	MultiScaleTraffic.advance(region, flow, independent_fork, clock.unix_seconds + 1, MultiScaleTraffic.SECOND)
	var fork_alias_error := false
	for rate in traffic.profile.quarter_hour_served[traffic.first_recorded_bin]:
		if rate != Vector2.ZERO:
			fork_alias_error = true
			break
	MultiScaleTraffic.advance(region, flow, traffic, clock.unix_seconds + 60, MultiScaleTraffic.SECOND)
	var first_bin: int = traffic.first_recorded_bin
	var next_bin_served := 0.0
	for rate in traffic.profile.quarter_hour_served[first_bin + 1]:
		next_bin_served += rate.x + rate.y
	MultiScaleTraffic.change_mode(region, flow, traffic, MultiScaleTraffic.SECOND, MultiScaleTraffic.MINUTE)
	MultiScaleTraffic.advance(region, flow, traffic, traffic.unix_seconds + 60, MultiScaleTraffic.MINUTE)
	MultiScaleTraffic.change_mode(region, flow, traffic, MultiScaleTraffic.MINUTE, MultiScaleTraffic.HOUR)
	MultiScaleTraffic.advance(region, flow, traffic, (traffic.unix_seconds / 3600 + 1) * 3600, MultiScaleTraffic.HOUR)
	MultiScaleTraffic.change_mode(region, flow, traffic, MultiScaleTraffic.HOUR, MultiScaleTraffic.DAY)
	traffic.stage_totals_us.clear()
	var advance_started: int = Time.get_ticks_usec()
	MultiScaleTraffic.advance(region, flow, traffic, (traffic.day_key + 1) * 86400, MultiScaleTraffic.DAY)
	print("Large traffic advance: %.1f ms" % (float(Time.get_ticks_usec() - advance_started) / 1000.0))
	print("Large traffic stages: ", traffic.stage_totals_us)
	var next_day: Dictionary = MultiScaleDayCalculator.advance_day(region, traffic.day_key + 1, flow, traffic)
	print("Large next-day stages: ", next_day["timings_us"])
	var errors: PackedStringArray = region.validation_errors()
	if not flow.is_compact or flow.compact_city_od["Work"].size() != region.cities.size() or flow.get_daily_totals()["All"] <= 0.0:
		errors.append("Large trip flow is incomplete.")
	if traffic.queues.size() != region.road_links.size() or traffic.cached_links.size() != region.road_links.size():
		errors.append("Large road traffic is incomplete.")
	if next_bin_served != 0.0:
		errors.append("Shared empty traffic bins changed before their hour was simulated.")
	if fork_alias_error:
		errors.append("Week fork changed the live traffic profile.")
	print("Large generation: %d neighborhoods, %d cities, %d links in %.2f s" % [region.neighborhoods.size(), region.cities.size(), region.road_links.size(), float(Time.get_ticks_msec() - start) / 1000.0])
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
