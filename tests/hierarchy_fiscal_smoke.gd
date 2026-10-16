extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures := 0


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	_check(region.region_ids.size() == 4 and region.county_ids.size() == 8 and region.cities.size() == 16 and region.neighborhoods.size() == 96, "state hierarchy must have the requested counts")
	for neighborhood in region.neighborhoods:
		var city_area = region.jurisdiction_for_neighborhood(neighborhood.id, "City")
		var county_area = region.jurisdiction_for_neighborhood(neighborhood.id, "County")
		_check(city_area.bounds_km.has_point(neighborhood.position_km) and county_area.bounds_km.has_point(neighborhood.position_km), "jurisdiction map boundaries must contain their neighborhoods")
	var home = region.neighborhoods[0]
	var county = region.jurisdiction_for_neighborhood(home.id, "County")
	var city = region.jurisdiction_for_neighborhood(home.id, "City")
	var district = region.jurisdiction_for_neighborhood(home.id, "Neighborhood")
	_check(county.id == region.county_ids[0] and city.id == region.city_jurisdiction_ids[0] and district.id == home.jurisdiction_id, "home jurisdiction lookup must follow the generated hierarchy")
	_check(is_equal_approx(FiscalCalculator.after_income_tax(region, home), home.average_monthly_income * 0.88), "state and home county income tax must stack on gross income")
	_check(is_equal_approx(FiscalCalculator.property_cost_monthly(region, home), home.assessed_home_value * county.property_tax_rate / 12.0), "property tax must enter effective housing cost")
	var state_income := 0.0
	var county_income := 0.0
	var county_property := 0.0
	for neighborhood in region.neighborhoods:
		state_income += neighborhood.households * neighborhood.average_monthly_income * 12.0 * 0.10 / 365.0
		if neighborhood.county_id == 0:
			county_income += neighborhood.households * neighborhood.average_monthly_income * 12.0 * 0.02 / 365.0
			county_property += neighborhood.households * neighborhood.assessed_home_value * 0.005 / 365.0
	_check(absf(region.jurisdictions[0].daily_income_revenue - state_income) < 0.1, "state income revenue must count each resident once")
	_check(absf(county.daily_income_revenue - county_income) < 0.1 and absf(county.daily_property_revenue - county_property) < 0.1, "county revenue must come only from its residents and homes")
	var before_profile = TripFlowCalculator.build(region)
	var before_visits := _county_visits(before_profile.weekday_shopping_od, region, 0, 0)
	county.sales_tax_rate = 0.15
	district.parking_fee = 25.0
	var after_profile = TripFlowCalculator.build(region)
	var after_visits := _county_visits(after_profile.weekday_shopping_od, region, 0, 0)
	_check(after_visits < before_visits, "higher destination sales tax must divert some shopping visits")
	_check(after_profile.weekday_social_od[1][0] < before_profile.weekday_social_od[1][0], "destination parking must reduce social attraction")
	var clock = CalendarClock.new()
	var initial_rate: float = county.income_tax_rate
	var tax_time: int = FiscalCalculator.queue_policy(region, county.id, "income_tax_rate", 0.08, clock.unix_seconds)
	var fee_time: int = FiscalCalculator.queue_policy(region, city.id, "congestion_fee", 12.0, clock.unix_seconds)
	_check(tax_time % 86400 == 0 and fee_time % 900 == 0 and fee_time < tax_time, "taxes must start at midnight and fees at the next quarter-hour")
	FiscalCalculator.apply_due_policies(region, fee_time)
	_check(is_equal_approx(county.income_tax_rate, initial_rate) and is_equal_approx(city.congestion_fee, 12.0), "quarter-hour policy application must leave tomorrow's tax unchanged")
	FiscalCalculator.apply_due_policies(region, tax_time)
	_check(is_equal_approx(county.income_tax_rate, 0.08), "county tax change must apply at midnight")
	if failures == 0:
		print("Hierarchy and fiscal smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _county_visits(matrix: Array[PackedFloat32Array], region, origin_id: int, county_index: int) -> float:
	var visits := 0.0
	for destination_id in range(region.neighborhoods.size()):
		if region.neighborhoods[destination_id].county_id == county_index:
			visits += matrix[origin_id][destination_id]
	return visits


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
