extends RefCounted

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")

const REGION_NAMES = ["North Coast", "North Interior", "South Coast", "South Interior"]
const COUNTY_NAMES = ["Bay County", "Pine County", "Mesa County", "River County", "Harbor County", "Cedar County", "Valley County", "Lake County"]
const CITY_NAMES = ["Harbor", "Midvale", "Northbank", "Eastport", "Westfield", "Cedar", "South Ridge", "Lakeside", "Port Union", "Oakview", "Sunvale", "Riverton", "Stonefield", "Brookhaven", "Clearwater", "Hillcrest"]
const ARCHETYPES = [
	{"Residential": 45, "Commercial": 10, "Office": 5, "Mixed": 30, "Industry": 10},
	{"Residential": 20, "Commercial": 30, "Office": 20, "Mixed": 25, "Industry": 5},
	{"Residential": 20, "Commercial": 15, "Office": 35, "Mixed": 25, "Industry": 5},
	{"Residential": 20, "Commercial": 10, "Office": 5, "Mixed": 15, "Industry": 50},
]
const HOUSING_YIELDS = {"Residential": [10, 35, 85], "Mixed": [5, 18, 45]}
const JOB_YIELDS = {"Commercial": [18, 45, 90], "Office": [25, 75, 150], "Mixed": [12, 35, 70], "Industry": [12, 28, 55]}
const JOB_SKILL_MIX = {"Commercial": [0.55, 0.35, 0.10], "Office": [0.10, 0.35, 0.55], "Mixed": [0.30, 0.40, 0.30], "Industry": [0.40, 0.45, 0.15]}


static func generate_region(seed_value: int):
	return _generate(seed_value, 16, 96, 4, 8, false)


static func generate_large_region(seed_value: int, city_count: int = 128, neighborhoods_per_city: int = 40):
	var county_count: int = mini(64, city_count)
	return _generate(seed_value, city_count, city_count * maxi(4, neighborhoods_per_city), mini(16, county_count), county_count, true)


static func _generate(seed_value: int, city_count: int, neighborhood_count: int, region_count: int, county_count: int, large_scale: bool):
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var region = RegionData.new()
	region.generation_seed = seed_value
	region.is_large_scale = large_scale
	var state = _add_jurisdiction(region, JurisdictionData.STATE, region.state_name, -1)
	state.income_tax_rate = 0.10
	state.treasury = 500000000.0
	var counties_per_region: PackedInt32Array = _distribute(county_count, region_count, 1, rng)
	var cities_per_county: PackedInt32Array = _distribute(city_count, county_count, 1, rng)
	var neighborhoods_per_city: PackedInt32Array = _distribute(neighborhood_count, city_count, 4, rng)
	for region_index in range(region_count):
		var region_name: String = "Region %d" % (region_index + 1) if large_scale else REGION_NAMES[region_index]
		var planning_region = _add_jurisdiction(region, JurisdictionData.REGION, region_name, state.id)
		region.region_ids.append(planning_region.id)
		for local_county in range(counties_per_region[region_index]):
			var county_index: int = region.county_ids.size()
			var county_name: String = "County %d" % (county_index + 1) if large_scale else COUNTY_NAMES[county_index]
			var county = _add_jurisdiction(region, JurisdictionData.COUNTY, county_name, planning_region.id)
			county.income_tax_rate = 0.02
			county.property_tax_rate = 0.005
			county.sales_tax_rate = 0.02
			county.treasury = 50000000.0
			region.county_ids.append(county.id)
			for local_city in range(cities_per_county[county_index]):
				var city_id: int = region.cities.size()
				var city_name: String = CITY_NAMES[city_id % CITY_NAMES.size()]
				if large_scale:
					city_name += " %d" % (city_id / CITY_NAMES.size() + 1)
				var city = _add_jurisdiction(region, JurisdictionData.CITY, city_name, county.id)
				city.treasury = 10000000.0
				region.city_jurisdiction_ids.append(city.id)
				var density: int = 2 if city_id == 0 else (1 if rng.randf() < 0.3 else 0)
				var neighborhood_ids: Array[int] = []
				for local_id in range(neighborhoods_per_city[city_id]):
					var neighborhood = NeighborhoodData.new()
					neighborhood.id = region.neighborhoods.size()
					neighborhood.city_id = city_id
					neighborhood.county_id = county_index
					neighborhood.region_id = region_index
					neighborhood.name = "%s · %d" % [city_name, local_id + 1]
					var district = _add_jurisdiction(region, JurisdictionData.NEIGHBORHOOD, neighborhood.name, city.id)
					district.treasury = 1000000.0
					district.generation_weight = pow(rng.randf_range(0.5, 1.6), 2.0)
					neighborhood.jurisdiction_id = district.id
					region.neighborhood_jurisdiction_ids.append(district.id)
					neighborhood.developable_area_ha = float(rng.randi_range(80, 130))
					neighborhood.zone_shares = ARCHETYPES[(local_id + city_id) % ARCHETYPES.size()].duplicate(true)
					for zone in RegionData.ZONE_TYPES:
						neighborhood.zone_density[zone] = clampi(density + rng.randi_range(-1, 1), 0, 2)
					region.neighborhoods.append(neighborhood)
					neighborhood_ids.append(neighborhood.id)
					var current_id: int = district.id
					while current_id >= 0:
						region.jurisdictions[current_id].neighborhood_ids.append(neighborhood.id)
						current_id = region.jurisdictions[current_id].parent_id
				region.cities.append({"id": city_id, "name": city_name, "center_km": Vector2.ZERO, "neighborhood_ids": neighborhood_ids, "county_id": county_index, "region_id": region_index, "jurisdiction_id": city.id, "density": density})
	for area in region.jurisdictions:
		if area.kind in [JurisdictionData.REGION, JurisdictionData.COUNTY, JurisdictionData.CITY]:
			area.generation_weight = pow(float(area.neighborhood_ids.size()), 0.65) * rng.randf_range(0.55, 1.8)
	StateGeography.generate(region, rng)
	for neighborhood in region.neighborhoods:
		_populate_capacity_and_occupancy(neighborhood, rng, region.cities[neighborhood.city_id]["density"])
	StateGeography.initialize_development(region)
	return region


static func _distribute(total: int, parent_count: int, minimum: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(parent_count)
	counts.fill(minimum)
	var weights := PackedFloat64Array()
	var weight_sum := 0.0
	for parent_index in range(parent_count):
		var weight: float = pow(rng.randf_range(0.25, 1.8), 2.0)
		weights.append(weight)
		weight_sum += weight
	var remaining: int = total - parent_count * minimum
	var assigned := 0
	for parent_index in range(parent_count):
		var addition: int = floori(float(remaining) * weights[parent_index] / weight_sum)
		counts[parent_index] += addition
		assigned += addition
	for remainder in range(remaining - assigned):
		counts[rng.randi_range(0, parent_count - 1)] += 1
	if parent_count > 1 and remaining > 0 and counts.count(counts[0]) == parent_count:
		counts[0] -= 1
		counts[-1] += 1
	return counts


static func _add_jurisdiction(region, kind: String, name: String, parent_id: int):
	var area = JurisdictionData.new()
	area.id = region.jurisdictions.size()
	area.kind = kind
	area.name = name
	area.parent_id = parent_id
	region.jurisdictions.append(area)
	if parent_id >= 0:
		region.jurisdictions[parent_id].child_ids.append(area.id)
	return area


static func _populate_capacity_and_occupancy(neighborhood, rng: RandomNumberGenerator, city_density: int) -> void:
	var housing_capacity := 0
	var job_capacity := 0
	var zone_job_capacity: Dictionary = {}
	for zone in RegionData.ZONE_TYPES:
		var hectares: float = neighborhood.developable_area_ha * float(neighborhood.zone_shares[zone]) / 100.0
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
