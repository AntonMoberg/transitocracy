extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")

var failures := 0


func _initialize() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	var day_key: int = clock.unix_seconds / 86400
	var initial_links: int = region.road_links.size()
	_check(initial_links >= 49 and RoadGraph.is_forest(region) and _all_connected(region), "starter roads must connect forty developed neighborhoods and ten city hubs as a tree")
	for city_id in region.starting_city_ids:
		var hub_id: int = region.city_hub_node_ids[city_id]
		var arterial_count := 0
		for link in region.road_links:
			if link.road_class == "Arterial" and (link.from_node_id == hub_id or link.to_node_id == hub_id):
				arterial_count += 1
		_check(arterial_count >= 1 and arterial_count <= 2, "each highway hub must feed only one or two arterial trunks")
	var interchange: Dictionary = RoadPlanner.interchange_preview(region, region.neighborhood_gateway_node_ids[0], -1, Vector2.ZERO, day_key)
	_check(interchange["ok"] and region.jurisdictions[interchange["owner_id"]].kind == "City" and region.jurisdictions[interchange["owner_id"]].treasury >= interchange["cost"], "a starting city must be able to fund a junction interchange")
	var state_roads := 0
	var local_roads := 0
	for link in region.road_links:
		_check(link.owner_jurisdiction_id == region.road_owner_for_points(link.points, link.road_class), "road owner must cover the whole corridor")
		state_roads += 1 if link.owner_jurisdiction_id == 0 else 0
		local_roads += 1 if region.jurisdictions[link.owner_jurisdiction_id].kind in ["City", "Neighborhood"] else 0
	_check(state_roads > 0 and local_roads > 0, "the generated network must have both state and local road owners")
	var removed = region.road_links[0]
	var removed_owner_id: int = removed.owner_jurisdiction_id
	var funds_before: float = region.jurisdictions[removed_owner_id].treasury
	var upkeep_before: float = RoadPlanner.calculate_upkeep(region)
	var demolition: Dictionary = RoadPlanner.demolish_preview(region, removed.id)
	_check(demolition["ok"] and demolition["components_after"] > 1, "demolition preview must show the resulting disconnection")
	RoadPlanner.demolish(region, removed.id)
	_check(region.road_links.size() == initial_links - 1 and is_equal_approx(region.jurisdictions[removed_owner_id].treasury, funds_before), "demolition must remove the road without a refund")
	_check(RoadPlanner.calculate_upkeep(region) < upkeep_before, "demolition must lower road upkeep")
	AccessibilityCalculator.recalculate(region)
	_check(region.travel_times[0][1] >= RoadGraph.UNREACHABLE_MINUTES or not _all_connected(region), "demolition must create a disconnected travel component")
	var reconnect: Dictionary = RoadPlanner.link_preview(region, removed.from_node_id, removed.to_node_id, "Arterial", PackedVector2Array(), day_key)
	_check(reconnect["ok"] and reconnect["owner_id"] == removed_owner_id, "rebuilding a corridor must assign its original paying jurisdiction")
	var owner = region.jurisdictions[reconnect["owner_id"]]
	owner.treasury = float(reconnect["cost"]) - 1.0
	_check(not RoadPlanner.commit(region, reconnect, day_key)["ok"], "insufficient owner funds must block construction even when other treasuries have money")
	owner.treasury = float(reconnect["cost"]) + 1000000.0
	var balance_before: float = owner.treasury
	_check(RoadPlanner.commit(region, reconnect, day_key)["ok"], "the owner must be able to fund a valid road")
	_check(is_equal_approx(owner.treasury, balance_before - reconnect["cost"]) and region.road_links.size() == initial_links - 1, "construction must debit its owner upfront and stay closed")
	RoadPlanner.advance_day(region, int(reconnect["open_day_key"]))
	AccessibilityCalculator.recalculate(region)
	_check(region.road_projects.is_empty() and region.road_links.size() == initial_links and _all_connected(region), "a completed road must restore connectivity")
	var widen_link = region.road_links[0]
	var widen: Dictionary = RoadPlanner.widen_preview(region, widen_link.id, day_key)
	_check(widen["ok"] and widen["owner_id"] == widen_link.owner_jurisdiction_id, "widening must use the road owner's budget")
	region.jurisdictions[widen["owner_id"]].treasury += widen["cost"]
	_check(RoadPlanner.commit(region, widen, day_key)["ok"], "a funded arterial must be widenable")
	RoadPlanner.advance_day(region, int(widen["open_day_key"]))
	_check(widen_link.lanes_per_direction == 2, "widening must increase capacity in both directions")
	var toll_time: int = FiscalCalculator.queue_toll(region, widen_link.id, "toll_forward", 4.0, clock.unix_seconds)
	FiscalCalculator.apply_due_policies(region, toll_time)
	_check(is_equal_approx(widen_link.toll_forward, 4.0) and is_equal_approx(widen_link.toll_reverse, 0.0), "directional toll edits must affect only their chosen direction")
	_check(region.validation_errors().is_empty(), "road and fiscal edits must preserve region invariants")
	if failures == 0:
		print("Road smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _all_connected(region) -> bool:
	var routes: Dictionary = RoadGraph.route_pairs(region, RoadGraph.free_flow_costs(region), [], false)
	for origin_id in range(region.neighborhoods.size()):
		if not region.neighborhoods[origin_id].initially_developed:
			continue
		var row: PackedFloat32Array = routes["times"][origin_id]
		for destination_id in range(row.size()):
			if region.neighborhoods[destination_id].initially_developed and row[destination_id] >= RoadGraph.UNREACHABLE_MINUTES:
				return false
	return true


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
