extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const NeighborhoodDynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var target := 5000
	var refresh_candidates := false
	var map_index := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--neighborhoods="):
			target = maxi(5000, int(argument.trim_prefix("--neighborhoods=")))
		if argument == "--refresh-candidates":
			refresh_candidates = true
		if argument == "--map-index":
			map_index = true
	var started: int = Time.get_ticks_usec()
	var region = RegionGenerator.generate_large_region(1729, 256)
	var per_city: int = ceili(float(target) / 256.0)
	for city in region.cities:
		var city_id: int = city["id"]
		var center: Vector2 = city["center_km"]
		var origin: Vector2i = StateGeography.cell_grid_at_point(region.generation_seed, center)
		var occupied: Dictionary = {}
		for neighborhood_id in city["neighborhood_ids"]:
			var neighborhood = region.neighborhoods[neighborhood_id]
			var grid: Vector2i = neighborhood.cell_grid
			occupied[grid] = true
		for radius in range(0, 35):
			if city["neighborhood_ids"].size() >= per_city:
				break
			for y in range(-radius, radius + 1):
				for x in range(-radius, radius + 1):
					if maxi(absi(x), absi(y)) != radius or city["neighborhood_ids"].size() >= per_city:
						continue
					var grid := origin + Vector2i(x, y)
					if occupied.has(grid):
						continue
					var point: Vector2 = StateGeography.cell_site(region.generation_seed, grid)
					if not region.jurisdictions[city["jurisdiction_id"]].contains_point(point):
						continue
					var polygon: PackedVector2Array = StateGeography.cell_polygon(region, city_id, grid)
					if StateGeography.polygon_area(polygon) < 0.4:
						continue
					RegionGenerator.append_neighborhood(region, city_id, polygon, grid)
					occupied[grid] = true
		if city["neighborhood_ids"].size() < per_city:
			push_error("Could not place %d neighborhoods in city %d." % [per_city, city_id])
			quit(1)
			return
	for neighborhood in region.neighborhoods:
		if neighborhood.population == 0:
			neighborhood.jobs = 0
			neighborhood.jobs_by_skill = {"Entry": 0, "Skilled": 0, "Professional": 0}
			neighborhood.shopping_attraction = 0.0
			var rng := RandomNumberGenerator.new()
			rng.seed = 1729 * 1000003 + neighborhood.id * 9176
			RegionGenerator._populate_capacity_and_occupancy(neighborhood, rng, region.cities[neighborhood.city_id]["density"])
		neighborhood.initially_developed = true
		neighborhood.development_approved = true
	region.starting_city_ids.clear()
	for city in region.cities:
		region.starting_city_ids.append(city["id"])
	print("Placed %d occupied economic neighborhoods in %.1f ms" % [region.neighborhoods.size(), float(Time.get_ticks_usec() - started) / 1000.0])
	RoadNetworkGenerator.generate(region)
	var streeted := 0
	var fine_edges := 0
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout != null:
			streeted += 1
			fine_edges += neighborhood.street_layout.edges.size()
	print("Built %d street layouts with %d fine edges in %.1f ms" % [streeted, fine_edges, float(Time.get_ticks_usec() - started) / 1000.0])
	if streeted < target:
		push_error("Scale fixture must contain at least %d fully streeted neighborhoods, not only economic cells." % target)
		quit(1)
		return
	if refresh_candidates:
		var refresh_started: int = Time.get_ticks_usec()
		DevelopmentPlanner.refresh_candidates(region)
		var first_refresh_ms: float = float(Time.get_ticks_usec() - refresh_started) / 1000.0
		refresh_started = Time.get_ticks_usec()
		DevelopmentPlanner.refresh_candidates(region)
		print("Candidate refresh: %.1f ms first, %.1f ms repeat, %d candidates" % [first_refresh_ms, float(Time.get_ticks_usec() - refresh_started) / 1000.0, region.development_candidates.size()])
	AccessibilityCalculator.recalculate(region)
	NeighborhoodDynamics.initialize(region)
	var clock = CalendarClock.new()
	region.current_day_key = floori(float(clock.unix_seconds) / 86400.0)
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	if flow.is_compact:
		var max_origin_error := 0.0
		for city in region.cities:
			var city_target := 0.0
			for neighborhood_id in city["neighborhood_ids"]:
				city_target += flow.compact_origin_daily["Work"][neighborhood_id]
			var actual := 0.0
			for value in flow.compact_city_od["Work"][city["id"]]:
				actual += value
			max_origin_error = maxf(max_origin_error, absf(actual - city_target) / maxf(1.0, city_target))
		print("Work OD max origin error: %.3f%%" % (max_origin_error * 100.0))
	var state = MultiScaleTraffic.new_day(region, flow, clock.unix_seconds)
	var generation_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var snapshot = RegionSnapshot.copy_region(region)
	var copy_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	if map_index:
		var map := RegionMap.new()
		root.add_child(map)
		map.size = Vector2(900, 600)
		map.set_region(region)
		var index_started: int = Time.get_ticks_usec()
		map._ensure_spatial_index()
		var initial_index_ms: float = float(Time.get_ticks_usec() - index_started) / 1000.0
		map.region = snapshot
		index_started = Time.get_ticks_usec()
		map._ensure_spatial_index()
		var reused_index_ms: float = float(Time.get_ticks_usec() - index_started) / 1000.0
		print("Map road index: %.1f ms initial, %.3f ms unchanged day" % [initial_index_ms, reused_index_ms])
		var center: Vector2 = region.cities[region.starting_city_ids[0]]["center_km"]
		for magnification in [2.0, 16.0]:
			map.zoom = magnification
			map.pan = -(center - map._world_center()) * map._map_scale() * magnification
			map.queue_redraw()
			await process_frame
			await process_frame
			map.queue_redraw()
			await process_frame
			await process_frame
			print("Map zoom %.0f warm draw: %.1f ms (roads %.1f ms)" % [magnification, float(map.last_draw_us) / 1000.0, float(map.last_draw_stages_us["roads"] - map.last_draw_stages_us["cities"]) / 1000.0])
		if refresh_candidates:
			map.set_map_mode("Zoning")
			map.queue_redraw()
			await process_frame
			await process_frame
			map.queue_redraw()
			await process_frame
			await process_frame
			print("Zoning zoom 16 warm draw: %.1f ms" % (float(map.last_draw_us) / 1000.0))
		map.set_map_mode("Roads")
		map.zoom = 250.0 / map._map_scale()
		map.pan = -(region.neighborhoods[0].street_layout.bounds.get_center() - map._world_center()) * map._map_scale() * map.zoom
		map.queue_redraw()
		await process_frame
		await process_frame
		map.queue_redraw()
		await process_frame
		await process_frame
		print("Street zoom warm draw: %.1f ms, %d local streets, %d buildings" % [float(map.last_draw_us) / 1000.0, map.urban_layer.last_street_count, map.urban_layer.last_building_count])
	started = Time.get_ticks_usec()
	var next: Dictionary = MultiScaleDayCalculator.advance_day(snapshot, region.current_day_key + 1, flow, state)
	var day_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	var errors: PackedStringArray = next["region"].validation_errors()
	print("Active scale: %d neighborhoods, %d roads, %d people" % [region.neighborhoods.size(), region.road_links.size(), region.get_region_totals()["population"]])
	print("Generation %.1f ms, detached copy %.1f ms, next day %.1f ms" % [generation_ms, copy_ms, day_ms])
	print("Next-day stages: %s" % next["timings_us"])
	if not errors.is_empty():
		push_error("Scaled region failed validation: " + "; ".join(errors.slice(0, 5)))
	quit(1 if not errors.is_empty() else 0)
