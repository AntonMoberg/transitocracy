extends RefCounted

const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")

# One aggregate update per simulated day. Income is a proxy derived from the
# local job mix; tax, housing costs, job access and amenities affect migration.
const JOB_MONTHLY_INCOME = {"Entry": 3000.0, "Skilled": 4300.0, "Professional": 6500.0}
const NEUTRAL_DESIRABILITY = 58.0
const DAILY_MIGRATION_RATE = 0.006
const RENT_RESPONSE = 0.04
const DAILY_DEVELOPMENT_RATE = 0.01
const DAILY_DECLINE_RATE = 0.02


static func initialize(region) -> void:
	var max_access := _maximum_access(region)
	for neighborhood in region.neighborhoods:
		var weighted_income := 0.0
		var skill_mix: Dictionary = neighborhood.development_jobs_by_skill if not neighborhood.development_jobs_by_skill.is_empty() else neighborhood.jobs_by_skill
		var template_jobs := 0
		for skill in JOB_MONTHLY_INCOME:
			weighted_income += float(skill_mix[skill]) * float(JOB_MONTHLY_INCOME[skill])
			template_jobs += int(skill_mix[skill])
		var local_wage: float = weighted_income / maxf(1.0, float(template_jobs))
		var access_ratio: float = region.accessibility[neighborhood.id] / max_access
		neighborhood.development_income = roundi(local_wage * 1.1 * (0.85 + 0.15 * access_ratio))
		neighborhood.average_monthly_income = neighborhood.development_income if neighborhood.households > 0 else 0
		neighborhood.average_household_wealth = float(neighborhood.average_monthly_income) * 2.0
		if neighborhood.households > 0:
			neighborhood.people_per_household = float(neighborhood.population) / float(neighborhood.households)
		if neighborhood.baseline_monthly_rent == 0:
			neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
		neighborhood.baseline_occupancy = float(neighborhood.households) / float(neighborhood.housing_capacity) if neighborhood.households > 0 else 0.75
		neighborhood.rent_level = float(neighborhood.monthly_rent)
		neighborhood.migration_remainder = 0.0
		neighborhood.job_growth_remainder = 0.0
		neighborhood.last_household_change = 0
		neighborhood.last_population_change = 0
	region.last_population_change = 0
	region.last_household_change = 0
	FiscalCalculator.assess_homes(region)
	refresh_desirability(region)


static func refresh_desirability(region) -> void:
	var max_access := _maximum_access(region)
	FiscalCalculator.refresh_tax_estimates(region)
	for neighborhood in region.neighborhoods:
		var connected: bool = _development_connected(region, neighborhood)
		if not neighborhood.development_approved and neighborhood.households == 0 and neighborhood.jobs == 0:
			neighborhood.development_state = "Dormant"
		elif not connected:
			neighborhood.development_state = "Disconnected" if neighborhood.households > 0 or neighborhood.jobs > 0 else "Dormant"
		elif neighborhood.development_state != "Established" or neighborhood.households == 0:
			var occupancy: float = float(neighborhood.households) / maxf(1.0, float(neighborhood.housing_capacity))
			neighborhood.development_state = "Established" if occupancy >= 0.6 else "Developing"
		if neighborhood.development_state == "Dormant":
			neighborhood.desirability = 0.0
			continue
		var after_tax_income: float = FiscalCalculator.after_income_tax(region, neighborhood)
		var rent_burden: float = (float(neighborhood.monthly_rent) + FiscalCalculator.property_cost_monthly(region, neighborhood)) / maxf(1.0, after_tax_income)
		var affordability: float = clampf((0.55 - rent_burden) / 0.35, 0.0, 1.0)
		var wealth_buffer: float = clampf(neighborhood.average_household_wealth / maxf(1.0, float(neighborhood.average_monthly_income) * 4.0), 0.0, 1.0)
		var vacancy: float = clampf(float(neighborhood.housing_capacity - neighborhood.households) / maxf(1.0, float(neighborhood.housing_capacity)) / 0.25, 0.0, 1.0)
		var amenities: float = clampf((float(neighborhood.zone_shares.get("Commercial", 0)) + 0.5 * float(neighborhood.zone_shares.get("Mixed", 0))) / 40.0, 0.0, 1.0)
		var access: float = region.accessibility[neighborhood.id] / max_access
		var county = region.jurisdictions[region.county_ids[neighborhood.county_id]]
		neighborhood.desirability = clampf(10.0 + 30.0 * access + 25.0 * affordability + 10.0 * wealth_buffer + 10.0 * vacancy + 10.0 * amenities - 30.0 * (region.jurisdictions[0].income_tax_rate + county.income_tax_rate), 0.0, 100.0)


static func advance_day(region) -> void:
	region.last_household_change = 0
	region.last_population_change = 0
	# Calculate each neighborhood against the same opening-day state.
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(region.current_day_key * 86400)
	if int(date["day"]) == 1:
		FiscalCalculator.assess_homes(region)
	refresh_desirability(region)
	for neighborhood in region.neighborhoods:
		var old_households: int = neighborhood.households
		var old_population: int = neighborhood.population
		neighborhood.last_household_change = 0
		neighborhood.last_population_change = 0
		if neighborhood.development_state == "Dormant":
			continue
		var connected: bool = _development_connected(region, neighborhood)
		if connected and neighborhood.average_monthly_income == 0:
			neighborhood.average_monthly_income = neighborhood.development_income
			neighborhood.average_household_wealth = float(neighborhood.development_income) * 2.0
			neighborhood.monthly_rent = neighborhood.baseline_monthly_rent
			neighborhood.rent_level = float(neighborhood.monthly_rent)
			if neighborhood.people_per_household <= 0.0:
				neighborhood.people_per_household = 2.25
		var after_tax_income: float = FiscalCalculator.after_income_tax(region, neighborhood)
		var monthly_surplus: float = after_tax_income - float(neighborhood.monthly_rent) - FiscalCalculator.property_cost_monthly(region, neighborhood) - 0.35 * float(neighborhood.average_monthly_income) - 500.0
		neighborhood.average_household_wealth = clampf(neighborhood.average_household_wealth + monthly_surplus / 30.0 * 0.35, 0.0, float(neighborhood.average_monthly_income) * 12.0)

		var migration_pressure: float = (neighborhood.desirability - NEUTRAL_DESIRABILITY) / NEUTRAL_DESIRABILITY
		var daily_change: float = float(old_households) * DAILY_MIGRATION_RATE * migration_pressure
		if not connected:
			daily_change = -float(old_households) * DAILY_DECLINE_RATE
		elif neighborhood.development_state == "Developing":
			var city_distance: float = neighborhood.position_km.distance_to(region.cities[neighborhood.city_id]["center_km"])
			var location_factor: float = 0.02 + 0.98 * exp(-city_distance / 12.0)
			daily_change = float(neighborhood.housing_capacity) * DAILY_DEVELOPMENT_RATE * clampf(neighborhood.desirability / NEUTRAL_DESIRABILITY, 0.3, 1.0) * location_factor
		if not neighborhood.development_approved:
			daily_change = minf(daily_change, 0.0)
		var exact_change: float = daily_change + neighborhood.migration_remainder
		var requested_change: int = roundi(exact_change)
		var next_households: int = clampi(old_households + requested_change, 0, neighborhood.housing_capacity)
		neighborhood.last_household_change = next_households - old_households
		neighborhood.migration_remainder = exact_change - float(requested_change) if next_households == old_households + requested_change else 0.0
		neighborhood.households = next_households
		neighborhood.population = roundi(float(next_households) * neighborhood.people_per_household)
		neighborhood.last_population_change = neighborhood.population - old_population
		region.last_household_change += neighborhood.last_household_change
		region.last_population_change += neighborhood.last_population_change
		var daily_jobs: float = -float(neighborhood.jobs) * DAILY_DECLINE_RATE
		if connected:
			var city_distance: float = neighborhood.position_km.distance_to(region.cities[neighborhood.city_id]["center_km"])
			var location_factor: float = 0.02 + 0.98 * exp(-city_distance / 12.0)
			daily_jobs = float(neighborhood.job_capacity) * DAILY_DEVELOPMENT_RATE * location_factor if neighborhood.development_approved and neighborhood.jobs < roundi(float(neighborhood.job_capacity) * 0.7) else 0.0
		var exact_jobs: float = daily_jobs + neighborhood.job_growth_remainder
		var job_change: int = roundi(exact_jobs)
		var next_jobs: int = clampi(neighborhood.jobs + job_change, 0, neighborhood.job_capacity)
		neighborhood.job_growth_remainder = exact_jobs - float(job_change) if next_jobs == neighborhood.jobs + job_change else 0.0
		_set_jobs(neighborhood, next_jobs)
		if neighborhood.households == 0:
			neighborhood.average_monthly_income = 0
			neighborhood.average_household_wealth = 0.0

		var occupancy: float = float(next_households) / maxf(1.0, float(neighborhood.housing_capacity))
		var rent_target: float = float(neighborhood.baseline_monthly_rent) * (1.0 + 0.9 * (occupancy - neighborhood.baseline_occupancy))
		neighborhood.rent_level = lerpf(neighborhood.rent_level, maxf(500.0, rent_target), RENT_RESPONSE)
		neighborhood.monthly_rent = roundi(neighborhood.rent_level)
		if neighborhood.households == 0 and neighborhood.jobs == 0 and not connected:
			neighborhood.monthly_rent = 0
			neighborhood.assessed_home_value = 0.0
	AccessibilityCalculator.recalculate_jobs(region)
	refresh_desirability(region)


static func _development_connected(region, neighborhood) -> bool:
	if region.neighborhood_development_connected.size() == region.neighborhoods.size():
		return region.neighborhood_development_connected[neighborhood.id] != 0
	return region.starting_city_ids.is_empty() or neighborhood.initially_developed


static func _set_jobs(neighborhood, next_jobs: int) -> void:
	var mix: Dictionary = neighborhood.development_jobs_by_skill
	if mix.is_empty():
		mix = neighborhood.jobs_by_skill.duplicate()
		neighborhood.development_jobs_by_skill = mix
		neighborhood.development_retail_share = neighborhood.shopping_attraction / maxf(1.0, float(neighborhood.jobs))
	var total: int = int(mix.get("Entry", 0)) + int(mix.get("Skilled", 0)) + int(mix.get("Professional", 0))
	var entry: int = roundi(float(next_jobs) * float(mix.get("Entry", 0)) / maxf(1.0, float(total)))
	var professional: int = mini(next_jobs - entry, roundi(float(next_jobs) * float(mix.get("Professional", 0)) / maxf(1.0, float(total))))
	neighborhood.jobs = next_jobs
	neighborhood.jobs_by_skill = {"Entry": entry, "Skilled": next_jobs - entry - professional, "Professional": professional}
	neighborhood.shopping_attraction = float(next_jobs) * neighborhood.development_retail_share


static func _maximum_access(region) -> float:
	var result := 1.0
	for value in region.accessibility:
		result = maxf(result, value)
	return result
