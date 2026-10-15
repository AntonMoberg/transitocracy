extends RefCounted

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")

const CITY_NAMES = ["Harbor", "Midvale", "South Ridge"]
const CITY_CENTERS = [Vector2(18, 15), Vector2(51, 17), Vector2(35, 43)]
const ARCHETYPES = [
	{"Residential": 45, "Commercial": 10, "Office": 5, "Mixed": 30, "Industry": 10},
	{"Residential": 20, "Commercial": 30, "Office": 20, "Mixed": 25, "Industry": 5},
	{"Residential": 20, "Commercial": 15, "Office": 35, "Mixed": 25, "Industry": 5},
	{"Residential": 20, "Commercial": 10, "Office": 5, "Mixed": 15, "Industry": 50},
]

# Capacities per hectare at low, medium, and high density.
const HOUSING_YIELDS = {
	"Residential": [10, 35, 85],
	"Mixed": [5, 18, 45],
}
const JOB_YIELDS = {
	"Commercial": [18, 45, 90],
	"Office": [25, 75, 150],
	"Mixed": [12, 35, 70],
	"Industry": [12, 28, 55],
}
const JOB_SKILL_MIX = {
	"Commercial": [0.55, 0.35, 0.10],
	"Office": [0.10, 0.35, 0.55],
	"Mixed": [0.30, 0.40, 0.30],
	"Industry": [0.40, 0.45, 0.15],
}


static func generate_region(seed_value: int):
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var region = RegionData.new()
	region.generation_seed = seed_value

	for city_id in range(CITY_NAMES.size()):
		var neighborhood_ids: Array[int] = []
		for local_id in range(4):
			var neighborhood = NeighborhoodData.new()
			neighborhood.id = region.neighborhoods.size()
			neighborhood.city_id = city_id
			neighborhood.name = "%s %d" % [CITY_NAMES[city_id], local_id + 1]
			var angle: float = TAU * float(local_id) / 4.0 + float(city_id) * 0.4 + rng.randf_range(-0.22, 0.22)
			var radius: float = rng.randf_range(6.0, 9.0)
			neighborhood.position_km = CITY_CENTERS[city_id] + Vector2.from_angle(angle) * radius
			neighborhood.land_area_ha = float(rng.randi_range(80, 130))
			neighborhood.zone_shares = ARCHETYPES[(local_id + city_id) % ARCHETYPES.size()].duplicate(true)

			var base_density: int = 2 - city_id
			for zone in RegionData.ZONE_TYPES:
				neighborhood.zone_density[zone] = clampi(base_density + rng.randi_range(-1, 1), 0, 2)
			_populate_capacity_and_occupancy(neighborhood, rng, base_density)
			region.neighborhoods.append(neighborhood)
			neighborhood_ids.append(neighborhood.id)

		region.cities.append({
			"id": city_id,
			"name": CITY_NAMES[city_id],
			"center_km": CITY_CENTERS[city_id],
			"neighborhood_ids": neighborhood_ids,
		})

	return region


static func _populate_capacity_and_occupancy(neighborhood, rng: RandomNumberGenerator, city_density: int) -> void:
	var housing_capacity := 0
	var job_capacity := 0
	var zone_job_capacity: Dictionary = {}
	for zone in RegionData.ZONE_TYPES:
		var hectares: float = neighborhood.land_area_ha * float(neighborhood.zone_shares[zone]) / 100.0
		var density: int = neighborhood.zone_density[zone]
		if HOUSING_YIELDS.has(zone):
			housing_capacity += roundi(hectares * float(HOUSING_YIELDS[zone][density]))
		if JOB_YIELDS.has(zone):
			var capacity := roundi(hectares * float(JOB_YIELDS[zone][density]))
			zone_job_capacity[zone] = capacity
			job_capacity += capacity

	neighborhood.housing_capacity = housing_capacity
	neighborhood.job_capacity = job_capacity
	neighborhood.households = roundi(housing_capacity * rng.randf_range(0.68, 0.88))
	neighborhood.population = roundi(neighborhood.households * rng.randf_range(2.0, 2.5))
	var job_occupancy := rng.randf_range(0.64, 0.86)
	for zone in zone_job_capacity.keys():
		var filled_jobs := roundi(int(zone_job_capacity[zone]) * job_occupancy)
		neighborhood.jobs += filled_jobs
		var mix: Array = JOB_SKILL_MIX[zone]
		var entry_jobs := roundi(filled_jobs * float(mix[0]))
		var professional_jobs := roundi(filled_jobs * float(mix[2]))
		neighborhood.jobs_by_skill["Entry"] += entry_jobs
		neighborhood.jobs_by_skill["Skilled"] += filled_jobs - entry_jobs - professional_jobs
		neighborhood.jobs_by_skill["Professional"] += professional_jobs
	var occupancy_ratio: float = float(neighborhood.households) / maxf(1.0, float(housing_capacity))
	neighborhood.monthly_rent = roundi(850.0 + city_density * 130.0 + occupancy_ratio * 400.0 + rng.randf_range(-80.0, 80.0))
