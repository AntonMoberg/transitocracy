extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	var state = MultiScaleTraffic.new_day(region, flow, clock.unix_seconds)
	var first_time: int = state.unix_seconds
	var queue_probe_region = RegionSnapshot.copy_region(region)
	var queue_probe_state = MultiScaleTraffic.new_day(queue_probe_region, flow, first_time)
	MultiScaleTraffic.advance(region, flow, state, first_time + 60, MultiScaleTraffic.SECOND)
	MultiScaleTraffic.advance(queue_probe_region, flow, queue_probe_state, first_time + 60, MultiScaleTraffic.MINUTE)
	_check(absf(state.queued_cars() - queue_probe_state.queued_cars()) < 0.05, "second and minute modes share the same directional queue totals")
	state = MultiScaleTraffic.new_day(region, flow, first_time)
	var policy_city_id: int = region.city_jurisdiction_ids[0]
	var old_parking: float = region.jurisdictions[policy_city_id].parking_fee
	FiscalCalculator.queue_policy(region, policy_city_id, "parking_fee", old_parking + 3.0, first_time)
	MultiScaleTraffic.advance(region, flow, state, first_time + 900, MultiScaleTraffic.MINUTE)
	_check(is_equal_approx(region.jurisdictions[policy_city_id].parking_fee, old_parking), "quarter-hour policy must wait for its effective time")
	MultiScaleTraffic.advance(region, flow, state, first_time + 901, MultiScaleTraffic.MINUTE)
	_check(is_equal_approx(region.jurisdictions[policy_city_id].parking_fee, old_parking + 3.0), "quarter-hour policy must apply on the next step")
	state = MultiScaleTraffic.new_day(region, flow, first_time)
	MultiScaleTraffic.advance(region, flow, state, first_time + 1, MultiScaleTraffic.SECOND)
	_check(state.unix_seconds == first_time + 1, "second solver advances exactly one second")
	_check(state.cached_links.size() == region.road_links.size(), "second solver assigns directional roads")
	MultiScaleTraffic.change_mode(region, flow, state, MultiScaleTraffic.SECOND, MultiScaleTraffic.MINUTE)
	MultiScaleTraffic.advance(region, flow, state, first_time + 61, MultiScaleTraffic.MINUTE)
	_check(state.unix_seconds == first_time + 61, "minute solver carries time and queues")
	var before_macro: float = state.queued_cars()
	MultiScaleTraffic.change_mode(region, flow, state, MultiScaleTraffic.MINUTE, MultiScaleTraffic.HOUR)
	MultiScaleTraffic.advance(region, flow, state, first_time + 3661, MultiScaleTraffic.HOUR)
	_check(state.unix_seconds == first_time + 3661 and state.cached_mode == MultiScaleTraffic.HOUR, "hour solver advances with city aggregation")
	MultiScaleTraffic.change_mode(region, flow, state, MultiScaleTraffic.HOUR, MultiScaleTraffic.DAY)
	MultiScaleTraffic.advance(region, flow, state, (state.day_key + 1) * 86400, MultiScaleTraffic.DAY)
	_check(state.next_bin == 96, "day solver reaches midnight")
	var next_result: Dictionary = MultiScaleDayCalculator.advance_day(region, state.day_key + 1, flow, state)
	var next_state = next_result["traffic_state"]
	_check(next_state.day_key == state.day_key + 1 and next_state.link_ids.size() == state.link_ids.size(), "daily economy keeps the road state")
	var macro_queue_total: float = next_state.queued_cars()
	MultiScaleTraffic.change_mode(next_result["region"], next_result["flow"], next_state, MultiScaleTraffic.DAY, MultiScaleTraffic.SECOND)
	_check(absf(next_state.queued_cars() - macro_queue_total) < 0.1, "returning to detail preserves aggregate queue count")
	_check(next_state.estimated == false and next_state.queued_cars() >= 0.0 and before_macro >= 0.0, "return to detailed mode reconstructs nonnegative traffic")
	var junction_region = RegionSnapshot.copy_region(region)
	var hub_id: int = -1
	for node in junction_region.road_nodes:
		var approaches := 0
		for link in region.road_links:
			if link.from_node_id == node.id or link.to_node_id == node.id:
				approaches += 1
		if approaches >= 3:
			hub_id = node.id
			node.is_interchange = false
			break
	_check(hub_id >= 0, "starter city hubs can provide a shared junction fixture")
	var junction_state = MultiScaleTraffic.new_day(junction_region, flow, first_time)
	if hub_id >= 0:
		var loading := PackedVector2Array()
		loading.resize(region.road_links.size())
		for index in range(region.road_links.size()):
			var link = region.road_links[index]
			if link.to_node_id == hub_id:
				loading[index] = Vector2(5000.0, loading[index].y)
			elif link.from_node_id == hub_id:
				loading[index] = Vector2(loading[index].x, 5000.0)
		junction_state.cached_links = loading
		MultiScaleTraffic._advance_links(junction_region, flow, junction_state, 7, 900)
		var junction_served := 0.0
		for index in range(region.road_links.size()):
			var link = region.road_links[index]
			if link.to_node_id == hub_id:
				junction_served += junction_state.last_served[index].x * 0.25
			elif link.from_node_id == hub_id:
				junction_served += junction_state.last_served[index].y * 0.25
		_check(junction_served <= junction_state.junction_capacity_hr[hub_id] * 0.25 + 0.1, "shared junction capacity limits simultaneous approaches")
	for aggregate_mode in [MultiScaleTraffic.HOUR, MultiScaleTraffic.DAY]:
		var group_count: int = region.cities.size() if aggregate_mode == MultiScaleTraffic.HOUR else region.region_ids.size()
		var internal_only: Array[PackedFloat32Array] = []
		for group_id in range(group_count):
			var row := PackedFloat32Array()
			row.resize(group_count)
			if group_id == 0:
				row[group_id] = 1000.0
			internal_only.append(row)
		var internal_volume := PackedVector2Array()
		internal_volume.resize(region.road_links.size())
		MultiScaleTraffic._add_internal_group_load(region, aggregate_mode, internal_only, internal_volume)
		var assigned_internal := 0.0
		for link_volume in internal_volume:
			assigned_internal += link_volume.x + link_volume.y
		_check(assigned_internal > 0.0, "aggregate modes retain trips within the same city or region")
	var first_city_neighborhoods: Array = region.cities[0]["neighborhood_ids"]
	var local_origin: int = first_city_neighborhoods[0]
	var local_destination: int = first_city_neighborhoods[1]
	var free_link_times: PackedVector2Array = junction_state.profile.hourly_link_times[0]
	for aggregate_mode in [MultiScaleTraffic.HOUR, MultiScaleTraffic.DAY]:
		junction_state.cached_mode = aggregate_mode
		for quarter in range(28, 32):
			var link_times: PackedVector2Array = free_link_times.duplicate()
			for link_index in range(region.road_links.size()):
				var link = region.road_links[link_index]
				if MultiScaleTraffic._group_for_node(region, link.from_node_id, aggregate_mode) == 0 and MultiScaleTraffic._group_for_node(region, link.to_node_id, aggregate_mode) == 0:
					link_times[link_index] *= 2.0
			junction_state.profile.quarter_hour_link_times[quarter] = link_times
		MultiScaleTraffic._finish_hour(region, junction_state, 7)
		var local_travel_time: float = junction_state.profile.hourly_pair_times[7][local_origin][local_destination]
		_check(local_travel_time > junction_state.free_pair_times[local_origin][local_destination] * 1.5, "aggregate local congestion affects daily travel time")
	if failures == 0:
		print("Multiscale simulation smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
