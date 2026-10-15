extends RefCounted

# One aggregate update per simulated day. Income is a proxy derived from the
# local job mix; tax, housing costs, job access and amenities affect migration.
const JOB_MONTHLY_INCOME = {"Entry": 3000.0, "Skilled": 4300.0, "Professional": 6500.0}
const NEUTRAL_DESIRABILITY = 58.0
const DAILY_MIGRATION_RATE = 0.006
const RENT_RESPONSE = 0.04


static func initialize(region) -> void:
	var max_access := _maximum_access(region)
	for neighborhood in region.neighborhoods:
		var weighted_income := 0.0
		for skill in JOB_MONTHLY_INCOME:
			weighted_income += float(neighborhood.jobs_by_skill[skill]) * float(JOB_MONTHLY_INCOME[skill])
		var local_wage: float = weighted_income / maxf(1.0, float(neighborhood.jobs))
		var access_ratio: float = region.accessibility[neighborhood.id] / max_access
		neighborhood.average_monthly_income = roundi(local_wage * 1.1 * (0.85 + 0.15 * access_ratio))
		neighborhood.average_household_wealth = float(neighborhood.average_monthly_income) * 2.0
		neighborhood.people_per_household = float(neighborhood.population) / maxf(1.0, float(neighborhood.households))
		neighborhood.baseline_monthly_rent = neighborhood.monthly_rent
		neighborhood.baseline_occupancy = float(neighborhood.households) / maxf(1.0, float(neighborhood.housing_capacity))
		neighborhood.rent_level = float(neighborhood.monthly_rent)
		neighborhood.migration_remainder = 0.0
		neighborhood.last_household_change = 0
		neighborhood.last_population_change = 0
	region.last_population_change = 0
	region.last_household_change = 0
	refresh_desirability(region)


static func refresh_desirability(region) -> void:
	var max_access := _maximum_access(region)
	region.daily_tax_revenue = 0.0
	for neighborhood in region.neighborhoods:
		var after_tax_income: float = float(neighborhood.average_monthly_income) * (1.0 - region.income_tax_rate)
		var rent_burden: float = float(neighborhood.monthly_rent) / maxf(1.0, after_tax_income)
		var affordability: float = clampf((0.55 - rent_burden) / 0.35, 0.0, 1.0)
		var wealth_buffer: float = clampf(neighborhood.average_household_wealth / maxf(1.0, float(neighborhood.average_monthly_income) * 4.0), 0.0, 1.0)
		var vacancy: float = clampf(float(neighborhood.housing_capacity - neighborhood.households) / maxf(1.0, float(neighborhood.housing_capacity)) / 0.25, 0.0, 1.0)
		var amenities: float = clampf((float(neighborhood.zone_shares.get("Commercial", 0)) + 0.5 * float(neighborhood.zone_shares.get("Mixed", 0))) / 40.0, 0.0, 1.0)
		var access: float = region.accessibility[neighborhood.id] / max_access
		neighborhood.desirability = clampf(10.0 + 30.0 * access + 25.0 * affordability + 10.0 * wealth_buffer + 10.0 * vacancy + 10.0 * amenities - 30.0 * region.income_tax_rate, 0.0, 100.0)
		region.daily_tax_revenue += float(neighborhood.households * neighborhood.average_monthly_income) * region.income_tax_rate / 30.0


static func advance_day(region) -> void:
	region.last_household_change = 0
	region.last_population_change = 0
	# Calculate each neighborhood against the same opening-day state.
	refresh_desirability(region)
	for neighborhood in region.neighborhoods:
		var old_households: int = neighborhood.households
		var old_population: int = neighborhood.population
		var after_tax_income: float = float(neighborhood.average_monthly_income) * (1.0 - region.income_tax_rate)
		var monthly_surplus: float = after_tax_income - float(neighborhood.monthly_rent) - 0.35 * float(neighborhood.average_monthly_income) - 500.0
		neighborhood.average_household_wealth = clampf(neighborhood.average_household_wealth + monthly_surplus / 30.0 * 0.35, 0.0, float(neighborhood.average_monthly_income) * 12.0)

		var migration_pressure: float = (neighborhood.desirability - NEUTRAL_DESIRABILITY) / NEUTRAL_DESIRABILITY
		var exact_change: float = float(old_households) * DAILY_MIGRATION_RATE * migration_pressure + neighborhood.migration_remainder
		var requested_change: int = roundi(exact_change)
		var next_households: int = clampi(old_households + requested_change, 0, neighborhood.housing_capacity)
		neighborhood.last_household_change = next_households - old_households
		neighborhood.migration_remainder = exact_change - float(requested_change) if next_households == old_households + requested_change else 0.0
		neighborhood.households = next_households
		neighborhood.population = roundi(float(next_households) * neighborhood.people_per_household)
		neighborhood.last_population_change = neighborhood.population - old_population
		region.last_household_change += neighborhood.last_household_change
		region.last_population_change += neighborhood.last_population_change

		var occupancy: float = float(next_households) / maxf(1.0, float(neighborhood.housing_capacity))
		var rent_target: float = float(neighborhood.baseline_monthly_rent) * (1.0 + 0.9 * (occupancy - neighborhood.baseline_occupancy))
		neighborhood.rent_level = lerpf(neighborhood.rent_level, maxf(500.0, rent_target), RENT_RESPONSE)
		neighborhood.monthly_rent = roundi(neighborhood.rent_level)
	refresh_desirability(region)


static func _maximum_access(region) -> float:
	var result := 1.0
	for value in region.accessibility:
		result = maxf(result, value)
	return result
