extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionSetup.build(1729, 32, 0.10)["region"]
	var curved_highways := 0
	var sharp_inland_turns := 0
	var inland_curve := false
	var land: PackedVector2Array = region.jurisdictions[0].polygon_km
	for link in region.road_links:
		if link.road_class == "Highway":
			_check(region.jurisdictions[link.owner_jurisdiction_id].kind in ["State", "Region"], "all highways need state or regional owners")
			if link.points.size() > 2:
				curved_highways += 1
				if StateGeography.segment_on_land(land, link.points[0], link.points[-1]):
					for point in link.points:
						if point.distance_to(Geometry2D.get_closest_point_to_segment(point, link.points[0], link.points[-1])) > 0.1:
							inland_curve = true
		for segment in range(1, link.points.size()):
			_check(StateGeography.segment_on_land(land, link.points[segment - 1], link.points[segment]), "generated road must stay on land")
		if link.road_class == "Highway" and StateGeography.segment_on_land(land, link.points[0], link.points[-1]):
			for index in range(1, link.points.size() - 1):
				var incoming: Vector2 = link.points[index] - link.points[index - 1]
				var outgoing: Vector2 = link.points[index + 1] - link.points[index]
				if incoming.length_squared() < 0.000001 or outgoing.length_squared() < 0.000001:
					continue
				if absf(rad_to_deg(incoming.angle_to(outgoing))) > 25.0:
					sharp_inland_turns += 1
	_check(curved_highways > 0, "starter highways should include broad bends")
	_check(inland_curve, "open-land highways should bend rather than only detour around water")
	_check(sharp_inland_turns == 0, "inland highways should not contain sharp polyline corners")
	var highway_corridors: Dictionary = {}
	for link in region.road_links:
		if link.road_class != "Highway":
			continue
		if not highway_corridors.has(link.corridor_id):
			highway_corridors[link.corridor_id] = Rect2(link.points[0], Vector2.ZERO)
		var bounds: Rect2 = highway_corridors[link.corridor_id]
		for point in link.points:
			bounds = bounds.expand(point)
		highway_corridors[link.corridor_id] = bounds
	var trunks := 0
	var connectors := 0
	for bounds in highway_corridors.values():
		if bounds.size.x > bounds.size.y * 3.0 and bounds.size.x > 500.0:
			trunks += 1
		else:
			connectors += 1
			_check(bounds.size.x > 20.0 and bounds.size.y > 10.0, "cross-state highway connections should be diagonal")
	_check(trunks >= 1 and trunks <= 3 and connectors == trunks - 1 and highway_corridors.size() == trunks + connectors, "the starter network needs one to three lengthwise trunks joined into a single network")
	_check_highway_joins(region, 1729)
	var direct_city_connections := 0
	for city_id in region.starting_city_ids:
		var access_id: int = region.city_highway_access_node_ids[city_id]
		var highway_count := 0
		var arterial_count := 0
		for link in region.road_links:
			if link.from_node_id != access_id and link.to_node_id != access_id:
				continue
			highway_count += 1 if link.road_class == "Highway" else 0
			arterial_count += 1 if link.road_class == "Arterial" else 0
		_check(highway_count >= 1 and arterial_count >= 1 and region.road_nodes[access_id].kind == "Highway", "a city arterial must join a trunk node rather than a terminal highway spur")
		var center: Vector2 = region.cities[city_id]["center_km"]
		var access: Vector2 = region.road_nodes[access_id].position_km
		if absf(center.x - access.x) < 5.1:
			direct_city_connections += 1
	_check(direct_city_connections == region.starting_city_ids.size(), "city arterials should meet lengthwise trunk highways on their perpendicular projection")
	for seed_value in [291, 3819]:
		_check_highway_joins(RegionSetup.build(seed_value, 32, 0.10)["region"], seed_value)
	for city_count in [32, 256, 768]:
		var target_region = RegionSetup.build(8363444, city_count, 0.10)["region"]
		_check_highway_joins(target_region, 8363444)
		for highway in target_region.road_links:
			if highway.road_class == "Highway":
				for segment_index in range(1, highway.points.size()):
					_check(StateGeography.segment_on_land(target_region.jurisdictions[0].polygon_km, highway.points[segment_index - 1], highway.points[segment_index]), "seed 8363444 highway must stay on land")
	for large_seed in [1729, 291, 3819, 6061]:
		_check_highway_joins(RegionSetup.build(large_seed, 256, 0.10)["region"], large_seed)
	var city: Dictionary = region.cities[0]
	var city_point: Vector2 = city["center_km"]
	var local_points := PackedVector2Array([city_point, city_point + Vector2(0.01, 0.0)])
	_check(region.jurisdictions[region.road_owner_for_points(local_points, "Highway")].kind == "Region", "a city-local highway must still be region-funded")
	_check(region.jurisdictions[region.road_owner_for_points(local_points, "Arterial")].kind in ["City", "Neighborhood"], "a local arterial should have a local owner")
	var intercounty_region_owner := false
	for first_city in region.cities:
		for second_city in region.cities:
			if first_city["region_id"] != second_city["region_id"] or first_city["county_id"] == second_city["county_id"]:
				continue
			var corridor := PackedVector2Array([first_city["center_km"], second_city["center_km"]])
			if region.jurisdictions[region.road_owner_for_points(corridor, "Arterial")].kind == "Region":
				intercounty_region_owner = true
				break
		if intercounty_region_owner:
			break
	_check(intercounty_region_owner, "an arterial crossing counties within one region should be region-funded")
	var other_city: Dictionary = {}
	for candidate in region.cities:
		if candidate["region_id"] != city["region_id"]:
			other_city = candidate
			break
	_check(not other_city.is_empty() and region.road_owner_for_points(PackedVector2Array([city_point, other_city["center_km"]]), "Highway") == 0, "cross-region highways belong to the state")
	var state = region.jurisdictions[0]
	var capital_share: float = state.daily_income_revenue * 0.20 / float(region.region_ids.size())
	var regional_grants := 0.0
	for region_id in region.region_ids:
		var area = region.jurisdictions[region_id]
		_check(is_equal_approx(area.treasury, 300000000.0), "regions should start with a road capital reserve")
		_check(is_equal_approx(area.daily_grant_revenue, area.daily_road_upkeep + capital_share), "grants should cover regional upkeep plus equal capital funding")
		regional_grants += area.daily_grant_revenue
	_check(is_equal_approx(state.daily_transfer_expense, regional_grants), "state transfers must equal received regional grants")
	state.treasury = -1000000.0
	var before_total := 0.0
	var expected_change := 0.0
	for area in region.jurisdictions:
		before_total += area.treasury
		expected_change += area.daily_net()
	RoadPlanner.advance_day(region, region.current_day_key + 1)
	var after_total := 0.0
	for area in region.jurisdictions:
		after_total += area.treasury
	_check(absf(after_total - before_total - expected_change) < 0.1, "grants must cancel in statewide totals")
	_check(state.treasury < 0.0 and region.jurisdictions[region.region_ids[0]].daily_grant_revenue > 0.0, "state debt must not stop regional grants")
	var preview: Dictionary = {}
	for first_city in region.starting_city_ids:
		for second_city in region.starting_city_ids:
			if first_city >= second_city:
				continue
			var candidate: Dictionary = RoadPlanner.link_preview(region, region.city_highway_access_node_ids[first_city], region.city_highway_access_node_ids[second_city], "Highway", PackedVector2Array(), region.current_day_key)
			if candidate.get("ok", false) and candidate["length_km"] > 15.0 and region.jurisdictions[candidate["owner_id"]].kind == "Region":
				preview = candidate
				break
		if not preview.is_empty():
			break
	_check(not preview.is_empty(), "a regional player highway should be available to preview")
	if not preview.is_empty():
		var repeat: Dictionary = RoadPlanner.link_preview(region, preview["from"], preview["to"], "Highway", PackedVector2Array(), region.current_day_key)
		_check(repeat["points"] == preview["points"] and repeat["cost"] == preview["cost"], "the same route preview must be deterministic")
		var waypoint: Vector2 = preview["points"][preview["points"].size() / 2]
		var with_waypoint: Dictionary = RoadPlanner.link_preview(region, preview["from"], preview["to"], "Highway", PackedVector2Array([waypoint]), region.current_day_key)
		_check(with_waypoint.get("ok", false) and with_waypoint["points"].has(waypoint) and with_waypoint["waypoints"] == PackedVector2Array([waypoint]), "player waypoint must remain an exact route anchor")
		region.jurisdictions[preview["owner_id"]].treasury = maxf(region.jurisdictions[preview["owner_id"]].treasury, float(preview["cost"]) + 1000000.0)
		var result: Dictionary = RoadPlanner.commit(region, preview, region.current_day_key)
		_check(result.get("ok", false), "the regional highway should be fundable")
		if result.get("ok", false):
			var project = result["project"]
			_check(project.points == preview["points"] and project.cost == preview["cost"] and project.owner_jurisdiction_id == preview["owner_id"], "commit must retain preview geometry, price and owner")
			RoadPlanner.advance_day(region, project.open_day_key)
			var link = region.road_links[-1]
			_check(link.points == preview["points"] and is_equal_approx(link.length_km, preview["length_km"]) and link.owner_jurisdiction_id == preview["owner_id"], "completed road must retain its previewed corridor and sponsor")
			var exit_point: Vector2 = link.points[link.points.size() / 2]
			var exit_preview: Dictionary = RoadPlanner.interchange_preview(region, -1, link.id, exit_point, region.current_day_key)
			_check(exit_preview.get("ok", false) and exit_preview["owner_id"] == link.owner_jurisdiction_id, "highway exit should use its highway sponsor")
			if exit_preview.get("ok", false):
				region.jurisdictions[exit_preview["owner_id"]].treasury += float(exit_preview["cost"])
				var exit_result: Dictionary = RoadPlanner.commit(region, exit_preview, region.current_day_key)
				_check(exit_result.get("ok", false), "regional highway exit should be fundable")
				if exit_result.get("ok", false):
					RoadPlanner.advance_day(region, exit_result["project"].open_day_key)
					_check(region.road_nodes[-1].interchange_owner_jurisdiction_id == link.owner_jurisdiction_id, "exit upkeep must follow its sponsoring highway")
					_check(region.road_links[-1].owner_jurisdiction_id == link.owner_jurisdiction_id, "both halves of a split highway must keep their original owner")
					var snapshot = DayCycleCalculator.copy_region(region)
					_check(snapshot.road_nodes[-1].interchange_owner_jurisdiction_id == region.road_nodes[-1].interchange_owner_jurisdiction_id, "worker snapshot must retain exit ownership")
					_check(is_equal_approx(snapshot.jurisdictions[0].daily_transfer_expense, region.jurisdictions[0].daily_transfer_expense), "worker snapshot must retain transfer expenses")
	if failures == 0:
		print("Curved land routes, highway ownership, regional grants, and project geometry passed.")
	quit(1 if failures > 0 else 0)


func _check_highway_joins(region, seed_value: int) -> void:
	var pair_count := 0
	var branch_count := 0
	var largest_error := 0.0
	var smallest_radius := INF
	for link in region.road_links:
		if link.road_class == "Highway":
			smallest_radius = minf(smallest_radius, RoadRouteBuilder.minimum_curve_radius(link.points))
	for node in region.road_nodes:
		if node.kind != "Highway":
			continue
		var hub_id: int = node.id
		var by_corridor: Dictionary = {}
		for link in region.road_links:
			if link.road_class != "Highway":
				continue
			if link.from_node_id == hub_id:
				if region.road_nodes[link.to_node_id].kind != "Highway":
					branch_count += 1
					continue
				if not by_corridor.has(link.corridor_id):
					by_corridor[link.corridor_id] = []
				by_corridor[link.corridor_id].append(link.points[1] - link.points[0])
			elif link.to_node_id == hub_id:
				if region.road_nodes[link.from_node_id].kind != "Highway":
					branch_count += 1
					continue
				if not by_corridor.has(link.corridor_id):
					by_corridor[link.corridor_id] = []
				by_corridor[link.corridor_id].append(link.points[-2] - link.points[-1])
		for corridor_id in by_corridor:
			var outward: Array = by_corridor[corridor_id]
			if outward.size() != 2:
				continue
			pair_count += 1
			var error: float = 180.0 - absf(rad_to_deg(outward[0].angle_to(outward[1])))
			largest_error = maxf(largest_error, error)
			_check(error < 2.0, "seed %d trunk node %d has a %.3f degree kink in its through-highway pair" % [seed_value, hub_id, error])
	_check(pair_count > 0, "road seed should contain a continuous through-highway corridor")
	_check(smallest_radius >= RoadRouteBuilder.MIN_HIGHWAY_RADIUS_KM, "seed %d needs highway bends of at least 2 km radius" % seed_value)
	print("Seed %d (%d cities): %d highway junctions (%d branched), largest through turn %.3f degrees, smallest bend radius %.3f km." % [seed_value, region.cities.size(), pair_count, branch_count, largest_error, smallest_radius])


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
