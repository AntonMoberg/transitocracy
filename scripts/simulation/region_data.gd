extends RefCounted

const ZONE_TYPES = ["Residential", "Commercial", "Office", "Mixed", "Industry"]
const DENSITY_NAMES = ["Low", "Medium", "High"]

var generation_seed: int = 0
var state_name: String = "New Meridian"
var region_name: String = "Central Region"
var county_name: String = "Meridian County"
var income_tax_rate: float = 0.10
var daily_tax_revenue: float = 0.0
var last_population_change: int = 0
var last_household_change: int = 0

# Each city has an id, name, center_km, and neighborhood_ids.
var cities: Array[Dictionary] = []
var neighborhoods: Array = []
var travel_times: Array[PackedFloat32Array] = []
var accessibility: PackedFloat32Array = PackedFloat32Array()


func get_city_name(city_id: int) -> String:
	return str(cities[city_id]["name"])


func get_city_totals(city_id: int) -> Dictionary:
	var totals := {"population": 0, "households": 0, "housing_capacity": 0, "jobs": 0, "job_capacity": 0}
	for neighborhood in neighborhoods:
		if neighborhood.city_id != city_id:
			continue
		totals["population"] += neighborhood.population
		totals["households"] += neighborhood.households
		totals["housing_capacity"] += neighborhood.housing_capacity
		totals["jobs"] += neighborhood.jobs
		totals["job_capacity"] += neighborhood.job_capacity
	return totals


func get_region_totals() -> Dictionary:
	var totals := {"population": 0, "households": 0, "housing_capacity": 0, "jobs": 0, "job_capacity": 0}
	for city in cities:
		var city_totals := get_city_totals(city["id"])
		for key in totals.keys():
			totals[key] += city_totals[key]
	return totals


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if neighborhoods.size() != 12 or cities.size() != 3:
		errors.append("Expected three cities and twelve neighborhoods.")
	for neighborhood in neighborhoods:
		var share_total := 0
		for zone in ZONE_TYPES:
			share_total += int(neighborhood.zone_shares.get(zone, 0))
			var density := int(neighborhood.zone_density.get(zone, -1))
			if density < 0 or density > 2:
				errors.append("Invalid density in %s: %s" % [neighborhood.name, zone])
		if share_total != 100:
			errors.append("Land shares do not total 100%% in %s." % neighborhood.name)
		if neighborhood.households < 0 or neighborhood.population < 0 or neighborhood.households > neighborhood.housing_capacity or neighborhood.jobs > neighborhood.job_capacity:
			errors.append("Invalid population or occupancy in %s." % neighborhood.name)
		if neighborhood.desirability < 0.0 or neighborhood.desirability > 100.0 or neighborhood.average_household_wealth < 0.0:
			errors.append("Invalid household dynamics in %s." % neighborhood.name)
		if neighborhood.shopping_attraction < 0.0 or neighborhood.shopping_attraction > neighborhood.jobs:
			errors.append("Shopping attraction is outside occupied jobs in %s." % neighborhood.name)
		var skill_jobs := 0
		for count in neighborhood.jobs_by_skill.values():
			skill_jobs += int(count)
		if skill_jobs != neighborhood.jobs:
			errors.append("Job skill counts do not match total jobs in %s." % neighborhood.name)
	if travel_times.size() != neighborhoods.size() or accessibility.size() != neighborhoods.size():
		errors.append("Travel-time or accessibility data is incomplete.")
	else:
		for row in travel_times:
			if row.size() != neighborhoods.size():
				errors.append("Travel-time matrix has an incomplete row.")
	return errors
