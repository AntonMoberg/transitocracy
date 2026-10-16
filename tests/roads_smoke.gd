extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	var same_seed = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(same_seed)
	_check(region.road_nodes.size() == 15 and region.road_links.size() == 14, "seed must create a connected tree with the minimum number of links")
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		var matching_link = same_seed.road_links[index]
		_check(link.road_class == "Arterial" and link.lanes_per_direction == 1, "seed must contain only single-lane arterials")
		_check(link.from_node_id == matching_link.from_node_id and link.to_node_id == matching_link.to_node_id, "road tree must be deterministic for a region seed")
	for node in region.road_nodes:
		_check(not node.is_interchange, "interchanges must be player built")
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	var day_key := floori(float(clock.unix_seconds) / 86400.0)
	var free_access: float = region.accessibility[0]
	var starting_free: Dictionary = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region))
	for row in starting_free["times"]:
		for minutes in row:
			_check(minutes < RoadGraph.UNREACHABLE_MINUTES, "every starting neighborhood must have a road route to every other")
	var day: Dictionary = RoadTrafficCalculator.build_day(region, clock.unix_seconds)
	var flow = day["flow"]
	var traffic = day["traffic"]
	_check(region.validation_errors().is_empty(), "initial region must validate")
	_check(traffic.hourly_volumes.size() == 24 and traffic.hourly_pair_times.size() == 24, "traffic must be assigned for every hour")
	_check(region.travel_times[0][4] > starting_free["times"][0][4] and region.accessibility[0] < free_access, "road congestion must affect travel time and job access")
	var rush_peak := 0.0
	var night_peak := 0.0
	var has_rush_reversal := false
	for link_index in range(region.road_links.size()):
		var morning: Vector2 = traffic.hourly_volumes[8][link_index]
		var evening: Vector2 = traffic.hourly_volumes[17][link_index]
		rush_peak = maxf(rush_peak, maxf(morning.x, morning.y))
		night_peak = maxf(night_peak, maxf(traffic.hourly_volumes[2][link_index].x, traffic.hourly_volumes[2][link_index].y))
		if (morning.x > morning.y and evening.y > evening.x) or (morning.y > morning.x and evening.x > evening.y):
			has_rush_reversal = true
	_check(rush_peak > night_peak and has_rush_reversal, "road traffic must show a directional rush hour")
	_check(traffic.interpolated_volume(0, 8, 0.5).distance_to(traffic.hourly_volumes[8][0].lerp(traffic.hourly_volumes[9][0], 0.5)) < 0.001, "road volumes must interpolate between hours")
	_check(not RoadPlanner.link_preview(region, 0, 1, "Highway", PackedVector2Array(), day_key)["ok"], "highways must require interchanges")

	var removed_link = region.road_links[0]
	var demolition: Dictionary = RoadPlanner.demolish_preview(region, removed_link.id)
	_check(demolition["ok"] and demolition["components_after"] > 1, "demolishing a tree edge must preview the resulting disconnected groups")
	var treasury_before: float = region.treasury
	var upkeep_before: float = RoadPlanner.calculate_upkeep(region)
	var removal: Dictionary = RoadPlanner.demolish(region, removed_link.id)
	_check(removal["ok"] and region.road_links.size() == 13, "demolition must immediately remove the selected road")
	_check(region.treasury == treasury_before and region.daily_road_upkeep < upkeep_before, "demolition must have no refund and end the road's upkeep")
	AccessibilityCalculator.recalculate(region)
	var blocked_pair := Vector2i(-1, -1)
	for origin_id in range(region.neighborhoods.size()):
		for destination_id in range(region.neighborhoods.size()):
			if region.travel_times[origin_id][destination_id] >= RoadGraph.UNREACHABLE_MINUTES:
				blocked_pair = Vector2i(origin_id, destination_id)
				break
		if blocked_pair.x >= 0:
			break
	_check(blocked_pair.x >= 0 and region.validation_errors().is_empty(), "disconnected roads must be a valid gameplay state")
	var disconnected_day: Dictionary = RoadTrafficCalculator.build_day(region, clock.unix_seconds, flow)
	var disconnected_flow = disconnected_day["flow"]
	_check(disconnected_flow.daily_work_od[blocked_pair.x][blocked_pair.y] == 0.0 and disconnected_flow.weekday_shopping_od[blocked_pair.x][blocked_pair.y] == 0.0, "work and shopping trips must not cross disconnected groups")
	var assigned_commuters := 0.0
	for row in disconnected_flow.daily_work_od:
		for commuters in row:
			assigned_commuters += commuters
	_check(absf(assigned_commuters - disconnected_flow.daily_commuters) < 0.1, "work balancing must respect the available jobs in each connected group")

	var reconnect: Dictionary = RoadPlanner.link_preview(region, removed_link.from_node_id, removed_link.to_node_id, "Arterial", PackedVector2Array(), day_key)
	var original_reconnect_days := maxi(14, ceili(7.0 + 2.0 * float(reconnect["length_km"])))
	_check(reconnect["ok"] and reconnect["days"] == ceili(float(original_reconnect_days) / 10.0), "arterial construction must take about one tenth of its original duration")
	var funded: Dictionary = RoadPlanner.commit(region, reconnect, day_key)
	_check(funded["ok"] and region.road_links.size() == 13 and region.treasury == treasury_before - reconnect["cost"], "construction must charge upfront and stay closed until opening")
	var tax_receipts: float = region.daily_tax_revenue
	RoadPlanner.advance_day(region, day_key + 1)
	_check(is_equal_approx(region.last_fiscal_change, tax_receipts - upkeep_before + demolition["upkeep_saved"]), "daily finances must credit tax and charge only open-road upkeep")
	_check(region.road_links.size() == 13, "replacement road must remain closed before opening")
	RoadPlanner.advance_day(region, int(reconnect["open_day_key"]))
	AccessibilityCalculator.recalculate(region)
	_check(region.road_projects.is_empty() and region.road_links.size() == 14 and region.travel_times[blocked_pair.x][blocked_pair.y] < RoadGraph.UNREACHABLE_MINUTES, "replacement road must restore connectivity on its opening day")

	var base_times: Array = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region))["times"]
	var best_shortcut: Dictionary = {}
	var best_saving := 0.0
	for origin_id in range(region.neighborhoods.size()):
		for destination_id in range(origin_id + 1, region.neighborhoods.size()):
			var candidate: Dictionary = RoadPlanner.link_preview(region, origin_id, destination_id, "Arterial", PackedVector2Array(), day_key)
			if not candidate.get("ok", false) or candidate["cost"] > region.treasury:
				continue
			var direct_time: float = RoadGraph.LOCAL_ACCESS_MINUTES + candidate["length_km"] * 60.0 / RoadGraph.free_speed_kmh("Arterial")
			var saving: float = base_times[origin_id][destination_id] - direct_time
			if saving > best_saving and base_times[origin_id][destination_id] < direct_time * 5.5:
				best_saving = saving
				best_shortcut = candidate
	_check(not best_shortcut.is_empty(), "tree must leave a useful alternate corridor for the player to build")
	if not best_shortcut.is_empty():
		var shortcut_commit: Dictionary = RoadPlanner.commit(region, best_shortcut, day_key)
		_check(shortcut_commit["ok"], "player must be able to fund a second arterial route")
		RoadPlanner.advance_day(region, int(best_shortcut["open_day_key"]))
		var link_index: int = region.road_links.size() - 1
		var free_routes: Dictionary = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region))
		_check(free_routes["times"][best_shortcut["from"]][best_shortcut["to"]] < base_times[best_shortcut["from"]][best_shortcut["to"]], "new corridor must shorten trips")
		var loaded_costs: PackedVector2Array = RoadGraph.free_flow_costs(region)
		loaded_costs[link_index] *= 6.0
		var loaded_routes: Dictionary = RoadGraph.route_pairs(region, loaded_costs)
		_check(free_routes["paths"][best_shortcut["from"]][best_shortcut["to"]] != loaded_routes["paths"][best_shortcut["from"]][best_shortcut["to"]], "traffic must be able to reroute through the old tree when a new corridor is congested")

	var widen_link = region.road_links[0]
	var widen: Dictionary = RoadPlanner.widen_preview(region, widen_link.id, day_key)
	var original_widen_days := maxi(14, ceili(7.0 + 2.0 * widen_link.length_km))
	_check(widen["ok"] and widen["days"] == ceili(float(maxi(7, ceili(float(original_widen_days) * 0.5))) / 10.0), "widening duration must be reduced tenfold")
	var fixed_volumes := PackedVector2Array()
	fixed_volumes.resize(region.road_links.size())
	fixed_volumes[0] = Vector2(1200.0, 1200.0)
	var before_widen_time: float = RoadTrafficCalculator._congested_costs(region, RoadGraph.free_flow_costs(region), fixed_volumes)[0].x
	_check(widen["ok"] and RoadPlanner.commit(region, widen, day_key)["ok"], "widening must be available on an arterial")
	RoadPlanner.advance_day(region, int(widen["open_day_key"]))
	var after_widen_time: float = RoadTrafficCalculator._congested_costs(region, RoadGraph.free_flow_costs(region), fixed_volumes)[0].x
	_check(widen_link.lanes_per_direction == 2 and after_widen_time < before_widen_time, "widening must add capacity and reduce delay")
	_check(region.validation_errors().is_empty(), "road changes must leave valid data")

	var highway_region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(highway_region)
	var interchange_open_day := day_key
	for node_id in [0, 1]:
		var interchange: Dictionary = RoadPlanner.interchange_preview(highway_region, node_id, -1, Vector2.ZERO, day_key)
		_check(interchange["days"] == 5, "interchanges must take five days")
		_check(interchange["ok"] and RoadPlanner.commit(highway_region, interchange, day_key)["ok"], "interchanges must be constructible at road nodes")
		interchange_open_day = int(interchange["open_day_key"])
	RoadPlanner.advance_day(highway_region, interchange_open_day)
	_check(highway_region.road_nodes[0].is_interchange and highway_region.road_nodes[1].is_interchange, "interchanges must open after construction")
	var highway: Dictionary = RoadPlanner.link_preview(highway_region, 0, 1, "Highway", PackedVector2Array(), interchange_open_day)
	_check(highway["ok"], "highway must be buildable between active interchanges")
	if highway.get("ok", false):
		var original_highway_days := maxi(45, ceili(20.0 + 4.0 * float(highway["length_km"])))
		_check(highway["days"] == ceili(float(original_highway_days) / 10.0), "highway construction duration must be reduced tenfold")
		_check(RoadPlanner.commit(highway_region, highway, interchange_open_day)["ok"], "highway must be fundable")
		RoadPlanner.advance_day(highway_region, int(highway["open_day_key"]))
		var highway_link = highway_region.road_links[-1]
		_check(highway_link.road_class == "Highway", "new highway must open into the active graph")
		var midpoint: Vector2 = highway_link.points[0].lerp(highway_link.points[1], 0.5)
		var exit_preview: Dictionary = RoadPlanner.interchange_preview(highway_region, -1, highway_link.id, midpoint, day_key)
		_check(exit_preview["ok"] and exit_preview["days"] == 5, "a highway segment must accept a five-day planned exit")
		if exit_preview.get("ok", false):
			highway_region.treasury = 100000000.0
			RoadPlanner.commit(highway_region, exit_preview, day_key)
			var nodes_before: int = highway_region.road_nodes.size()
			RoadPlanner.advance_day(highway_region, int(exit_preview["open_day_key"]))
			_check(highway_region.road_nodes.size() == nodes_before + 1 and highway_region.road_nodes[-1].is_interchange, "new exit must become an active highway node")
	var unaffordable: Dictionary = RoadPlanner.link_preview(highway_region, 2, 3, "Arterial", PackedVector2Array(), day_key)
	highway_region.treasury = 0.0
	_check(not RoadPlanner.commit(highway_region, unaffordable, day_key)["ok"], "unaffordable roads must be rejected")
	var empty_region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(empty_region)
	while not empty_region.road_links.is_empty():
		RoadPlanner.demolish(empty_region, empty_region.road_links[0].id)
	AccessibilityCalculator.recalculate(empty_region)
	NeighborhoodDynamics.initialize(empty_region)
	var empty_day: Dictionary = RoadTrafficCalculator.build_day(empty_region, clock.unix_seconds)
	_check(empty_region.travel_times[0][1] >= RoadGraph.UNREACHABLE_MINUTES and empty_region.travel_times[0][0] == RoadGraph.LOCAL_ACCESS_MINUTES, "demolishing every road must preserve only local access")
	_check(empty_region.validation_errors().is_empty() and empty_day["traffic"].hourly_volumes[8].is_empty(), "the simulation must handle an empty road graph")
	if failures == 0:
		print("Road smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
