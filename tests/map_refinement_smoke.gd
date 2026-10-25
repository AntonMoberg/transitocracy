extends SceneTree
## Measures time to useful detail, not just frame rate while tiles are absent.
const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
const Geometry = preload("res://scripts/ui/map_geometry.gd")
var errors := PackedStringArray()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(2560,1440)
	root.content_scale_size = Vector2i(2560,1440)
	var payload: Dictionary = Setup.build(1729,768,0.1)
	var map := RegionMap.new()
	root.add_child(map)
	map.size = Vector2(2400,1250)
	map.set_region(payload.region)
	map.set_traffic_profile(payload.traffic_state.profile)
	map.set_road_traffic_mode(map.ROAD_LIVE,payload.traffic_state)
	var deadline := Time.get_ticks_msec() + 30000
	while not map.chunk_renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await create_timer(.005).timeout
	var focus: Vector2 = payload.region.neighborhoods[0].street_layout.bounds.get_center()
	for ppk in [45.0,80.0,300.0,1000.0]:
		map.zoom = ppk / map._map_scale()
		map.pan = -(focus - map._world_center()) * ppk
		var start := Time.get_ticks_msec()
		var roads_ms := -1
		var blocks_ms := -1
		var buildings_ms := -1
		while Time.get_ticks_msec() - start < 5000:
			await process_frame
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
			var elapsed := Time.get_ticks_msec() - start
			if roads_ms < 0 and _ready_layer(map.chunk_renderer,"roads"):
				roads_ms = elapsed
			if blocks_ms < 0 and _ready_layer(map.chunk_renderer,"blocks"):
				blocks_ms = elapsed
			if buildings_ms < 0 and ppk >= 200.0 and _ready_layer(map.chunk_renderer,"buildings"):
				buildings_ms = elapsed
			if roads_ms >= 0 and blocks_ms >= 0 and (ppk < 200.0 or buildings_ms >= 0):
				break
		print("Detail at %.0f px/km: roads %d ms, blocks %d ms, buildings %d ms" % [ppk,roads_ms,blocks_ms,buildings_ms])
		_check(roads_ms >= 0 and roads_ms <= 350, "visible roads took over 350 ms at %s px/km" % ppk)
		_check(blocks_ms >= 0 and blocks_ms <= 500, "visible city blocks took over 500 ms at %s px/km" % ppk)
		if ppk >= 200.0:
			_check(buildings_ms >= 0 and buildings_ms <= 1000, "visible buildings took over 1 s at %s px/km" % ppk)
		if DisplayServer.get_name() != "headless":
			root.get_texture().get_image().save_png("user://refinement_%d.png" % ppk)
	print("Visible detail latency: ", "PASS" if errors.is_empty() else errors)
	map.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)

func _ready_layer(renderer, layer: String) -> bool:
	var width: float = renderer.source.bounds.size.x / pow(2.0,renderer.target_level)
	var count: int = int(pow(2.0,renderer.target_level))
	var first := Vector2i((renderer.visible_world.position - renderer.source.bounds.position) / width).clamp(Vector2i.ZERO,Vector2i.ONE * (count - 1))
	var last := Vector2i((renderer.visible_world.end - renderer.source.bounds.position) / width).clamp(Vector2i.ZERO,Vector2i.ONE * (count - 1))
	for y in range(first.y,last.y + 1):
		for x in range(first.x,last.x + 1):
			var key := Vector3i(renderer.target_level,x,y)
			if not Geometry.tile_rect(renderer.source.bounds,key).intersects(renderer.visible_world):
				continue
			var id: String = renderer._chunk_id(key,layer)
			if not renderer.chunks.has(id) or renderer.chunks[id].epoch != renderer.epoch:
				return false
	return true

func _check(ok: bool, message: String) -> void:
	if not ok:
		errors.append(message)
		push_error(message)
