extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const CompactTrafficCalculator = preload("res://scripts/simulation/compact_traffic_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for city_count in [16, 128, 512]:
		for seed_value in [1729, 1730, 42]:
			var region = RegionGenerator.generate_region(seed_value) if city_count == 16 else RegionGenerator.generate_large_region(seed_value, city_count)
			_check_geography(region)
			RoadNetworkGenerator.generate(region)
			AccessibilityCalculator.recalculate(region)
			NeighborhoodDynamics.initialize(region)
			_check(region.validation_errors().is_empty(), "all generated map sizes must validate")
			_check(region.starting_city_ids.size() == 4 and region.road_links.size() == 15, "four starting cities must have only twelve local roads and three highways")
			var populated := 0
			for neighborhood in region.neighborhoods:
				if neighborhood.initially_developed:
					populated += 1
					_check(neighborhood.population > 0 and region.neighborhood_development_connected[neighborhood.id] != 0, "starting neighborhoods must be populated and connected")
				else:
					_check(neighborhood.population == 0 and neighborhood.jobs == 0 and neighborhood.shopping_attraction == 0.0 and neighborhood.average_household_wealth == 0.0, "undeveloped land must start economically empty")
			_check(populated == 12, "only three neighborhoods in each starting city may be developed")
			for city_id in region.starting_city_ids:
				_check(region.road_nodes[region.city_hub_node_ids[city_id]].is_interchange, "initial highways need usable interchanges")
			for link in region.road_links:
				_check(link.owner_jurisdiction_id == region.road_owner_for_points(link.points), "road ownership must follow polygon boundaries")
				for segment in range(1, link.points.size()):
					_check(StateGeography.segment_on_land(region.jurisdictions[0].polygon_km, link.points[segment - 1], link.points[segment]), "starting roads must follow land around bays")
			var repeat = RegionGenerator.generate_region(seed_value) if city_count == 16 else RegionGenerator.generate_large_region(seed_value, city_count)
			_check(region.jurisdictions[0].polygon_km == repeat.jurisdictions[0].polygon_km and region.neighborhoods[-1].position_km == repeat.neighborhoods[-1].position_km and region.starting_city_ids == repeat.starting_city_ids, "geography and starting cities must repeat for the same seed")
	for city_count in [16, 128]:
		_check_development(city_count)
	_check_direct_gateway()
	_check_coastal_routing()
	if failures == 0:
		print("State geography and development smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check_geography(region) -> void:
	var state = region.jurisdictions[0]
	_check(state.bounds_km.size.x / state.bounds_km.size.y >= 2.7, "states must be elongated rather than round")
	_check(_polygon_area(Geometry2D.convex_hull(state.polygon_km)) > _polygon_area(state.polygon_km) * 1.08, "coastlines must contain meaningful bays and peninsulas")
	var straight_length := 0.0
	var border_length := 0.0
	for area in region.jurisdictions:
		_check(area.polygon_km.size() >= 3 and _polygon_area(area.polygon_km) > 0.001, "jurisdictions must have nondegenerate polygons")
		_check(area.contains_point(area.center_km), "jurisdiction centers must lie within their polygon")
		if area.kind != "State":
			for vertex in range(area.polygon_km.size()):
				var edge: Vector2 = area.polygon_km[(vertex + 1) % area.polygon_km.size()] - area.polygon_km[vertex]
				border_length += edge.length()
				if absf(edge.x) < 0.001 or absf(edge.y) < 0.001:
					straight_length += edge.length()
		if not area.child_ids.is_empty():
			var child_area := 0.0
			for child_id in area.child_ids:
				child_area += _polygon_area(region.jurisdictions[child_id].polygon_km)
			var perimeter := 0.0
			for vertex in range(area.polygon_km.size()):
				perimeter += area.polygon_km[vertex].distance_to(area.polygon_km[(vertex + 1) % area.polygon_km.size()])
			var tolerance: float = maxf(0.0001, perimeter * JurisdictionData.BOUNDARY_TOLERANCE_KM)
			_check(absf(child_area - _polygon_area(area.polygon_km)) < tolerance, "child polygons must cover their parent without gaps or overlaps")
	for neighborhood in region.neighborhoods:
		for kind in ["City", "County", "Region", "State"]:
			_check(region.jurisdiction_for_neighborhood(neighborhood.id, kind).contains_point(neighborhood.position_km), "seed %d neighborhood %d at %s must remain inside its %s" % [region.generation_seed, neighborhood.id, neighborhood.position_km, kind])
		_check(region.jurisdiction_at_point(neighborhood.position_km) == neighborhood.jurisdiction_id, "polygon lookup must identify neighborhood ownership")
	_check(straight_length / border_length < 0.35, "administrative borders must favor varied organic edges rather than square grids")


func _check_coastal_routing() -> void:
	var polygon := PackedVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(4, 4), Vector2(3, 4), Vector2(3, 1), Vector2(1, 1), Vector2(1, 4), Vector2(0, 4)])
	var first := Vector2(0.5, 3.5)
	var second := Vector2(3.5, 3.5)
	_check(not StateGeography.segment_on_land(polygon, first, second), "a road across a bay must be recognized as crossing water")
	var route: PackedVector2Array = StateGeography.land_route(polygon, first, second)
	_check(route.size() >= 4 and route[0] == first and route[-1] == second, "coastal routes must preserve their endpoints and turn around the bay")
	for segment in range(1, route.size()):
		_check(StateGeography.segment_on_land(polygon, route[segment - 1], route[segment]), "every segment of a coastal detour must remain on land")


func _check_development(city_count: int) -> void:
	var setup: Dictionary = RegionSetup.build(1729, city_count, 0.1)
	var region = setup["region"]
	var city_id := 0
	while region.starting_city_ids.has(city_id):
		city_id += 1
	var first_id: int = region.cities[city_id]["neighborhood_ids"][0]
	var second_id: int = region.cities[city_id]["neighborhood_ids"][1]
	var third_id: int = region.cities[city_id]["neighborhood_ids"][2]
	var first = region.neighborhoods[first_id]
	var first_gateway: int = region.neighborhood_gateway_node_ids[first_id]
	var second_gateway: int = region.neighborhood_gateway_node_ids[second_id]
	var hub_id: int = region.city_hub_node_ids[city_id]
	var starting_hub: int = region.city_hub_node_ids[0]
	_open_road(region, first_gateway, second_gateway)
	AccessibilityCalculator.recalculate(region)
	_step_day(region)
	_check(first.households == 0 and first.jobs == 0, "an isolated local road must not activate development")
	var hub_link: int = _open_road(region, starting_hub, hub_id)
	AccessibilityCalculator.recalculate(region)
	_step_day(region)
	_check(first.households == 0 and first.jobs == 0, "connecting only a city hub must leave its unconnected neighborhoods dormant")
	var preview: Dictionary = RoadPlanner.link_preview(region, hub_id, first_gateway, "Arterial", PackedVector2Array(), region.current_day_key)
	region.jurisdictions[preview["owner_id"]].treasury += preview["cost"]
	_check(RoadPlanner.commit(region, preview, region.current_day_key)["ok"], "connection project must be buildable")
	AccessibilityCalculator.recalculate(region)
	_step_day(region)
	_check(first.population == 0, "unfinished roads must not activate development")
	RoadPlanner.advance_day(region, int(preview["open_day_key"]))
	AccessibilityCalculator.recalculate(region)
	for day_index in range(28):
		_step_day(region)
	_check(first.households >= roundi(float(first.housing_capacity) * 0.15) and first.households <= roundi(float(first.housing_capacity) * 0.3), "a connected neighborhood must develop meaningfully over four weeks")
	_check(first.jobs > 0 and first.average_monthly_income > 0 and first.population > first.households, "new development must initialize jobs, income, and household size")
	_check(region.neighborhoods[second_id].population > 0 and region.neighborhoods[third_id].population == 0, "only neighborhoods with completed routes may grow")
	_check(region.validation_errors().is_empty(), "growth must preserve economic invariants")
	var previous_households: int = first.households
	var previous_jobs: int = first.jobs
	RoadPlanner.demolish(region, hub_link)
	AccessibilityCalculator.recalculate(region)
	_step_day(region)
	_check(first.households > 0 and first.households < previous_households and first.jobs < previous_jobs, "disconnection must cause gradual decline without immediately erasing occupants")
	_check(first.development_state == "Disconnected" and region.accessibility[first_id] > 0.0, "disconnected inhabited areas must retain internal job access")
	_open_road(region, starting_hub, first_gateway)
	AccessibilityCalculator.recalculate(region)
	var declining_households: int = first.households
	_step_day(region)
	_check(first.households > declining_households, "reconnection must resume development")
	if region.is_large_scale:
		_check_compact_routes(region, first_id, second_id)
		var source_households: int = first.households
		var fork = DayCycleCalculator.copy_region(region)
		_step_day(fork)
		_check(first.households == source_households and fork.neighborhoods[first_id].households > source_households, "background snapshots must detach development state")
		_check(fork.jurisdictions[0].polygon_km == region.jurisdictions[0].polygon_km and fork.neighborhood_development_connected == region.neighborhood_development_connected, "snapshots must preserve geography and connectivity")
		_step_day(region)
		_check(fork.neighborhoods[first_id].households == first.households and fork.neighborhoods[first_id].jobs == first.jobs, "detached and live daily growth must agree")
		var next_flow = TripFlowCalculator.build(region)
		TripFlowCalculator.populate_day(next_flow, region.generation_seed, region.current_day_key * 86400, false)
		var next_region = DayCycleCalculator.copy_region(region)
		var next_day: int = region.current_day_key + 1
		_step_day(region)
		var result: Dictionary = MultiScaleDayCalculator.advance_day(next_region, next_day, null, null)
		_check(result["region"].neighborhoods[first_id].households == first.households, "background daily preparation must use the same development rules")
		for mode in [MultiScaleTraffic.SECOND, MultiScaleTraffic.MINUTE, MultiScaleTraffic.HOUR, MultiScaleTraffic.DAY]:
			var state = MultiScaleTraffic.new_day(region, next_flow, region.current_day_key * 86400)
			MultiScaleTraffic.advance(region, next_flow, state, state.unix_seconds + 60, mode)
			_check(state.queues.size() == region.road_links.size(), "all traffic modes must handle the sparse network")
	var last_connection: int = region.road_links[-1].id
	RoadPlanner.demolish(region, last_connection)
	AccessibilityCalculator.recalculate(region)
	first.households = 2
	first.population = roundi(2.0 * first.people_per_household)
	NeighborhoodDynamics._set_jobs(first, 2)
	for day_index in range(100):
		_step_day(region)
	_check(first.households == 0 and first.jobs == 0 and first.development_state == "Dormant", "long disconnected decline must eventually return to an empty dormant state")


func _check_direct_gateway() -> void:
	var region = RegionSetup.build(1729, 128, 0.1)["region"]
	var city_id := 0
	while region.starting_city_ids.has(city_id):
		city_id += 1
	var first_id: int = region.cities[city_id]["neighborhood_ids"][0]
	var second_id: int = region.cities[city_id]["neighborhood_ids"][1]
	var first_gateway: int = region.neighborhood_gateway_node_ids[first_id]
	_open_road(region, region.city_hub_node_ids[0], first_gateway)
	_open_road(region, first_gateway, region.neighborhood_gateway_node_ids[second_id])
	AccessibilityCalculator.recalculate(region)
	_step_day(region)
	_check(region.city_route_node_ids[city_id] == first_gateway, "a direct gateway connection must work without building a city hub connection")
	_check(region.neighborhoods[first_id].population > 0 and region.neighborhood_accessible[second_id] != 0, "direct gateway development must receive road accessibility")
	_check(region.city_travel_times[city_id][0] < RoadGraph.UNREACHABLE_MINUTES, "compact city routing must use the connected gateway")
	_check_compact_routes(region, first_id, second_id)
	var profile = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(profile, region.generation_seed, region.current_day_key * 86400, false)
	for neighborhood in region.neighborhoods:
		if neighborhood.development_state == "Dormant":
			_check(profile.compact_origin_daily["Work"][neighborhood.id] == 0.0 and profile.compact_destination_daily["Work"][neighborhood.id] == 0.0, "dormant sites must not create compact work trips")
			var area = region.jurisdictions[neighborhood.jurisdiction_id]
			_check(area.daily_revenue() == 0.0, "dormant sites must not generate fiscal revenue")
	var first = region.neighborhoods[first_id]
	first.households = 0
	first.population = 0
	first.average_monthly_income = 0
	first.average_household_wealth = 0.0
	first.development_state = "Established"
	_step_day(region)
	_check(first.households > 0, "an empty connected neighborhood must be able to attract residents again")


func _check_compact_routes(region, first_id: int, second_id: int) -> void:
	var profile = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(profile, region.generation_seed, region.current_day_key * 86400, false)
	var state = MultiScaleTraffic.new_day(region, profile, region.current_day_key * 86400)
	CompactTrafficCalculator.prepare_routes(region, state)
	CompactTrafficCalculator.build_hour(region, profile, state, MultiScaleTraffic.HOUR, 8)
	var path = state.compact_trees_by_mode["local_routes"][second_id]
	_check(path != null and path.size() >= 1, "compact traffic must include newly built multi-edge local routes")
	if path != null:
		for edge in path:
			_check(state.cached_links[edge.x].length() > 0.0, "each local route segment must receive demand")
	_check(profile.compact_origin_daily["Work"][first_id] > 0.0, "connected development must generate compact work demand")


func _open_road(region, from_id: int, to_id: int) -> int:
	var preview: Dictionary = RoadPlanner.link_preview(region, from_id, to_id, "Arterial", PackedVector2Array(), region.current_day_key)
	_check(preview.get("ok", false), "test road must have a valid preview")
	if not preview.get("ok", false):
		return -1
	region.jurisdictions[preview["owner_id"]].treasury += preview["cost"]
	_check(RoadPlanner.commit(region, preview, region.current_day_key)["ok"], "funded test roads must be buildable")
	RoadPlanner.advance_day(region, int(preview["open_day_key"]))
	return region.road_links[-1].id


func _step_day(region) -> void:
	region.current_day_key += 1
	NeighborhoodDynamics.advance_day(region)


func _polygon_area(polygon: PackedVector2Array) -> float:
	return StateGeography._area(polygon)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
