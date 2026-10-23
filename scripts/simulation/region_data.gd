extends RefCounted

const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const UrbanRouting = preload("res://scripts/simulation/urban_routing.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")

const ZONE_TYPES = ["Residential", "Commercial", "Office", "Mixed", "Industry"]
const DENSITY_NAMES = ["Low", "Medium", "High"]

var generation_seed: int = 0
var dev_mode: bool = false
var starting_city_ids: Array[int] = []
var neighborhood_development_connected: PackedByteArray = PackedByteArray()
var is_large_scale: bool = false
var city_travel_times: Array[PackedFloat32Array] = []
var city_od_candidates: Array[PackedInt32Array] = []
var neighborhood_accessible: PackedByteArray = PackedByteArray()
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
var road_geometry_revision: int = 0
var accessibility_cost_revision: int = -1
var accessibility_link_costs: PackedVector2Array = PackedVector2Array()

# Each city has an id, name, center_km, and neighborhood_ids.
var cities: Array[Dictionary] = []
var neighborhoods: Array = []
var travel_times: Array[PackedFloat32Array] = []
var accessibility: PackedFloat32Array = PackedFloat32Array()
var road_nodes: Array = []
var road_links: Array = []
var road_projects: Array = []
var road_reservations: Array[Dictionary] = []
var neighborhood_gateway_node_ids: Array[int] = []
var city_hub_node_ids: Array[int] = []
var city_highway_access_node_ids: Array[int] = []
var city_route_node_ids: Array[int] = []
var neighborhood_spoke_link_ids: Array[int] = []
var development_candidates: Array = []
var development_candidate_keys: Dictionary = {}
var development_candidate_cells: Dictionary = {}
var development_candidate_city_ids: Dictionary = {}
var urban_route_cache: Dictionary = {}
var urban_route_revision: int = -1
var street_spatial_cache: Dictionary = {}
var road_corridor_cache: Dictionary = {}
var neighborhood_spatial_cache: Dictionary = {}
var urban_sector_claims: Dictionary = {}
var urban_block_claims: Dictionary = {}
var urban_plan_edges: Dictionary = {}
var urban_locked_junctions: Dictionary = {}
var urban_district_cells: Dictionary = {}
var urban_district_owner_cache: Dictionary = {}
var urban_valid_junction_cache: Dictionary = {}
var urban_sector_merges: Dictionary = {}
var urban_sector_merge_members: Dictionary = {}
var urban_grid_domains: Dictionary = {}
var city_border_seams: Dictionary = {}
var urban_corridors: Array[Dictionary] = []
var rail_reservations: Array[Dictionary] = []
var station_sites: Array[Dictionary] = []


func reserved_development_funds(jurisdiction_id: int = 0) -> int:
	var total := 0
	for neighborhood in neighborhoods:
		if neighborhood.development_plan == null:
			continue
		if jurisdiction_id == 0 or jurisdictions[jurisdiction_id].neighborhood_ids.has(neighborhood.id):
			total += neighborhood.development_plan.reserved
	return total


func city_id_at_point(point: Vector2) -> int:
	for city_id in range(city_jurisdiction_ids.size()):
		if jurisdictions[city_jurisdiction_ids[city_id]].contains_point(point):
			return city_id
	return -1


func development_candidate_at_point(point: Vector2) -> int:
	if RoadLand.contains_reserved(self, point):
		return -1
	var grid: Vector2i = StateGeography.cell_grid_at_point(generation_seed, point)
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			for candidate_id in development_candidate_cells.get("%d:%d" % [grid.x + offset_x, grid.y + offset_y], []):
				if JurisdictionData.polygon_contains_point(point, development_candidates[candidate_id]["polygon"]):
					return candidate_id
	for candidate in development_candidates:
		if JurisdictionData.polygon_contains_point(point, candidate["polygon"]):
			return candidate["id"]
	return -1


func travel_time_between(origin_id: int, destination_id: int) -> float:
	if not is_large_scale:
		return travel_times[origin_id][destination_id]
	if not neighborhood_accessible.is_empty() and (neighborhood_accessible[origin_id] == 0 or neighborhood_accessible[destination_id] == 0):
		return 1000000.0
	var origin = neighborhoods[origin_id]
	var destination = neighborhoods[destination_id]
	var city_minutes: float = city_travel_times[origin.city_id][destination.city_id]
	if origin.city_id == destination.city_id:
		return UrbanRouting.route(self, origin_id, destination_id)["minutes"]
	return city_minutes + UrbanRouting.hub_route(self, origin_id)["minutes"] + UrbanRouting.hub_route(self, destination_id)["minutes"]


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
		if city.contains_point(point):
			for neighborhood_id in city.neighborhood_ids:
				if neighborhoods[neighborhood_id].street_layout == null:
					continue
				var district = jurisdictions[neighborhoods[neighborhood_id].jurisdiction_id]
				if district.contains_point(point):
					return district.id
			return city.id
	for county_id in county_ids:
		if jurisdictions[county_id].contains_point(point):
			return county_id
	return 0


func road_owner_for_points(points: PackedVector2Array, road_class: String) -> int:
	if road_class in ["Collector", "Local"]:
		var city_id: int = city_id_at_point(points[floori(float(points.size()) / 2.0)])
		if city_id >= 0:
			return city_jurisdiction_ids[city_id]
	var owner_id: int = jurisdiction_at_point(points[0])
	var traveled := 0.0
	var next_sample := 5.0
	for segment in range(1, points.size()):
		var length: float = points[segment - 1].distance_to(points[segment])
		while next_sample < traveled + length:
			var point: Vector2 = points[segment - 1].lerp(points[segment], (next_sample - traveled) / length)
			owner_id = lowest_common_jurisdiction(owner_id, jurisdiction_at_point(point))
			next_sample += 5.0
		traveled += length
	owner_id = lowest_common_jurisdiction(owner_id, jurisdiction_at_point(points[-1]))
	if road_class == "Highway":
		while jurisdictions[owner_id].kind not in ["Region", "State"]:
			owner_id = jurisdictions[owner_id].parent_id
	return owner_id


func get_city_name(city_id: int) -> String:
	return str(cities[city_id]["name"])


func city_development_state(jurisdiction_id: int) -> String:
	var status := "Dormant"
	for neighborhood_id in jurisdictions[jurisdiction_id].neighborhood_ids:
		var development: String = neighborhoods[neighborhood_id].development_state
		if development == "Established":
			return development
		if development == "Developing" or (development == "Disconnected" and status == "Dormant"):
			status = development
	return status


func get_city_totals(city_id: int) -> Dictionary:
	var totals := {"population": 0, "households": 0, "housing_capacity": 0, "jobs": 0, "job_capacity": 0}
	for neighborhood_id in cities[city_id]["neighborhood_ids"]:
		var neighborhood = neighborhoods[neighborhood_id]
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
		totals["population"] += neighborhood.population
		totals["households"] += neighborhood.households
		totals["housing_capacity"] += neighborhood.housing_capacity
		totals["jobs"] += neighborhood.jobs
		totals["job_capacity"] += neighborhood.job_capacity
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
			if not starting_city_ids.is_empty() and area.polygon_km.size() < 3:
				errors.append("Jurisdiction %d lacks polygon geometry." % area_index)
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
		if neighborhood.households < 0 or neighborhood.population < 0 or neighborhood.jobs < 0 or neighborhood.households > neighborhood.housing_capacity or neighborhood.jobs > neighborhood.job_capacity:
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
		if neighborhood.development_state == "Dormant" and (neighborhood.households != 0 or neighborhood.population != 0 or neighborhood.jobs != 0 or neighborhood.average_household_wealth != 0.0):
			errors.append("Dormant neighborhood %s has occupied development." % neighborhood.name)
		var plan = neighborhood.development_plan
		if plan != null:
			var layout = neighborhood.street_layout
			if plan.reserved < 0 or plan.spent < 0 or plan.completed_phase < 0 or plan.completed_phase > 3 or plan.constructing_phase < 0 or plan.constructing_phase > 3:
				errors.append("Invalid development funding or phase in %s." % neighborhood.name)
			if layout == null or layout.city_id != neighborhood.city_id or layout.edges.size() != layout.classes.size() or layout.edges.size() != layout.phases.size() or layout.edges.size() != layout.lengths.size():
				errors.append("Invalid street layout in %s." % neighborhood.name)
			for node_id in neighborhood.access_node_ids:
				if node_id < 0 or node_id >= road_nodes.size():
					errors.append("Invalid street access in %s." % neighborhood.name)
	for candidate_id in range(development_candidates.size()):
		var candidate: Dictionary = development_candidates[candidate_id]
		var city_id: int = candidate.get("city_id", -1)
		var neighborhood_id: int = candidate.get("neighborhood_id", -1)
		if int(candidate.get("id", -1)) != candidate_id or city_id < 0 or city_id >= cities.size():
			errors.append("Invalid development candidate %d." % candidate_id)
			continue
		if neighborhood_id >= 0 and (neighborhood_id >= neighborhoods.size() or neighborhoods[neighborhood_id].city_id != city_id):
			errors.append("Candidate %d has an invalid neighborhood." % candidate_id)
	if accessibility.size() != neighborhoods.size() or (is_large_scale and city_travel_times.size() != cities.size()) or (not is_large_scale and travel_times.size() != neighborhoods.size()):
		errors.append("Travel-time or accessibility data is incomplete.")
	elif not is_large_scale:
		for row in travel_times:
			if row.size() != neighborhoods.size():
				errors.append("Travel-time matrix has an incomplete row.")
	else:
		for row in city_travel_times:
			if row.size() != cities.size():
				errors.append("City travel-time matrix has an incomplete row.")
	if not road_nodes.is_empty():
		if neighborhood_gateway_node_ids.size() != neighborhoods.size():
			errors.append("Neighborhood road gateways are incomplete.")
		for link in road_links:
			if link.from_node_id < 0 or link.to_node_id < 0 or link.from_node_id >= road_nodes.size() or link.to_node_id >= road_nodes.size() or link.length_km <= 0.0:
				errors.append("Invalid road link %d." % link.id)
			elif link.road_class == "Highway" and (not (road_nodes[link.from_node_id].is_interchange or road_nodes[link.from_node_id].kind == "Highway") or not (road_nodes[link.to_node_id].is_interchange or road_nodes[link.to_node_id].kind == "Highway")):
				errors.append("Highway %d lacks an interchange." % link.id)
			if not jurisdictions.is_empty() and (link.owner_jurisdiction_id < 0 or link.owner_jurisdiction_id >= jurisdictions.size()):
				errors.append("Road %d has an invalid owner." % link.id)
	return errors
