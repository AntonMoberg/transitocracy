extends RefCounted

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")

const CITY_NAMES = ["Harbor", "Midvale", "Northbank", "Eastport", "Westfield", "Cedar", "South Ridge", "Lakeside"]
const CITY_COLUMNS = 4
const NEIGHBORHOODS_PER_CITY = 8
const NEIGHBORHOODS_PER_RING = 4
const CITY_GRID_ORIGIN = Vector2(10.0, 15.5)
const CITY_GRID_SPACING = Vector2(16.5, 27.0)
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
		var grid_column: int = city_id % CITY_COLUMNS
		var grid_row: int = floori(float(city_id) / float(CITY_COLUMNS))
		var city_center := CITY_GRID_ORIGIN + Vector2(grid_column, grid_row) * CITY_GRID_SPACING
		city_center += Vector2(rng.randf_range(-1.8, 1.8), rng.randf_range(-1.8, 1.8))
		var neighborhood_ids: Array[int] = []
		for local_id in range(NEIGHBORHOODS_PER_CITY):
			var neighborhood = NeighborhoodData.new()
			neighborhood.id = region.neighborhoods.size()
			neighborhood.city_id = city_id
			neighborhood.name = "%s %d" % [CITY_NAMES[city_id], local_id + 1]
			var outer_ring := local_id >= NEIGHBORHOODS_PER_RING
			var ring_index := local_id % NEIGHBORHOODS_PER_RING
			var angle: float = TAU * float(ring_index) / float(NEIGHBORHOODS_PER_RING) + (PI / float(NEIGHBORHOODS_PER_RING) if outer_ring else 0.0) + float(city_id) * 0.19 + rng.randf_range(-0.16, 0.16)
			var radius: float = rng.randf_range(5.0, 6.3) if outer_ring else rng.randf_range(2.5, 3.3)
			neighborhood.position_km = city_center + Vector2.from_angle(angle) * radius
			neighborhood.land_area_ha = float(rng.randi_range(80, 130))
			neighborhood.zone_shares = ARCHETYPES[(local_id + city_id) % ARCHETYPES.size()].duplicate(true)

			var base_density: int = 2 if city_id == 0 else (1 if city_id < CITY_COLUMNS else 0)
			for zone in RegionData.ZONE_TYPES:
				neighborhood.zone_density[zone] = clampi(base_density + rng.randi_range(-1, 1), 0, 2)
			_populate_capacity_and_occupancy(neighborhood, rng, base_density)
			region.neighborhoods.append(neighborhood)
			neighborhood_ids.append(neighborhood.id)

		region.cities.append({
			"id": city_id,
			"name": CITY_NAMES[city_id],
			"center_km": city_center,
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
		if zone == "Commercial":
			neighborhood.shopping_attraction += filled_jobs
		elif zone == "Mixed":
			neighborhood.shopping_attraction += filled_jobs * 0.5
		var mix: Array = JOB_SKILL_MIX[zone]
		var entry_jobs := roundi(filled_jobs * float(mix[0]))
		var professional_jobs := roundi(filled_jobs * float(mix[2]))
		neighborhood.jobs_by_skill["Entry"] += entry_jobs
		neighborhood.jobs_by_skill["Skilled"] += filled_jobs - entry_jobs - professional_jobs
		neighborhood.jobs_by_skill["Professional"] += professional_jobs
	var occupancy_ratio: float = float(neighborhood.households) / maxf(1.0, float(housing_capacity))
	neighborhood.monthly_rent = roundi(850.0 + city_density * 130.0 + occupancy_ratio * 400.0 + rng.randf_range(-80.0, 80.0))
