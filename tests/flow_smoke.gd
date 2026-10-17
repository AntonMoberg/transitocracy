extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures: int = 0


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	AccessibilityCalculator.recalculate(region)
	var flow = TripFlowCalculator.build(region)
	var clock = CalendarClock.new()
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	_check(flow.daily_work_od.size() == region.neighborhoods.size(), "daily work OD matrix must match the region")
	_check(flow.hourly_od.size() == 24 and flow.hourly_shopping_od.size() == 24 and flow.hourly_social_od.size() == 24, "each day must contain 24 hourly matrices for every purpose")
	_check(flow.get_hourly_total(8, FlowProfile.WORK) > flow.get_hourly_total(5, FlowProfile.WORK), "morning work departures must follow a peak around 08:00")
	_check(flow.get_hourly_total(17, FlowProfile.WORK) > flow.get_hourly_total(14, FlowProfile.WORK), "evening work departures must follow a peak around 17:00")
	_check(flow.get_hourly_total(0, FlowProfile.SOCIAL) > 0.0, "social trips must continue through midnight")
	_check(flow.get_hourly_total(20, FlowProfile.SOCIAL) > flow.get_hourly_total(8, FlowProfile.SOCIAL), "weekday social activity must favor after-work hours")
	_check(flow.get_hourly_total(12, FlowProfile.COMMERCIAL) > 0.0, "commercial trips must contribute midday flow")
	_check(absf(flow.get_hourly_total(12) - flow.get_hourly_total(12, FlowProfile.WORK) - flow.get_hourly_total(12, FlowProfile.COMMERCIAL) - flow.get_hourly_total(12, FlowProfile.SOCIAL)) < 0.01, "all-purpose trips must equal work, commercial, and social trips")

	var morning: Array = flow.get_hour_matrix(8, FlowProfile.WORK)
	var evening: Array = flow.get_hour_matrix(17, FlowProfile.WORK)
	var morning_total: float = flow.get_hourly_total(8, FlowProfile.WORK)
	var evening_total: float = flow.get_hourly_total(17, FlowProfile.WORK)
	for home_id in range(region.neighborhoods.size()):
		for work_id in range(region.neighborhoods.size()):
			var outbound_share: float = morning[home_id][work_id] / morning_total
			var return_share: float = evening[work_id][home_id] / evening_total
			_check(absf(outbound_share - return_share) < 0.00001, "evening work flows must reverse the morning OD pairs")

	var all_daily_work := 0.0
	for row in flow.daily_work_od:
		for commuters in row:
			all_daily_work += commuters
	_check(absf(all_daily_work - flow.daily_commuters) < flow.daily_commuters * 0.001, "work OD totals must match employed commuters")
	var weekday_work_trips := _sum_hours(flow.hourly_work_trips)
	var weekday_shopping_trips := _sum_hours(flow.hourly_shopping_trips)
	_check(absf(weekday_work_trips - flow.daily_commuters * 2.0) < flow.daily_commuters * 0.001, "each weekday commuter must make an outbound and return trip")
	_check(absf(weekday_shopping_trips - flow.weekday_shopping_visits * 2.0) < flow.weekday_shopping_visits * 0.001, "each shopping visit must have a return trip")
	var first_day_peak: float = flow.get_hourly_total(8, FlowProfile.WORK)
	var halfway_total: float = flow.get_interpolated_hourly_total(8, 0.5, FlowProfile.WORK)
	_check(is_equal_approx(halfway_total, (flow.get_hourly_total(8, FlowProfile.WORK) + flow.get_hourly_total(9, FlowProfile.WORK)) * 0.5), "half-hour work demand must interpolate adjacent hourly results")
	var halfway_matrix: Array = flow.get_interpolated_hour_matrix(8, 0.5, FlowProfile.WORK)
	_check(is_equal_approx(halfway_matrix[0][1], (flow.get_hour_matrix(8, FlowProfile.WORK)[0][1] + flow.get_hour_matrix(9, FlowProfile.WORK)[0][1]) * 0.5), "OD flows must interpolate between hours")
	var next_day = TripFlowCalculator.copy_for_day(flow, region.generation_seed, clock.unix_seconds + 86400, false)
	next_day.hourly_trips[0] = 100.0
	next_day.hourly_od[0][0][1] = 100.0
	_check(is_equal_approx(flow.get_interpolated_hourly_total(23, 0.5, FlowProfile.ALL, next_day), (flow.get_hourly_total(23) + 100.0) * 0.5), "23:30 must blend into the next calendar day's midnight total")
	_check(is_equal_approx(flow.get_interpolated_hour_matrix(23, 0.5, FlowProfile.ALL, next_day)[0][1], (flow.get_hour_matrix(23)[0][1] + 100.0) * 0.5), "23:30 OD flows must blend into the next day's matrix")
	var minute_clock = CalendarClock.new()
	minute_clock.advance_simulation_seconds(1800.0)
	_check(minute_clock.get_hour() == 7 and minute_clock.get_minute() == 30 and is_equal_approx(minute_clock.get_hour_fraction(), 0.5), "clock must advance to 07:30 without an hourly jump")
	_check(minute_clock.get_display_text().contains("07:30"), "calendar must display minutes")
	minute_clock.set_time(23, 30)
	minute_clock.advance_simulation_seconds(1800.0)
	_check(minute_clock.get_hour() == 0 and minute_clock.get_minute() == 0, "clock must roll over smoothly at midnight")
	minute_clock.set_time(17, 15)
	minute_clock.set_hour(8)
	_check(minute_clock.get_hour() == 8 and minute_clock.get_minute() == 0, "setting an hour must clear prior minutes")
	minute_clock.advance_simulation_seconds(30.25)
	minute_clock.advance_simulation_seconds(29.75)
	_check(minute_clock.get_minute() == 1 and is_zero_approx(minute_clock.fractional_second), "subsecond advances must accumulate without losing simulated time")

	var total_workers := 0.0
	for neighborhood in region.neighborhoods:
		total_workers += neighborhood.households * TripFlowCalculator.WORKERS_PER_HOUSEHOLD
	var total_jobs: float = region.get_region_totals()["jobs"]
	for home_id in range(region.neighborhoods.size()):
		var row_sum := 0.0
		for commuters in flow.daily_work_od[home_id]:
			row_sum += commuters
		var expected: float = region.neighborhoods[home_id].households * TripFlowCalculator.WORKERS_PER_HOUSEHOLD * flow.daily_commuters / total_workers
		_check(absf(row_sum - expected) < maxf(1.0, expected * 0.01), "home commuter allocation must be balanced")
	for workplace_id in range(region.neighborhoods.size()):
		var column_sum := 0.0
		for row in flow.daily_work_od:
			column_sum += row[workplace_id]
		var expected: float = region.neighborhoods[workplace_id].jobs * flow.daily_commuters / total_jobs
		_check(absf(column_sum - expected) < maxf(1.0, expected * 0.01), "workplace allocation must be balanced")

	var first_day_seconds: int = clock.unix_seconds
	for _hour_step in range(4 * 24):
		clock.advance_hour()
	_check(clock.is_weekend(), "four days after the starting Tuesday must be Saturday")
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	_check(absf(_sum_hours(flow.hourly_work_trips) - flow.daily_commuters * 2.0 * TripFlowCalculator.WEEKEND_COMMUTE_FRACTION) < flow.daily_commuters * 0.001, "weekend work trips must follow the reduced attendance fraction")
	_check(absf(_sum_hours(flow.hourly_shopping_trips) - flow.weekend_shopping_visits * 2.0) < flow.weekend_shopping_visits * 0.001, "weekend shopping visits must have return trips")
	_check(flow.weekend_shopping_visits > flow.weekday_shopping_visits, "shopping demand must rise on weekends")
	_check(flow.weekend_social_visits > flow.weekday_social_visits, "social visits must rise on weekends")
	_check(flow.get_hourly_total(0, FlowProfile.SOCIAL) > 0.0, "social demand must remain active on weekend nights")
	TripFlowCalculator.populate_day(flow, region.generation_seed, first_day_seconds, false)
	_check(is_equal_approx(flow.get_hourly_total(8, FlowProfile.WORK), first_day_peak), "scrubbing back to a day must reproduce its departure curve")
	var friday_seconds: int = first_day_seconds + 3 * 86400
	var saturday_seconds: int = friday_seconds + 86400
	var saturday_flow = TripFlowCalculator.copy_for_day(flow, region.generation_seed, saturday_seconds, true)
	var saturday_departures: PackedFloat32Array = TripFlowCalculator._social_departure_hours(floori(float(saturday_seconds) / 86400.0), region.generation_seed, true)
	var friday_departures: PackedFloat32Array = TripFlowCalculator._social_departure_hours(floori(float(friday_seconds) / 86400.0), region.generation_seed, false)
	var expected_midnight_social: float = saturday_flow.weekend_social_od[0][1] * saturday_departures[0]
	for stay_index in range(TripFlowCalculator.SOCIAL_STAY_HOURS.size()):
		var departure_hour: int = 24 - TripFlowCalculator.SOCIAL_STAY_HOURS[stay_index]
		expected_midnight_social += saturday_flow.weekday_social_od[1][0] * friday_departures[departure_hour] * TripFlowCalculator.SOCIAL_STAY_SHARES[stay_index]
	_check(absf(saturday_flow.get_hour_matrix(0, FlowProfile.SOCIAL)[0][1] - expected_midnight_social) < 0.001, "Saturday midnight returns must reverse Friday residential visits")

	var empty_region = RegionData.new()
	var empty_neighborhood = NeighborhoodData.new()
	empty_neighborhood.households = 100
	empty_neighborhood.population = 250
	empty_region.neighborhoods.append(empty_neighborhood)
	AccessibilityCalculator.recalculate(empty_region)
	var empty_flow = TripFlowCalculator.build(empty_region)
	TripFlowCalculator.populate_day(empty_flow, 1, first_day_seconds, false)
	_check(empty_flow.daily_commuters == 0.0 and empty_flow.get_hourly_total(8, FlowProfile.WORK) == 0.0 and empty_flow.get_hourly_total(8, FlowProfile.COMMERCIAL) == 0.0, "a region without jobs or shops must generate no work or commercial trips")
	_check(empty_flow.get_hourly_total(20, FlowProfile.SOCIAL) > 0.0, "residents must be able to make local social visits")

	var shopping_region = _shopping_choice_region()
	AccessibilityCalculator.recalculate(shopping_region)
	var shopping_flow = TripFlowCalculator.build(shopping_region)
	_check(shopping_flow.weekday_shopping_od[0][2] > shopping_flow.weekday_shopping_od[0][1], "higher commercial density must attract more shopping trips at equal distance")
	_check(shopping_flow.weekday_shopping_od[0][0] == 0.0, "residential-only neighborhoods must not attract shopping trips")
	var social_region = _social_choice_region()
	AccessibilityCalculator.recalculate(social_region)
	var social_flow = TripFlowCalculator.build(social_region)
	_check(social_flow.weekday_social_od[0][2] > social_flow.weekday_social_od[0][1], "a more populated residential destination must attract more visits at equal distance")
	_check(social_flow.weekday_social_od[0][0] > 0.0, "visits within the home neighborhood must remain possible")

	if failures == 0:
		print("Trip flow smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _shopping_choice_region():
	var result = RegionData.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for neighborhood_id in range(3):
		var neighborhood = NeighborhoodData.new()
		neighborhood.id = neighborhood_id
		neighborhood.position_km = Vector2(0, 0) if neighborhood_id == 0 else Vector2(10 if neighborhood_id == 1 else -10, 0)
		neighborhood.land_area_ha = 100.0
		neighborhood.developable_area_ha = 100.0
		neighborhood.zone_shares = {"Residential": 100, "Commercial": 0, "Office": 0, "Mixed": 0, "Industry": 0}
		neighborhood.zone_density = {"Residential": 0, "Commercial": 0, "Office": 0, "Mixed": 0, "Industry": 0}
		if neighborhood_id != 0:
			neighborhood.zone_shares["Residential"] = 0
			neighborhood.zone_shares["Commercial"] = 100
			neighborhood.zone_density["Commercial"] = 0 if neighborhood_id == 1 else 2
		RegionGenerator._populate_capacity_and_occupancy(neighborhood, rng, 0)
		if neighborhood_id != 0:
			neighborhood.population = 0
			neighborhood.households = 0
		result.neighborhoods.append(neighborhood)
	return result


func _social_choice_region():
	var result = RegionData.new()
	for neighborhood_id in range(3):
		var neighborhood = NeighborhoodData.new()
		neighborhood.id = neighborhood_id
		neighborhood.position_km = Vector2(0, 0) if neighborhood_id == 0 else Vector2(10 if neighborhood_id == 1 else -10, 0)
		neighborhood.population = 100 if neighborhood_id < 2 else 300
		neighborhood.households = neighborhood.population / 2
		result.neighborhoods.append(neighborhood)
	return result


func _sum_hours(values: PackedFloat32Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
