extends RefCounted

const ZONE_TYPES = ["Residential", "Commercial", "Office", "Mixed", "Industry"]
const DENSITY_NAMES = ["Low", "Medium", "High"]

var generation_seed: int = 0
var current_day_key: int = 0
var state_name: String = "New Meridian"
var jurisdictions: Array = []
var region_ids: Array[int] = []
var county_ids: Array[int] = []
var city_jurisdiction_ids: Array[int] = []
var neighborhood_jurisdiction_ids: Array[int] = []
var pending_policy_changes: Array[Dictionary] = []
var last_population_change: int = 0
var last_household_change: int = 0
var next_road_link_id: int = 0
var next_road_project_id: int = 0

# Each city has an id, name, center_km, and neighborhood_ids.
var cities: Array[Dictionary] = []
var neighborhoods: Array = []
var travel_times: Array[PackedFloat32Array] = []
var accessibility: PackedFloat32Array = PackedFloat32Array()
var road_nodes: Array = []
var road_links: Array = []
var road_projects: Array = []
var neighborhood_gateway_node_ids: Array[int] = []


func jurisdiction_for_neighborhood(neighborhood_id: int, kind: String):
	var current_id: int = neighborhoods[neighborhood_id].jurisdiction_id
	while current_id >= 0:
		var current = jurisdictions[current_id]
		if current.kind == kind:
			return current
		current_id = current.parent_id
	return null


func jurisdiction_for_city(city_id: int, kind: String):
	var current_id: int = city_jurisdiction_ids[city_id]
	while current_id >= 0:
		var current = jurisdictions[current_id]
		if current.kind == kind:
			return current
		current_id = current.parent_id
	return null


func lowest_common_jurisdiction(first_id: int, second_id: int) -> int:
	var ancestors: Dictionary = {}
	var current_id := first_id
	while current_id >= 0:
		ancestors[current_id] = true
		current_id = jurisdictions[current_id].parent_id
	current_id = second_id
	while current_id >= 0:
		if ancestors.has(current_id):
			return current_id
		current_id = jurisdictions[current_id].parent_id
	return 0


func funded_jurisdiction(first_id: int, second_id: int) -> int:
	var owner_id: int = lowest_common_jurisdiction(first_id, second_id)
	return 0 if jurisdictions[owner_id].kind == "Region" else owner_id


func nearest_neighborhood_id(point: Vector2) -> int:
	var nearest_id := 0
	var nearest_distance := INF
	for neighborhood in neighborhoods:
		var distance: float = point.distance_squared_to(neighborhood.position_km)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_id = neighborhood.id
	return nearest_id


func jurisdiction_at_point(point: Vector2) -> int:
	for city_id in city_jurisdiction_ids:
		var city = jurisdictions[city_id]
		if city.bounds_km.has_point(point):
			var nearest_id: int = city.neighborhood_ids[0]
			var nearest_distance := INF
			for neighborhood_id in city.neighborhood_ids:
				var distance: float = point.distance_squared_to(neighborhoods[neighborhood_id].position_km)
				if distance < nearest_distance:
					nearest_distance = distance
					nearest_id = neighborhood_id
			return neighborhoods[nearest_id].jurisdiction_id
	return neighborhoods[nearest_neighborhood_id(point)].jurisdiction_id


func road_owner_for_points(points: PackedVector2Array) -> int:
	var owner_id: int = jurisdiction_at_point(points[0])
	for segment in range(1, points.size()):
		var steps: int = maxi(1, ceili(points[segment - 1].distance_to(points[segment]) / 5.0))
		for step in range(steps + 1):
			var point: Vector2 = points[segment - 1].lerp(points[segment], float(step) / float(steps))
			owner_id = lowest_common_jurisdiction(owner_id, jurisdiction_at_point(point))
	return 0 if jurisdictions[owner_id].kind == "Region" else owner_id


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


func get_jurisdiction_totals(jurisdiction_id: int) -> Dictionary:
	var totals := {"population": 0, "households": 0, "housing_capacity": 0, "jobs": 0, "job_capacity": 0}
	for neighborhood_id in jurisdictions[jurisdiction_id].neighborhood_ids:
		var neighborhood = neighborhoods[neighborhood_id]
		for key in totals:
			totals[key] += neighborhood.get(key)
	return totals


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not jurisdictions.is_empty():
		if jurisdictions[0].kind != "State":
			errors.append("The first jurisdiction must be the state.")
		for area_index in range(jurisdictions.size()):
			var area = jurisdictions[area_index]
			if area.id != area_index or (area_index > 0 and (area.parent_id < 0 or area.parent_id >= area_index)):
				errors.append("Invalid jurisdiction parent or id at %d." % area_index)
		for neighborhood in neighborhoods:
			if neighborhood.jurisdiction_id < 0 or neighborhood.jurisdiction_id >= jurisdictions.size():
				errors.append("Neighborhood %d lacks a jurisdiction." % neighborhood.id)
				continue
			var district = jurisdictions[neighborhood.jurisdiction_id]
			if district.kind != "Neighborhood" or not district.neighborhood_ids.has(neighborhood.id):
				errors.append("Neighborhood %d has an invalid fiscal district." % neighborhood.id)
	if neighborhoods.is_empty() or cities.is_empty():
		errors.append("Region needs cities and neighborhoods.")
	var listed_neighborhoods := PackedByteArray()
	listed_neighborhoods.resize(neighborhoods.size())
	for city_index in range(cities.size()):
		var city: Dictionary = cities[city_index]
		if int(city.get("id", -1)) != city_index:
			errors.append("City ids must match their array positions.")
		for neighborhood_id in city.get("neighborhood_ids", []):
			var id: int = int(neighborhood_id)
			if id < 0 or id >= neighborhoods.size():
				errors.append("City %d has an invalid neighborhood id." % city_index)
				continue
			if listed_neighborhoods[id] != 0 or neighborhoods[id].city_id != city_index:
				errors.append("Neighborhood %d has an invalid city assignment." % id)
			listed_neighborhoods[id] = 1
	for neighborhood in neighborhoods:
		if neighborhood.id < 0 or neighborhood.id >= neighborhoods.size() or neighborhood.city_id < 0 or neighborhood.city_id >= cities.size() or listed_neighborhoods[neighborhood.id] == 0:
			errors.append("Invalid neighborhood or city id in %s." % neighborhood.name)
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
	if not road_nodes.is_empty():
		if neighborhood_gateway_node_ids.size() != neighborhoods.size():
			errors.append("Neighborhood road gateways are incomplete.")
		for link in road_links:
			if link.from_node_id < 0 or link.to_node_id < 0 or link.from_node_id >= road_nodes.size() or link.to_node_id >= road_nodes.size() or link.length_km <= 0.0:
				errors.append("Invalid road link %d." % link.id)
			elif link.road_class == "Highway" and (not road_nodes[link.from_node_id].is_interchange or not road_nodes[link.to_node_id].is_interchange):
				errors.append("Highway %d lacks an interchange." % link.id)
			if not jurisdictions.is_empty() and (link.owner_jurisdiction_id < 0 or link.owner_jurisdiction_id >= jurisdictions.size()):
				errors.append("Road %d has an invalid owner." % link.id)
	return errors
