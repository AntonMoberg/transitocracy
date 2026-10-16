extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")

var failures: int = 0


func _initialize() -> void:
	var first = RegionGenerator.generate_region(1729)
	var repeat = RegionGenerator.generate_region(1729)
	var other = RegionGenerator.generate_region(1730)
	AccessibilityCalculator.recalculate(first)
	AccessibilityCalculator.recalculate(repeat)
	AccessibilityCalculator.recalculate(other)

	_check(first.region_ids.size() == 4 and first.county_ids.size() == 8 and first.cities.size() == 16 and first.neighborhoods.size() == 96, "a state must generate all five administrative tiers")
	for city in first.cities:
		_check(city["neighborhood_ids"].size() == 6, "each city must contain six neighborhoods")
	for neighborhood in first.neighborhoods:
		_check(neighborhood.position_km.x >= 0.0 and neighborhood.position_km.x <= 240.0 and neighborhood.position_km.y >= 0.0 and neighborhood.position_km.y <= 160.0, "generated neighborhoods must stay inside the playable map")
		_check(first.jurisdiction_for_neighborhood(neighborhood.id, "State").id == 0 and first.jurisdiction_for_neighborhood(neighborhood.id, "County") != null, "every neighborhood must have state and county parents")
	_check(first.validation_errors().is_empty(), "generated region must pass validation")
	_check(first.neighborhoods[0].position_km == repeat.neighborhoods[0].position_km, "same seed must reproduce positions")
	_check(first.neighborhoods[0].households == repeat.neighborhoods[0].households, "same seed must reproduce population")
	_check(first.accessibility == repeat.accessibility, "same seed must reproduce accessibility")
	_check(first.neighborhoods[0].position_km != other.neighborhoods[0].position_km, "different seeds must change the map")

	var manual_population := 0
	var manual_jobs := 0
	for neighborhood in first.neighborhoods:
		manual_population += neighborhood.population
		manual_jobs += neighborhood.jobs
	var totals: Dictionary = first.get_region_totals()
	_check(totals["population"] == manual_population and totals["jobs"] == manual_jobs, "region totals must equal neighborhood totals")
	for origin_id in range(first.neighborhoods.size()):
		for destination_id in range(first.neighborhoods.size()):
			_check(is_equal_approx(first.travel_times[origin_id][destination_id], first.travel_times[destination_id][origin_id]), "road travel times must be symmetric")

	var near_region = _two_neighborhood_region(5.0)
	var far_region = _two_neighborhood_region(30.0)
	AccessibilityCalculator.recalculate(near_region)
	AccessibilityCalculator.recalculate(far_region)
	_check(near_region.accessibility[0] > far_region.accessibility[0], "equally sized closer job centers must add more accessibility")

	if failures == 0:
		print("Simulation smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _two_neighborhood_region(distance_km: float):
	var result = RegionData.new()
	var origin = NeighborhoodData.new()
	origin.position_km = Vector2.ZERO
	var destination = NeighborhoodData.new()
	destination.position_km = Vector2(distance_km, 0)
	destination.jobs = 1000
	result.neighborhoods = [origin, destination]
	return result


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
