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
	return _generate(seed_value, 32, 32, 4, 8, false)


static func generate_large_region(seed_value: int, city_count: int = 256):
	var county_count: int = mini(64, city_count)
	return _generate(seed_value, city_count, city_count, mini(16, county_count), county_count, true)


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
	var neighborhoods_per_city: PackedInt32Array = _distribute(neighborhood_count, city_count, 1, rng)
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
	_seed_anchor_neighborhoods(region)
	for neighborhood in region.neighborhoods:
		_populate_capacity_and_occupancy(neighborhood, rng, region.cities[neighborhood.city_id]["density"])
	StateGeography.initialize_development(region)
	_cap_starting_population(region)
	return region


static func _seed_anchor_neighborhoods(region) -> void:
	for city_id in region.starting_city_ids:
		var center: Vector2 = region.cities[city_id]["center_km"]
		var origin: Vector2i = StateGeography.cell_grid_at_point(region.generation_seed, center)
		var occupied: Dictionary = {}
		for neighborhood_id in region.cities[city_id]["neighborhood_ids"]:
			occupied[region.neighborhoods[neighborhood_id].cell_grid] = true
		var added := 0
		for radius in range(1, 10):
			for offset_y in range(-radius, radius + 1):
				for offset_x in range(-radius, radius + 1):
					if maxi(absi(offset_x), absi(offset_y)) != radius or added >= 3:
						continue
					var grid := origin + Vector2i(offset_x, offset_y)
					if occupied.has(grid):
						continue
					var cell_center: Vector2 = StateGeography.cell_site(region.generation_seed, grid)
					if not region.jurisdictions[region.city_jurisdiction_ids[city_id]].contains_point(cell_center):
						continue
					var polygon: PackedVector2Array = StateGeography.cell_polygon(region, city_id, grid)
					if polygon.size() < 3 or StateGeography.polygon_area(polygon) < 0.4:
						continue
					append_neighborhood(region, city_id, polygon, grid, false)
					occupied[grid] = true
					added += 1
			if added >= 3:
				break


static func append_neighborhood(region, city_id: int, polygon: PackedVector2Array, grid: Vector2i, populate: bool = true):
	var city: Dictionary = region.cities[city_id]
	var local_id: int = city["neighborhood_ids"].size()
	var neighborhood = NeighborhoodData.new()
	neighborhood.id = region.neighborhoods.size()
	neighborhood.city_id = city_id
	neighborhood.county_id = city["county_id"]
	neighborhood.region_id = city["region_id"]
	neighborhood.name = "%s · %d" % [city["name"], local_id + 1]
	var district = _add_jurisdiction(region, JurisdictionData.NEIGHBORHOOD, neighborhood.name, city["jurisdiction_id"])
	district.polygon_km = polygon
	StateGeography.update_bounds(district)
	neighborhood.jurisdiction_id = district.id
	neighborhood.position_km = district.center_km
	neighborhood.cell_grid = grid
	neighborhood.land_area_ha = StateGeography.polygon_area(polygon) * 100.0
	neighborhood.developable_area_ha = minf(105.0, neighborhood.land_area_ha)
	var defaults: Dictionary = zone_defaults(region, city_id, grid)
	neighborhood.zone_shares = defaults["shares"]
	neighborhood.zone_density = defaults["density"]
	var local_rng := RandomNumberGenerator.new()
	local_rng.seed = absi(region.generation_seed * 1000003 + city_id * 9176 + grid.x * 7309 + grid.y * 1543 + 7919)
	region.neighborhoods.append(neighborhood)
	city["neighborhood_ids"].append(neighborhood.id)
	region.neighborhood_jurisdiction_ids.append(district.id)
	var parent_id: int = district.id
	while parent_id >= 0:
		region.jurisdictions[parent_id].neighborhood_ids.append(neighborhood.id)
		parent_id = region.jurisdictions[parent_id].parent_id
	if populate:
		_populate_capacity_and_occupancy(neighborhood, local_rng, int(city["density"]))
	return neighborhood


static func zone_defaults(region, city_id: int, grid: Vector2i) -> Dictionary:
	var shares: Dictionary = ARCHETYPES[posmod(city_id * 13 + grid.x * 7 + grid.y * 11, ARCHETYPES.size())].duplicate(true)
	var density: Dictionary = {}
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(region.generation_seed * 1000003 + city_id * 9176 + grid.x * 7309 + grid.y * 1543)
	for zone in RegionData.ZONE_TYPES:
		density[zone] = clampi(int(region.cities[city_id]["density"]) + rng.randi_range(-1, 1), 0, 2)
	return {"shares": shares, "density": density}


static func _cap_starting_population(region) -> void:
	var total: int = int(region.get_region_totals()["population"])
	if total <= 100000:
		return
	var ratio: float = 100000.0 / float(total)
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed:
			continue
		neighborhood.households = floori(float(neighborhood.households) * ratio)
		neighborhood.population = roundi(float(neighborhood.households) * neighborhood.people_per_household)
	var capped_total: int = int(region.get_region_totals()["population"])
	while capped_total > 100000:
		for neighborhood in region.neighborhoods:
			if not neighborhood.initially_developed or neighborhood.households == 0:
				continue
			var previous: int = neighborhood.population
			neighborhood.households -= 1
			neighborhood.population = roundi(float(neighborhood.households) * neighborhood.people_per_household)
			capped_total -= previous - neighborhood.population
			break


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
