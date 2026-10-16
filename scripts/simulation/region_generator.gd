extends RefCounted

const RegionData = preload("res://scripts/simulation/region_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")

const REGION_NAMES = ["North Coast", "North Interior", "South Coast", "South Interior"]
const COUNTY_NAMES = ["Bay County", "Pine County", "Mesa County", "River County", "Harbor County", "Cedar County", "Valley County", "Lake County"]
const CITY_NAMES = ["Harbor", "Midvale", "Northbank", "Eastport", "Westfield", "Cedar", "South Ridge", "Lakeside", "Port Union", "Oakview", "Sunvale", "Riverton", "Stonefield", "Brookhaven", "Clearwater", "Hillcrest"]
const CITY_COLUMNS = 4
const NEIGHBORHOODS_PER_CITY = 6
const NEIGHBORHOODS_PER_RING = 3
const CITY_GRID_ORIGIN = Vector2(28.0, 25.0)
const CITY_GRID_SPACING = Vector2(60.0, 36.0)
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
	var state = _add_jurisdiction(region, JurisdictionData.STATE, region.state_name, -1, Vector2(120.0, 80.0))
	state.bounds_km = Rect2(0.0, 0.0, 240.0, 160.0)
	state.income_tax_rate = 0.10
	state.treasury = 500000000.0
	for region_index in range(4):
		var region_column: int = region_index % 2
		var region_row: int = region_index / 2
		var region_center := Vector2(58.0 + region_column * 120.0, 43.0 + region_row * 72.0)
		var planning_region = _add_jurisdiction(region, JurisdictionData.REGION, REGION_NAMES[region_index], state.id, region_center)
		planning_region.bounds_km = Rect2(region_column * 120.0, region_row * 80.0, 120.0, 80.0)
		region.region_ids.append(planning_region.id)
		for county_local in range(2):
			var county_index: int = region_index * 2 + county_local
			var county_center := region_center + Vector2(-30.0 if county_local == 0 else 30.0, 0.0)
			var county = _add_jurisdiction(region, JurisdictionData.COUNTY, COUNTY_NAMES[county_index], planning_region.id, county_center)
			county.bounds_km = Rect2(region_column * 120.0 + county_local * 60.0, region_row * 80.0, 60.0, 80.0)
			county.income_tax_rate = 0.02
			county.property_tax_rate = 0.005
			county.sales_tax_rate = 0.02
			county.treasury = 50000000.0
			region.county_ids.append(county.id)

	for city_id in range(CITY_NAMES.size()):
		var grid_column: int = city_id % CITY_COLUMNS
		var grid_row: int = city_id / CITY_COLUMNS
		var region_index: int = (grid_row / 2) * 2 + grid_column / 2
		var county_index: int = region_index * 2 + grid_column % 2
		var county = region.jurisdictions[region.county_ids[county_index]]
		var city_center := CITY_GRID_ORIGIN + Vector2(grid_column, grid_row) * CITY_GRID_SPACING
		city_center += Vector2(rng.randf_range(-1.8, 1.8), rng.randf_range(-1.8, 1.8))
		var city = _add_jurisdiction(region, JurisdictionData.CITY, CITY_NAMES[city_id], county.id, city_center)
		city.bounds_km = Rect2(region_index % 2 * 120.0 + grid_column % 2 * 60.0, region_index / 2 * 80.0 + grid_row % 2 * 40.0, 60.0, 40.0)
		city.treasury = 10000000.0
		region.city_jurisdiction_ids.append(city.id)
		var neighborhood_ids: Array[int] = []
		for local_id in range(NEIGHBORHOODS_PER_CITY):
			var neighborhood = NeighborhoodData.new()
			neighborhood.id = region.neighborhoods.size()
			neighborhood.city_id = city_id
			neighborhood.county_id = county_index
			neighborhood.region_id = region_index
			neighborhood.name = "%s %d" % [CITY_NAMES[city_id], local_id + 1]
			var outer_ring := local_id >= NEIGHBORHOODS_PER_RING
			var ring_index := local_id % NEIGHBORHOODS_PER_RING
			var angle: float = TAU * float(ring_index) / float(NEIGHBORHOODS_PER_RING) + (PI / float(NEIGHBORHOODS_PER_RING) if outer_ring else 0.0) + float(city_id) * 0.19 + rng.randf_range(-0.16, 0.16)
			var radius: float = rng.randf_range(5.0, 6.3) if outer_ring else rng.randf_range(2.5, 3.3)
			neighborhood.position_km = city_center + Vector2.from_angle(angle) * radius
			var district = _add_jurisdiction(region, JurisdictionData.NEIGHBORHOOD, neighborhood.name, city.id, neighborhood.position_km)
			district.treasury = 1000000.0
			neighborhood.jurisdiction_id = district.id
			region.neighborhood_jurisdiction_ids.append(district.id)
			neighborhood.land_area_ha = float(rng.randi_range(80, 130))
			neighborhood.zone_shares = ARCHETYPES[(local_id + city_id) % ARCHETYPES.size()].duplicate(true)

			var base_density: int = 2 if city_id == 0 else (1 if city_id < CITY_COLUMNS else 0)
			for zone in RegionData.ZONE_TYPES:
				neighborhood.zone_density[zone] = clampi(base_density + rng.randi_range(-1, 1), 0, 2)
			_populate_capacity_and_occupancy(neighborhood, rng, base_density)
			region.neighborhoods.append(neighborhood)
			neighborhood_ids.append(neighborhood.id)
			var current_id: int = district.id
			while current_id >= 0:
				region.jurisdictions[current_id].neighborhood_ids.append(neighborhood.id)
				current_id = region.jurisdictions[current_id].parent_id

		region.cities.append({
			"id": city_id,
			"name": CITY_NAMES[city_id],
			"center_km": city_center,
			"neighborhood_ids": neighborhood_ids,
			"county_id": county_index,
			"region_id": region_index,
			"jurisdiction_id": city.id,
		})

	return region


static func generate_large_region(seed_value: int, city_count: int = 128, neighborhoods_per_city: int = 40):
	# A benchmark-sized state with bounded local geometry and the same
	# State → Region → County → City → Neighborhood ownership model.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var region = RegionData.new()
	region.generation_seed = seed_value
	region.is_large_scale = true
	var columns: int = ceili(sqrt(float(city_count) * 2.0))
	columns = maxi(4, ceili(float(columns) / 4.0) * 4)
	var rows: int = ceili(float(city_count) / float(columns))
	rows = maxi(4, ceili(float(rows) / 4.0) * 4)
	var state_width: float = float(columns) * 20.0
	var state_height: float = float(rows) * 20.0
	var state = _add_jurisdiction(region, JurisdictionData.STATE, region.state_name, -1, Vector2(state_width, state_height) * 0.5)
	state.bounds_km = Rect2(0.0, 0.0, state_width, state_height)
	state.income_tax_rate = 0.10
	state.treasury = 500000000.0
	for region_row in range(4):
		for region_column in range(4):
			var region_index: int = region_row * 4 + region_column
			var region_bounds := Rect2(float(region_column) * state_width / 4.0, float(region_row) * state_height / 4.0, state_width / 4.0, state_height / 4.0)
			var planning_region = _add_jurisdiction(region, JurisdictionData.REGION, "Region %d" % (region_index + 1), state.id, region_bounds.get_center())
			planning_region.bounds_km = region_bounds
			region.region_ids.append(planning_region.id)
			for county_row in range(2):
				for county_column in range(2):
					var county_index: int = region_index * 4 + county_row * 2 + county_column
					var county_bounds := Rect2(region_bounds.position + Vector2(county_column, county_row) * region_bounds.size * 0.5, region_bounds.size * 0.5)
					var county = _add_jurisdiction(region, JurisdictionData.COUNTY, "County %d" % (county_index + 1), planning_region.id, county_bounds.get_center())
					county.bounds_km = county_bounds
					county.income_tax_rate = 0.02
					county.property_tax_rate = 0.005
					county.sales_tax_rate = 0.02
					county.treasury = 50000000.0
					region.county_ids.append(county.id)
	for city_id in range(city_count):
		var grid_column: int = city_id % columns
		var grid_row: int = city_id / columns
		var region_column: int = mini(3, grid_column * 4 / columns)
		var region_row: int = mini(3, grid_row * 4 / rows)
		var region_index: int = region_row * 4 + region_column
		var county_column: int = mini(1, (grid_column * 8 / columns) % 2)
		var county_row: int = mini(1, (grid_row * 8 / rows) % 2)
		var county_index: int = region_index * 4 + county_row * 2 + county_column
		var county = region.jurisdictions[region.county_ids[county_index]]
		var city_center := Vector2((float(grid_column) + 0.5) * 20.0, (float(grid_row) + 0.5) * 20.0)
		var city_name: String = "%s %d" % [CITY_NAMES[city_id % CITY_NAMES.size()], city_id / CITY_NAMES.size() + 1]
		var city = _add_jurisdiction(region, JurisdictionData.CITY, city_name, county.id, city_center)
		city.bounds_km = Rect2(city_center - Vector2(10.0, 10.0), Vector2(20.0, 20.0))
		city.treasury = 10000000.0
		region.city_jurisdiction_ids.append(city.id)
		var neighborhood_ids: Array[int] = []
		for local_id in range(neighborhoods_per_city):
			var neighborhood = NeighborhoodData.new()
			neighborhood.id = region.neighborhoods.size()
			neighborhood.city_id = city_id
			neighborhood.county_id = county_index
			neighborhood.region_id = region_index
			neighborhood.name = "%s · %d" % [city_name, local_id + 1]
			var angle: float = float(local_id) * 2.3999632 + rng.randf_range(-0.05, 0.05)
			var radius: float = 1.0 + 7.0 * sqrt(float(local_id + 0.5) / float(neighborhoods_per_city))
			neighborhood.position_km = city_center + Vector2.from_angle(angle) * radius
			var district = _add_jurisdiction(region, JurisdictionData.NEIGHBORHOOD, neighborhood.name, city.id, neighborhood.position_km)
			district.treasury = 1000000.0
			neighborhood.jurisdiction_id = district.id
			region.neighborhood_jurisdiction_ids.append(district.id)
			neighborhood.land_area_ha = float(rng.randi_range(80, 130))
			neighborhood.zone_shares = ARCHETYPES[(local_id + city_id) % ARCHETYPES.size()].duplicate(true)
			var base_density: int = 2 if city_id % 8 == 0 else (1 if city_id % 8 < 3 else 0)
			for zone in RegionData.ZONE_TYPES:
				neighborhood.zone_density[zone] = clampi(base_density + rng.randi_range(-1, 1), 0, 2)
			_populate_capacity_and_occupancy(neighborhood, rng, base_density)
			region.neighborhoods.append(neighborhood)
			neighborhood_ids.append(neighborhood.id)
			var current_id: int = district.id
			while current_id >= 0:
				region.jurisdictions[current_id].neighborhood_ids.append(neighborhood.id)
				current_id = region.jurisdictions[current_id].parent_id
		region.cities.append({"id": city_id, "name": city_name, "center_km": city_center, "neighborhood_ids": neighborhood_ids, "county_id": county_index, "region_id": region_index, "jurisdiction_id": city.id})
	return region


static func _add_jurisdiction(region, kind: String, name: String, parent_id: int, center: Vector2):
	var area = JurisdictionData.new()
	area.id = region.jurisdictions.size()
	area.kind = kind
	area.name = name
	area.parent_id = parent_id
	area.center_km = center
	region.jurisdictions.append(area)
	if parent_id >= 0:
		region.jurisdictions[parent_id].child_ids.append(area.id)
	return area


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
