extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const DevelopmentBudget = preload("res://scripts/simulation/development_budget.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for city_count in [32, 256, 768]:
		for seed_value in [1729, 1730, 42]:
			var setup: Dictionary = RegionSetup.build(seed_value, city_count, 0.1)
			var region = setup["region"]
			_check(setup["errors"].is_empty(), "generated region must validate: %d/%d %s" % [city_count, seed_value, setup["errors"]])
			_check(region.starting_city_ids.size() == 10, "ten anchor cities must start populated")
			_check(region.neighborhoods.size() == city_count + 30, "only seed and anchor neighborhoods should be simulated at launch")
			_check(region.road_links.size() >= 49, "arterial trunks and nine highways should connect the starting neighborhoods")
			for city_id in region.starting_city_ids:
				var hub_id: int = region.city_hub_node_ids[city_id]
				var feeder_count := 0
				for link in region.road_links:
					if link.road_class == "Arterial" and (link.from_node_id == hub_id or link.to_node_id == hub_id):
						feeder_count += 1
				_check(feeder_count >= 1 and feeder_count <= 4 and region.city_highway_access_node_ids[city_id] != hub_id, "every starting center must reach a separate highway exit")
			_check(int(region.get_region_totals()["population"]) <= 100000, "launch population must stay below 100,000")
			var developed := 0
			for neighborhood in region.neighborhoods:
				var district = region.jurisdictions[neighborhood.jurisdiction_id]
				_check(district.polygon_km.size() >= 3 and StateGeography.polygon_area(district.polygon_km) <= 4.001, "neighborhood area must remain near 2 by 2 km")
				_check(region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]].contains_point(neighborhood.position_km), "neighborhood must belong to its city")
				if neighborhood.initially_developed:
					developed += 1
					_check(neighborhood.access_node_ids.size() >= 2 and region.neighborhood_development_connected[neighborhood.id] != 0, "developed neighborhoods must reach the arterial network through multiple streets: seed %d, %d cities, district %d" % [seed_value, city_count, neighborhood.id])
					_check(neighborhood.development_approved and neighborhood.population > 0, "anchor cells must start approved and populated")
				else:
					_check(not neighborhood.development_approved and neighborhood.population == 0 and neighborhood.jobs == 0, "other city seed cells stay empty")
			_check(developed == 40, "four neighborhoods per anchor city must be developed")
			_check(region.development_candidates.size() > 40, "initial arterials must expose road-frontage candidates")
			var checked_polygon_edge := false
			var rectangular_open_plans := 0
			for candidate in region.development_candidates:
				_check(StateGeography.polygon_area(candidate["polygon"]) <= 4.001, "candidate %s area %.3f km² must remain near 2 by 2 km" % [candidate["key"], StateGeography.polygon_area(candidate["polygon"])])
				_check(JurisdictionData.polygon_contains_point(candidate["center_km"], candidate["polygon"]), "candidate center must remain inside its irregular cell")
				if not candidate["key"].contains("face:") and _rectangular(candidate["polygon"]):
					rectangular_open_plans += 1
				if checked_polygon_edge:
					continue
				for vertex in candidate["polygon"]:
					var point: Vector2 = vertex.lerp(candidate["center_km"], 0.08)
					if JurisdictionData.polygon_contains_point(point, candidate["polygon"]):
						_check(region.development_candidate_at_point(point) == candidate["id"], "candidate lookup must include angled polygon edges")
						checked_polygon_edge = true
						break
			_check(checked_polygon_edge, "road-frontage polygon edges should be selectable")
			_check(rectangular_open_plans == 0, "open arterial corridors should create irregular neighbourhood boundaries")
			_check_administrative_coverage(region)
	_check_approval()
	_check_new_road_candidates()
	_check_coastal_routing()
	if failures == 0:
		print("State geography and zoning approval smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check_administrative_coverage(region) -> void:
	for area in region.jurisdictions:
		if area.kind not in ["State", "Region", "County"]:
			continue
		var children_area := 0.0
		for child_id in area.child_ids:
			children_area += StateGeography.polygon_area(region.jurisdictions[child_id].polygon_km)
		_check(absf(children_area - StateGeography.polygon_area(area.polygon_km)) < 0.2, "state, region and county boundaries must still tile")


func _check_approval() -> void:
	var region = RegionSetup.build(1729, 256, 0.1)["region"]
	var candidate_id := -1
	var best_distance := INF
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or int(candidate["frontage_link_id"]) < 0:
			continue
		var city_id: int = candidate["city_id"]
		var distance: float = candidate["center_km"].distance_to(region.cities[city_id]["center_km"])
		if distance < best_distance:
			candidate_id = candidate["id"]
			best_distance = distance
	_check(candidate_id >= 0, "an undeveloped road-frontage cell must be selectable")
	if candidate_id < 0:
		return
	var old_count: int = region.neighborhoods.size()
	for day in range(7):
		NeighborhoodDynamics.advance_day(region)
	_check(region.neighborhoods.size() == old_count, "road access alone must not create simulated neighborhoods")
	var result: Dictionary = DevelopmentPlanner.set_approval(region, candidate_id, true)
	_check(result.get("ok", false) and result.get("new_neighborhood", false), "approval must create an economic neighborhood")
	if not result.get("ok", false):
		return
	_check(region.neighborhoods.size() == old_count + 1, "approval creates exactly one neighborhood")
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.refresh_desirability(region)
	var neighborhood_id: int = region.development_candidates[candidate_id]["neighborhood_id"]
	var neighborhood = region.neighborhoods[neighborhood_id]
	_check(region.validation_errors().is_empty(), "approved growth must preserve region invariants")
	for day in range(35):
		region.current_day_key += 1
		if DevelopmentBudget.advance_day(region, region.current_day_key):
			AccessibilityCalculator.recalculate(region)
		NeighborhoodDynamics.advance_day(region)
	_check(neighborhood.households > 0 and neighborhood.jobs > 0, "approved connected land must gain homes and jobs")
	var homes: int = neighborhood.households
	var jobs: int = neighborhood.jobs
	var capacity: int = neighborhood.housing_capacity
	neighborhood.migration_remainder = 0.9
	neighborhood.job_growth_remainder = 0.9
	_check(DevelopmentPlanner.set_approval(region, candidate_id, false).get("ok", false), "approval must be withdrawable")
	_check(neighborhood.migration_remainder <= 0.0 and neighborhood.job_growth_remainder <= 0.0, "withdrawal must clear pending positive growth")
	for day in range(7):
		NeighborhoodDynamics.advance_day(region)
	_check(neighborhood.households <= homes and neighborhood.jobs <= jobs and neighborhood.housing_capacity == capacity, "withdrawal must preserve stock and stop positive growth")
	var snapshot = DayCycleCalculator.copy_region(region)
	snapshot.neighborhoods[neighborhood_id].development_approved = true
	snapshot.development_candidates[candidate_id]["frontage_link_id"] = -1
	snapshot.cities[neighborhood.city_id]["neighborhood_ids"].append(-1)
	_check(not neighborhood.development_approved and region.development_candidates[candidate_id]["frontage_link_id"] >= 0, "worker snapshots must detach zoning state")
	_check(not region.cities[neighborhood.city_id]["neighborhood_ids"].has(-1), "worker snapshots must detach mutable city ownership")
	_check(region.validation_errors().is_empty(), "withdrawal must preserve region invariants")


func _check_coastal_routing() -> void:
	var polygon := PackedVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(4, 4), Vector2(3, 4), Vector2(3, 1), Vector2(1, 1), Vector2(1, 4), Vector2(0, 4)])
	var first := Vector2(0.5, 3.5)
	var second := Vector2(3.5, 3.5)
	_check(not StateGeography.segment_on_land(polygon, first, second), "a road across a bay must be recognized as crossing water")
	var route: PackedVector2Array = StateGeography.land_route(polygon, first, second)
	_check(route.size() >= 4, "coastal routes must turn around a bay")
	for segment in range(1, route.size()):
		_check(StateGeography.segment_on_land(polygon, route[segment - 1], route[segment]), "coastal route segments must stay on land")


func _check_new_road_candidates() -> void:
	var region = RegionSetup.build(1729, 256, 0.1)["region"]
	var start_city: int = region.starting_city_ids[0]
	var city_id := -1
	var best_distance := INF
	for city in region.cities:
		if region.starting_city_ids.has(city["id"]):
			continue
		var distance: float = city["center_km"].distance_to(region.cities[start_city]["center_km"])
		if distance < best_distance and StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, region.cities[start_city]["center_km"], city["center_km"]):
			city_id = city["id"]
			best_distance = distance
	_check(city_id >= 0, "an unconnected city must be reachable by a new arterial")
	if city_id < 0:
		return
	var preview: Dictionary = RoadPlanner.link_preview(region, region.city_hub_node_ids[start_city], region.city_hub_node_ids[city_id], "Arterial", PackedVector2Array(), region.current_day_key)
	_check(preview.get("ok", false), "new arterial preview must be valid")
	if not preview.get("ok", false):
		return
	region.jurisdictions[preview["owner_id"]].treasury += preview["cost"]
	_check(RoadPlanner.commit(region, preview, region.current_day_key).get("ok", false), "new arterial must be buildable")
	var before: int = region.development_candidates.size()
	DevelopmentPlanner.refresh_candidates(region)
	_check(region.development_candidates.size() == before, "unfinished roads must not expose candidates")
	var corridor_id: int = region.next_road_link_id
	var opened: Dictionary = MultiScaleDayCalculator.advance_day(region, int(preview["open_day_key"]), null, null)
	region = opened["region"]
	var corridor_links: Array[int] = []
	for link in region.road_links:
		if link.corridor_id == corridor_id:
			corridor_links.append(link.id)
	var new_candidates := 0
	for candidate in region.development_candidates:
		if int(candidate["city_id"]) == city_id and corridor_links.has(int(candidate["frontage_link_id"])):
			new_candidates += 1
	_check(new_candidates > 0, "completed connected arterials must create candidates along the route")
	for link_id in corridor_links:
		RoadPlanner.demolish(region, link_id)
	DevelopmentPlanner.refresh_candidates(region)
	for candidate in region.development_candidates:
		if int(candidate["city_id"]) == city_id:
			_check(int(candidate["frontage_link_id"]) < 0, "demolished arterial must remove candidate road access")


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)


func _rectangular(polygon: PackedVector2Array) -> bool:
	if polygon.size() != 4:
		return false
	for index in range(4):
		var incoming: Vector2 = (polygon[index] - polygon[posmod(index - 1, 4)]).normalized()
		var outgoing: Vector2 = (polygon[(index + 1) % 4] - polygon[index]).normalized()
		if absf(incoming.dot(outgoing)) > 0.005:
			return false
	return true
