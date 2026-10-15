extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")

var failures: int = 0


func _initialize() -> void:
	var baseline = _new_region()
	var low_tax = _new_region()
	var high_tax = _new_region()
	var repeat = _new_region()
	low_tax.income_tax_rate = 0.0
	high_tax.income_tax_rate = 0.4
	repeat.income_tax_rate = 0.0
	NeighborhoodDynamics.refresh_desirability(low_tax)
	NeighborhoodDynamics.refresh_desirability(high_tax)
	NeighborhoodDynamics.refresh_desirability(repeat)
	_check(low_tax.neighborhoods[0].desirability > high_tax.neighborhoods[0].desirability, "higher income tax must lower affordability and desirability")
	var original_population: int = baseline.get_region_totals()["population"]
	var original_profile = TripFlowCalculator.build(baseline)
	for _day in range(90):
		NeighborhoodDynamics.advance_day(low_tax)
		NeighborhoodDynamics.advance_day(high_tax)
		NeighborhoodDynamics.advance_day(repeat)
	var low_population: int = low_tax.get_region_totals()["population"]
	var high_population: int = high_tax.get_region_totals()["population"]
	_check(low_population != original_population, "population must evolve over time")
	_check(low_population > high_population, "lower tax must attract or retain more residents over time")
	_check(low_tax.validation_errors().is_empty() and high_tax.validation_errors().is_empty(), "daily migration must preserve region invariants")
	var rent_changed := false
	var wealth_changed := false
	for id in range(low_tax.neighborhoods.size()):
		var neighborhood = low_tax.neighborhoods[id]
		var matching = repeat.neighborhoods[id]
		_check(neighborhood.households == matching.households and neighborhood.population == matching.population, "same seed and policy must reproduce migration")
		_check(neighborhood.households <= neighborhood.housing_capacity and neighborhood.households >= 0, "migration must respect housing capacity")
		rent_changed = rent_changed or neighborhood.monthly_rent != baseline.neighborhoods[id].monthly_rent
		wealth_changed = wealth_changed or not is_equal_approx(neighborhood.average_household_wealth, baseline.neighborhoods[id].average_household_wealth)
	_check(rent_changed and wealth_changed, "rent and household wealth must react over time")
	var updated_profile = TripFlowCalculator.build(low_tax)
	_check(not is_equal_approx(original_profile.daily_commuters, updated_profile.daily_commuters), "population changes must alter work travel demand")
	_check(not is_equal_approx(original_profile.weekday_shopping_visits, updated_profile.weekday_shopping_visits), "population changes must alter commercial travel demand")
	_check(not is_equal_approx(original_profile.weekday_social_visits, updated_profile.weekday_social_visits), "population changes must alter social travel demand")
	if failures == 0:
		print("Neighborhood dynamics smoke checks passed. Population: %d initial, %d at 0%% tax, %d at 40%% tax." % [original_population, low_population, high_population])
	quit(1 if failures > 0 else 0)


func _new_region():
	var region = RegionGenerator.generate_region(1729)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	return region


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
