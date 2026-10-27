extends SceneTree
const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
var errors := PackedStringArray()
var samples: Array[float] = []
var cpu_samples: Array[float] = []
var worst: Dictionary = {}
var peak := 0.0
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var cities := 32
	var seed_value := 7601356
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--cities="):
			cities = int(argument.trim_prefix("--cities="))
		if argument.begins_with("--seed="):
			seed_value = int(argument.trim_prefix("--seed="))
	root.size = Vector2i(2560,1440)
	var payload: Dictionary = Setup.build(seed_value, cities, 0.1)
	var map := RegionMap.new()
	root.add_child(map)
	map.size = Vector2(2400,1250)
	map.set_region(payload.region)
	map.set_traffic_profile(payload.traffic_state.profile)
	map.set_road_traffic_mode(map.ROAD_LIVE, payload.traffic_state)
	var deadline := Time.get_ticks_msec() + 30000
	while not map.chunk_renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await process_frame
		await create_timer(0.002).timeout
	var renderer = map.chunk_renderer
	_check(not renderer.chunks.is_empty(), "initial GPU coverage was not published")
	for entry in renderer.chunks.values():
		for node in entry.nodes:
			_check(node.mesh.get_surface_count() > 0, "GPU mesh upload failed")
	var focus: Vector2 = payload.region.neighborhoods[0].street_layout.bounds.get_center()
	await _building_latency(map,focus,false)
	map.reset_view()
	for frame in range(4): await process_frame
	await _building_latency(map,focus,true)
	var count_before: int = renderer.build_count
	await _navigate(map, focus)
	deadline = Time.get_ticks_msec() + 15000
	while not renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await create_timer(0.005).timeout
	_check(renderer.is_settled(), "street detail did not settle")
	_check(renderer.visible_buildings > 0 and renderer.visible_streets > 0, "street-scale benchmark did not exercise urban geometry")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("user://renderer_street.png")
	await _navigate(map, focus)
	# Static traffic changes must not rebuild terrain or meshes.
	map.show_traffic_overlay = true
	map.reset_view()
	deadline = Time.get_ticks_msec() + 10000
	while not renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await process_frame
		await create_timer(0.002).timeout
	count_before = renderer.build_count
	for frame in range(20):
		map.set_day_road_fraction(frame / 20.0)
		map.set_hourly_road_history(-1,-1,frame / 20.0)
		await process_frame
	_check(renderer.build_count == count_before, "traffic interpolation rebuilt geometry")
	_check(renderer.cache_bytes <= renderer.CACHE_BYTES, "render cache exceeded its budget")
	# Identical daily snapshots reuse geometry, and stale work cannot replace it.
	count_before = renderer.build_count
	var border_vertices: int = payload.region.jurisdictions[0].polygon_km.size()
	var previous_epoch: int = renderer.epoch
	renderer.invalidate()
	await process_frame
	renderer.invalidate()
	deadline = Time.get_ticks_msec() + 15000
	while not renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await process_frame
		await create_timer(0.002).timeout
	_check(renderer.is_settled() and renderer.epoch > previous_epoch, "snapshot replacement did not settle")
	_check(renderer.build_count == count_before, "unchanged snapshot rebuilt geometry")
	_check(payload.region.jurisdictions[0].polygon_km.size() == border_vertices, "snapshot capture mutated the source boundary")
	for entry in renderer.chunks.values():
		if entry.wanted:
			_check(entry.epoch == renderer.epoch, "stale generation was published")
	# Pixel readback deliberately runs outside the timed section.
	if DisplayServer.get_name() != "headless":
		for ppk in [3.0,60.0,150.0,1000.0,25.0]:
			map.zoom = maxf(1.0, ppk / map._map_scale())
			map.pan = -(focus - map._world_center()) * map._map_scale() * map.zoom
			for transition_frame in range(3):
				await process_frame
				await RenderingServer.frame_post_draw
				var pixels := root.get_texture().get_image()
				var land_samples := 0
				for y in range(200,1000,80):
					for x in range(400,2000,80):
						var pixel := pixels.get_pixel(x,y)
						# Empty-map regression clears to the water background.
						if pixel.to_html(false) != RegionMap.MapStyle.WATER.to_html(false) and pixel.to_html(false) != "4c4c4c":
							land_samples += 1
				_check(land_samples >= 20, "map cleared during LOD refinement")
			if ppk == 150.0:
				root.get_texture().get_image().save_png("user://renderer_500m.png")
	map.reset_view()
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("user://renderer_overview.png")
	samples.sort()
	cpu_samples.sort()
	print("Renderer %d cities, seed %d, %s: frame p50 %.2f / p95 %.2f / p99 %.2f / max %.2f ms; CPU p95 %.2f / max %.2f ms; chunks %d, builds %d, cache %.1f MiB" % [cities,seed_value,DisplayServer.get_name(),percentile(samples,.5),percentile(samples,.95),percentile(samples,.99),samples[-1],percentile(cpu_samples,.95),cpu_samples[-1],renderer.chunks.size(),renderer.build_count,renderer.cache_bytes/1048576.0])
	print("Worst frame: ", worst)
	if OS.get_cmdline_user_args().has("--enforce-frame-budget"):
		_check(DisplayServer.get_name() != "headless", "frame budgets require a graphical renderer")
		_check(percentile(samples,.95) <= 16.7, "p95 exceeded 60 FPS frame budget")
		_check(percentile(samples,.99) <= 20.0, "p99 exceeded 20 ms")
		_check(samples[-1] <= 33.4, "a navigation frame exceeded 33.4 ms")
	if not errors.is_empty():
		push_error("; ".join(errors))
	map.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)
func _navigate(map, focus: Vector2) -> void:
	for frame in range(240):
		var started := Time.get_ticks_usec()
		var ppk: float = [1.0,3.0,25.0,60.0,200.0,1000.0,3000.0,8000.0][mini(7, frame / 30)]
		map.zoom = maxf(1.0, ppk / map._map_scale())
		map.pan = -(focus - map._world_center()) * map._map_scale() * map.zoom + Vector2(sin(frame * 0.1) * 150.0, cos(frame * 0.13) * 100.0)
		await process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
		cpu_samples.append(map.chunk_renderer.last_tick_us / 1000.0)
		if samples[-1] > peak:
			peak = samples[-1]
			worst = {"frame": frame, "ppk": ppk, "renderer_ms": map.chunk_renderer.last_tick_us / 1000.0, "map_process_ms": map.last_frame_process_us / 1000.0, "overlay_ms": map.last_overlay_us / 1000.0, "static_ms": map.last_draw_us / 1000.0, "upload_ms": map.chunk_renderer.last_publish_us / 1000.0, "stages": map.last_draw_stages_us.duplicate(), "draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
		_check(map.chunk_renderer.transform.is_equal_approx(map._screen_transform()), "geometry and picking transforms diverged")

func percentile(values: Array[float], q: float) -> float:
	return values[mini(values.size()-1, floori(values.size()*q))]

func _building_latency(map,focus:Vector2,warm:bool) -> void:
	var renderer=map.chunk_renderer
	var started:=Time.get_ticks_msec()
	var first:=-1
	var complete:=-1
	map.zoom=8000.0/map._map_scale()
	map.pan=-(focus-map._world_center())*8000.0
	while Time.get_ticks_msec()-started<5000:
		await process_frame
		if DisplayServer.get_name()!="headless": await RenderingServer.frame_post_draw
		if renderer.visible_buildings>0 and first<0: first=Time.get_ticks_msec()-started
		var covered:=0.0
		for id in renderer.chunks:
			var entry:Dictionary=renderer.chunks[id]
			if not id.begins_with("buildings:") or not entry.wanted or entry.epoch!=renderer.epoch: continue
			var fields:PackedStringArray=id.split(":")
			if int(fields[1])!=renderer.target_level: continue
			var tile:Rect2=renderer.Geometry.tile_rect(renderer.source.bounds,Vector3i(int(fields[1]),int(fields[2]),int(fields[3])))
			covered+=tile.intersection(renderer.visible_world).get_area()
		if first>=0 and covered>=renderer.visible_world.get_area()*.95:
			complete=Time.get_ticks_msec()-started
			break
	print("Building refinement %s: first=%d ms, 95%% coverage=%d ms" % ["warm" if warm else "cold",first,complete])
	_check(first>=0 and complete>=0,"buildings failed to refine after rapid zoom")
	if OS.get_cmdline_user_args().has("--enforce-frame-budget"):
		_check(first<=(100 if warm else 250),"building first-pixel latency exceeded target")
		_check(complete<=(250 if warm else 750),"building 95% coverage latency exceeded target")
func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message):
		errors.append(message)
