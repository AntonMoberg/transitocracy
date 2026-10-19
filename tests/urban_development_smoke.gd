extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Budget = preload("res://scripts/simulation/development_budget.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Accessibility = preload("res://scripts/simulation/accessibility_calculator.gd")
const Dynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const DayCycle = preload("res://scripts/simulation/day_cycle_calculator.gd")
const Traffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const LocalTraffic = preload("res://scripts/simulation/local_street_traffic.gd")
const UrbanRouting = preload("res://scripts/simulation/urban_routing.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var setup: Dictionary = Setup.build(1729, 256, 0.1)
	var region = setup["region"]
	_check(region.validation_errors().is_empty(), "initial urban state must validate")
	var developed := 0
	var local_edges := 0
	var grid_blocks := 0
	for neighborhood in region.neighborhoods:
		if not neighborhood.initially_developed:
			continue
		developed += 1
		_check(neighborhood.street_layout != null and neighborhood.development_plan.completed_phase == 3, "all starting neighborhoods must use completed street plans")
		if neighborhood.street_layout == null:
			continue
		_check(neighborhood.access_node_ids.size() >= 2, "neighborhoods must have multiple actual street access points")
		local_edges += neighborhood.street_layout.edges.size()
		var street_edges: Dictionary = {}
		for edge_id in range(neighborhood.street_layout.edges.size()):
			var edge: Vector2 = neighborhood.street_layout.edges[edge_id]
			street_edges[Vector2i(mini(int(edge.x), int(edge.y)), maxi(int(edge.x), int(edge.y)))] = neighborhood.street_layout.phases[edge_id]
		_check(neighborhood.street_layout.blocks.size() > 20, "a neighborhood must contain street-defined blocks")
		for block in neighborhood.street_layout.blocks:
			if block.get("demolished", false):
				continue
			var nodes: PackedInt32Array = block["nodes"]
			if not block.has("redevelopment_day"):
				if nodes.size() == 4:
					grid_blocks += 1
				for index in range(nodes.size()):
					var first: int = nodes[index]
					var last: int = nodes[(index + 1) % nodes.size()]
					_check(street_edges.get(Vector2i(mini(first, last), maxi(first, last)), 4) <= block["phase"], "original block boundaries must be real streets available by their construction phase")
			var footprints: Array = LayoutGenerator.buildings(block, "Residential", 0)
			for footprint in footprints:
				for vertex in footprint:
					_check(preload("res://scripts/simulation/jurisdiction_data.gd").polygon_contains_point(vertex, block["polygon"]), "buildings must stay inside their blocks")
	_check(developed == 40 and local_edges > 4000, "ten starting cities must retain four developed neighborhoods with dense local networks")
	_check(grid_blocks > 1000, "starting neighborhoods must keep predominantly square or rectangular street blocks")
	var original_layout = region.neighborhoods[0].street_layout
	var repeat: Dictionary = Setup.build(1729, 256, 0.1)
	_check(repeat["region"].neighborhoods[0].street_layout.nodes == original_layout.nodes, "street generation must reproduce the same seed")
	_check(UrbanRouting.route(region, 0, region.cities[0]["neighborhood_ids"][3])["minutes"] < RoadGraph.UNREACHABLE_MINUTES, "same-city travel must follow actual connected streets")
	_check(Traffic.fork_for_week(setup["traffic_state"]).local_districts.has(0), "worker forks must retain local traffic")
	var candidate_id := -1
	for candidate in region.development_candidates:
		if candidate["neighborhood_id"] >= 0 or candidate["frontage_link_id"] < 0 or not candidate["layout_input"].get("edge_frontage", false):
			continue
		candidate_id = candidate["id"]
		break
	_check(candidate_id >= 0, "arterials must expose one-sided neighborhood plans")
	if candidate_id < 0:
		quit(1)
		return
	var candidate: Dictionary = region.development_candidates[candidate_id]
	var city = region.jurisdictions[region.city_jurisdiction_ids[candidate["city_id"]]]
	city.treasury = 100000000.0
	var opening_balance: float = city.treasury
	var first_cost: int = candidate["layout"].phase_costs[0]
	var approval: Dictionary = Planner.set_approval(region, candidate_id, true, first_cost)
	_check(approval["ok"], "a phased allocation must approve development")
	var neighborhood = region.neighborhoods[candidate["neighborhood_id"]]
	var plan = neighborhood.development_plan
	_check(plan.reserved == first_cost and plan.spent == 0 and city.treasury == opening_balance - first_cost, "approval must reserve rather than spend money")
	var day: int = region.current_day_key + 1
	Budget.advance_day(region, day)
	_check(plan.constructing_phase == 1 and plan.completed_phase == 0 and plan.spent == first_cost and plan.reserved == 0, "construction must spend escrow without opening roads early")
	var snapshot = DayCycle.copy_region(region)
	_check(snapshot.neighborhoods[neighborhood.id].development_plan != plan and snapshot.neighborhoods[neighborhood.id].street_layout == neighborhood.street_layout, "snapshots must detach funding state and share immutable layouts")
	snapshot.neighborhoods[neighborhood.id].development_plan.reserved += 1
	_check(plan.reserved == 0, "worker budget edits must not affect the live region")
	snapshot.neighborhoods[neighborhood.id].development_plan.capacity_multiplier = 3.0
	Budget.advance_day(snapshot, day + 2)
	_check(snapshot.neighborhoods[neighborhood.id].development_plan.installed_multiplier == 1.0, "rezoning during paid construction must not install unfunded extra capacity")
	Budget.advance_day(region, day + 2)
	Accessibility.recalculate(region)
	_check(plan.completed_phase == 1 and neighborhood.access_node_ids.size() > 1, "completed first phases must provide street access")
	var new_collector_count := 0
	var new_arterial_count := 0
	for link in region.road_links:
		if link.managed_neighborhood_id == neighborhood.id:
			if link.road_class == "Collector":
				new_collector_count += 1
			elif link.road_class == "Arterial":
				new_arterial_count += 1
	_check(new_collector_count > 0 and new_arterial_count == 0, "the first phase must connect via collectors without constructing a new arterial")
	for offset in range(80):
		region.current_day_key += 1
		Dynamics.advance_day(region)
	_check(neighborhood.households <= roundi(plan.target_housing * 0.35) and neighborhood.jobs <= roundi(plan.target_jobs * 0.35), "unbuilt phases must not receive population or jobs")
	neighborhood.households = roundi(plan.target_housing * 0.35 * 0.8)
	neighborhood.population = roundi(neighborhood.households * neighborhood.people_per_household)
	Dynamics._set_jobs(neighborhood, roundi(plan.target_jobs * 0.35 * 0.8))
	Budget.advance_day(region, day + 3)
	_check(plan.status == "Awaiting funds", "unfunded extensions must pause while existing development remains")
	var second_cost: int = Budget.phase_cost(neighborhood, 2)
	_check(Budget.allocate(region, neighborhood.id, second_cost + 1234)["ok"], "allocated funds must support a later phase")
	Budget.advance_day(region, day + 4)
	var cancelled: Dictionary = Budget.cancel(region, neighborhood.id)
	_check(cancelled["refund"] == 1234 and plan.spent == first_cost + second_cost, "cancellation must return only unspent reserves")
	Budget.advance_day(region, day + 6)
	_check(plan.completed_phase == 2 and not plan.active, "already-paid work must finish after cancellation")
	_check(is_equal_approx(city.treasury + plan.reserved + plan.spent, opening_balance), "development money must be conserved")
	var invalid: Dictionary = Budget.queue_zoning(region, neighborhood.id, {"Residential": 10}, {"Residential": 0}, day + 7)
	_check(not invalid["ok"], "invalid zoning shares must be rejected")
	var shares: Dictionary = {"Residential": 100, "Commercial": 0, "Office": 0, "Mixed": 0, "Industry": 0}
	var density: Dictionary = {"Residential": 2, "Commercial": 2, "Office": 2, "Mixed": 2, "Industry": 2}
	var old_housing: int = neighborhood.housing_capacity
	var old_population: int = neighborhood.population
	_check(Budget.queue_zoning(region, neighborhood.id, shares, density, day + 7)["ok"] and neighborhood.housing_capacity == old_housing, "rezoning must wait for its daily application")
	Budget.advance_day(region, day + 8)
	_check(neighborhood.zone_shares == shares and neighborhood.population == old_population, "rezoning must not instantly create or destroy residents")
	var initial = region.neighborhoods[0]
	for existing in region.neighborhoods:
		if existing.initially_developed and existing.street_layout != null and existing.development_plan.design_demand / existing.developable_area_ha < initial.development_plan.design_demand / initial.developable_area_ha:
			initial = existing
	var frozen_zones: PackedInt32Array = initial.block_zoning.duplicate()
	var low_density: Dictionary = {"Residential": 0, "Commercial": 0, "Office": 0, "Mixed": 0, "Industry": 0}
	var initial_population: int = initial.population
	Budget.queue_zoning(region, initial.id, shares, density, day + 8)
	Budget.advance_day(region, day + 9)
	var upgrade: int = Budget.upgrade_cost(initial)
	_check(upgrade > 0 and initial.development_plan.status == "Awaiting upgrade funds", "higher demand must require a funded street upgrade")
	var initial_city = region.jurisdictions[region.city_jurisdiction_ids[initial.city_id]]
	initial_city.treasury = 100000000.0
	var paid_before: int = initial.development_plan.spent
	_check(Budget.allocate(region, initial.id, upgrade)["ok"], "upgrade costs must accept a city allocation")
	Budget.advance_day(region, day + 10)
	_check(initial.development_plan.upgrade_open_day == day + 12 and initial.development_plan.installed_multiplier == 1.0, "funded upgrades must take time to open")
	Budget.advance_day(region, day + 12)
	_check(initial.development_plan.installed_multiplier > 1.0 and initial.development_plan.spent == paid_before + upgrade, "completed upgrades must increase actual street capacity and charge exactly once")
	_check(initial.street_layout.local_upkeep(3, initial.development_plan.installed_multiplier) > initial.street_layout.local_upkeep(3), "upgraded local infrastructure must retain its higher maintenance cost")
	Budget.queue_zoning(region, initial.id, shares, low_density, day + 12)
	Budget.advance_day(region, day + 13)
	LayoutGenerator.update_buildings(initial)
	_check(initial.population == initial_population and initial.block_zoning == frozen_zones, "downzoning must preserve occupied homes and existing building footprints")
	_check(not Budget.allocate(region, initial.id, -1)["ok"] and not Budget.allocate(region, initial.id, 1000000000000)["ok"], "transfers must not overdraw reserves or city funds")
	var state = setup["traffic_state"]
	var start: int = state.unix_seconds
	LocalTraffic.advance_to(region, setup["flow"], state, start + 900)
	var record: Dictionary = state.local_districts[0]
	_check(record["entered"] > 0.0 and record["weight_sum"] > 0.0, "local streets must carry actual assigned trip demand")
	var queued := 0.0
	for queue in record["queues"]:
		queued += queue.x + queue.y
	_check(absf(record["entered"] - record["discharged"] - queued) < 0.01, "local queue loading must conserve vehicle counts")
	var fork = Traffic.fork_for_week(state)
	LocalTraffic.advance_to(region, setup["flow"], fork, start + 1800)
	_check(state.local_clock == start + 900 and fork.local_clock == start + 1800, "background traffic must not advance live local queues")
	_check(region.validation_errors().is_empty(), "phased development and rezoning must preserve model invariants")
	if failures == 0:
		print("Road-led layouts, local traffic, phased reserves, cancellation, rezoning, and snapshots passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
