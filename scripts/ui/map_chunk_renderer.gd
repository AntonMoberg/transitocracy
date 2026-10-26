extends Node2D
## Persistent world-space GPU chunks. Only this node publishes worker results.
const Style = preload("res://scripts/ui/map_style.gd")
const LocalTraffic = preload("res://scripts/simulation/local_street_traffic.gd")
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const FILL_SHADER = preload("res://scripts/ui/shaders/map_fill.gdshader")
const LINE_SHADER = preload("res://scripts/ui/shaders/map_line.gdshader")
const LAYERS = ["water", "borders", "blocks", "clearance", "roads", "structures", "buildings"]
const BUDGET_US = 1000
const CACHE_BYTES = 192 * 1024 * 1024
const MAX_WORKERS = 2

var map
var source: Dictionary = {}
var snapshot: Dictionary = {}
var snapshot_region
var snapshot_cursor := 0
var snapshot_stage := 0
var neighborhood_part := 0
var reservation_part := 0
var neighborhood_masks: Array[PackedVector2Array] = []
var requested_signature := ""
var epoch := 0
var workers: Array[Dictionary] = []
var chunks: Dictionary = {}
var requests: Dictionary = {}
var uploads: Array[Dictionary] = []
var retire: Array[Node] = []
var cache_bytes := 0
var build_count := 0
var publish_count := 0
var discarded_count := 0
var last_publish_us := 0
var last_tick_us := 0
var target_level := 0
var visible_world := Rect2()
var traffic_image: Image
var traffic_texture: ImageTexture
var previous_texture: ImageTexture
var traffic_slots: Dictionary = {}
var traffic_cursor := 0
var traffic_next := 0
var traffic_published := 0
var traffic_pending := false
var traffic_signature := ""
var tick_id := 0
var watch_cursor := 0
var watched: Dictionary = {}
var traffic_revision := 0
var fill_material := ShaderMaterial.new()
var line_material := ShaderMaterial.new()
var current_materials: Array[ShaderMaterial] = []

func _ready() -> void:
	fill_material.shader = FILL_SHADER
	line_material.shader = LINE_SHADER
	line_material.set_shader_parameter("road_colors", PackedColorArray(Style.ROAD_COLORS))
	line_material.set_shader_parameter("water_color", Style.WATER)
	current_materials.append(line_material)
var visible_buildings := 0
var visible_streets := 0
var visible_districts := 0

func _exit_tree() -> void:
	for worker in workers:
		worker.thread.wait_to_finish()

func signature() -> String:
	# O(1) gate. Daily snapshots may replace objects without changing geography.
	return "%s:%d:%d:%d:%d:%d" % [map.region.terrain.get_instance_id(), map.region.road_geometry_revision, map.region.neighborhoods.size(), map.region.current_day_key, map.region.road_reservations.size(), map.region.development_candidates.size()]

func invalidate() -> void:
	requested_signature = ""

func _neighborhood_signature(neighborhood) -> int:
	return hash([neighborhood.street_layout.get_instance_id() if neighborhood.street_layout != null else 0, hash(neighborhood.block_zoning), neighborhood.built_fraction, neighborhood.character_profile, neighborhood.development_plan.completed_phase if neighborhood.development_plan != null else -1])

func _watch_geometry(deadline: int) -> void:
	if not snapshot.is_empty() or map.region.neighborhoods.is_empty():
		return
	for worker in workers:
		if worker.kind == "index":
			return
	while Time.get_ticks_usec() < deadline:
		watch_cursor = watch_cursor % map.region.neighborhoods.size()
		var neighborhood = map.region.neighborhoods[watch_cursor]
		var stamp := _neighborhood_signature(neighborhood)
		if watched.has(neighborhood.id) and watched[neighborhood.id] != stamp:
			invalidate()
			watched[neighborhood.id] = stamp
			return
		watched[neighborhood.id] = stamp
		watch_cursor += 1
		if watch_cursor >= map.region.neighborhoods.size():
			return

func tick() -> void:
	if map.region == null:
		return
	var started := Time.get_ticks_usec()
	tick_id += 1
	transform = map._screen_transform()
	var ppk: float = map._map_scale() * map.zoom
	var first: Vector2 = map._screen_to_world(Vector2.ZERO)
	visible_world = Rect2(first, map.size / ppk)
	_watch_geometry(started + 200)
	var next_signature := signature()
	if next_signature != requested_signature:
		_start_snapshot(next_signature)
	_capture_snapshot(started + BUDGET_US)
	_poll_workers()
	_publish(started + BUDGET_US)
	if not source.is_empty():
		var desired := maxi(0, floori(log(maxf(1.0, source.bounds.size.x * ppk / 512.0)) / log(2.0)))
		if desired > target_level and source.bounds.size.x * ppk / pow(2.0, target_level + 1) > 512.0 * 1.15:
			target_level = desired
		elif desired < target_level and source.bounds.size.x * ppk / pow(2.0, target_level) < 512.0 * 0.85:
			target_level = desired
		target_level = mini(target_level, 18)
		_select_chunks(ppk)
		_start_jobs()
		_update_traffic(started + 2000)
		_update_materials(ppk)
		_evict(started + 2000)
	last_tick_us = Time.get_ticks_usec() - started

func _start_snapshot(next_signature: String) -> void:
	epoch += 1
	requested_signature = next_signature
	snapshot_region = map.region
	var bounds: Rect2 = snapshot_region.jurisdictions[0].bounds_km
	var width: float = pow(2.0, ceilf(log(maxf(bounds.size.x, bounds.size.y)) / log(2.0)))
	var same_terrain: bool = source.get("terrain") == snapshot_region.terrain
	snapshot = {"features": [], "bounds": Rect2(bounds.position, Vector2.ONE * width), "terrain": snapshot_region.terrain, "epoch": epoch, "slots": source.get("slots", {}).duplicate() if same_terrain else {}, "previous": source.get("fingerprints", {}) if same_terrain else {}, "local_slots": [], "signature": next_signature}
	snapshot_cursor = 0
	snapshot_stage = 0
	neighborhood_part = 0
	reservation_part = 0

func _capture_snapshot(deadline: int) -> void:
	if snapshot.is_empty():
		return
	while Time.get_ticks_usec() < deadline:
		var region = snapshot_region
		match snapshot_stage:
			0:
				if snapshot_cursor >= region.road_links.size():
					_next_stage()
					continue
				var link = region.road_links[snapshot_cursor]
				var style: int = Style.road_style(link)
				var limits: Vector2 = Style.road_range(style, link.map_major)
				var slot: int = snapshot.slots.get(link.id, snapshot.slots.size())
				snapshot.slots[link.id] = slot
				snapshot.features.append({"identity": "road:%d" % link.id, "kind": "line", "layer": "roads", "points": link.points.duplicate(), "lanes": link.lanes_per_direction, "highway": link.road_class == "Highway", "slot": slot, "min_ppk": limits.x, "fade": limits, "style": style, "junctions": link.junctions.duplicate(true), "crossings": link.crossings.duplicate(true), "terrain_spans": link.terrain_spans.duplicate(true)})
			1:
				if snapshot_cursor >= region.jurisdictions.size():
					_next_stage()
					continue
				var area = region.jurisdictions[snapshot_cursor]
				if area.kind == "Neighborhood" and (area.neighborhood_ids.is_empty() or region.neighborhoods[area.neighborhood_ids[0]].street_layout == null):
					snapshot_cursor += 1
					continue
				var polygon: PackedVector2Array = area.polygon_km.duplicate()
				if not polygon.is_empty():
					polygon.append(polygon[0])
					snapshot.features.append({"identity": "border:%d" % area.id, "kind": "line", "layer": "borders", "points": polygon, "min_ppk": 25.0 if area.kind == "Neighborhood" else (3.0 if area.kind == "City" else 0.0), "pixels": 1.0})
			2:
				if snapshot_cursor >= region.terrain.rivers.size():
					_next_stage()
					continue
				var river: Dictionary = region.terrain.rivers[snapshot_cursor]
				snapshot.features.append({"identity": "river:%d" % snapshot_cursor, "kind": "line", "layer": "water", "points": river.points.duplicate(), "meters": float(river.width_km) * 1000.0, "pixels": 1.0, "slot": -2, "widths": river.get("widths_km", PackedFloat32Array()).duplicate(), "fade": Style.river_range(float(river.width_km)), "min_ppk": Style.river_range(float(river.width_km)).x})
			3:
				if snapshot_cursor >= region.terrain.lakes.size():
					_next_stage()
					continue
				var lake: Dictionary = region.terrain.lakes[snapshot_cursor]
				snapshot.features.append({"identity": "lake:%d" % snapshot_cursor, "kind": "block", "layer": "water", "points": lake.polygon.duplicate(), "color": Style.WATER})
			4:
				if snapshot_cursor >= region.neighborhoods.size():
					_next_stage()
					continue
				if not _capture_neighborhood(region.neighborhoods[snapshot_cursor]):
					continue
			5:
				if snapshot_cursor >= region.road_reservations.size():
					_next_stage()
					continue
				var reservation: Dictionary = region.road_reservations[snapshot_cursor]
				if reservation_part < reservation.masks.size():
					snapshot.features.append({"identity": "clearance:%d:%d" % [snapshot_cursor, reservation_part], "kind": "block", "layer": "clearance", "points": reservation.masks[reservation_part].duplicate(), "color": Color("24343b"), "min_ppk": 25.0})
					reservation_part += 1
					continue
				reservation_part = 0
			_:
				if workers.size() + map.terrain_detail_workers.size() >= MAX_WORKERS:
					return
				var thread := Thread.new()
				var owned := snapshot
				snapshot = {}
				if thread.start(Callable(Geometry, "index_source").bind(owned), Thread.PRIORITY_LOW) == OK:
					workers.append({"thread": thread, "kind": "index", "epoch": epoch})
				else:
					snapshot = owned
				return
		snapshot_cursor += 1

func _next_stage() -> void:
	snapshot_stage += 1
	snapshot_cursor = 0

func _capture_neighborhood(neighborhood) -> bool:
	var layout = neighborhood.street_layout
	var plan = neighborhood.development_plan
	if layout == null or plan == null:
		neighborhood_part = 0
		return true
	# Capture one edge/block per budget check, not an entire district at once.
	if neighborhood_part == 0:
		watched[neighborhood.id] = _neighborhood_signature(neighborhood)
		neighborhood_masks = []
		for reservation in snapshot_region.road_reservations:
			if reservation.bounds.intersects(layout.bounds):
				neighborhood_masks.append_array(reservation.masks)
	if neighborhood_part < layout.edges.size():
		var edge_id: int = neighborhood_part
		neighborhood_part += 1
		if layout.classes[edge_id] == "Local" and not layout.closed_edges.has(edge_id) and layout.phases[edge_id] <= plan.completed_phase:
			var edge: Vector2 = layout.edges[edge_id]
			var points: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]]))
			var address := Vector2i(neighborhood.id, edge_id)
			var slot: int = snapshot.slots.get(address, snapshot.slots.size())
			snapshot.slots[address] = slot
			snapshot.local_slots.append(address)
			snapshot.features.append({"slot": slot, "identity": "street:%d:%d" % [neighborhood.id, edge_id], "kind": "line", "layer": "roads", "points": points.duplicate(), "lanes": 1, "local": true, "style": Style.RoadStyle.LOCAL, "fade": Style.road_range(Style.RoadStyle.LOCAL), "min_ppk": 110.0})
		return false
	var block_id: int = neighborhood_part - layout.edges.size()
	if block_id >= layout.blocks.size():
		neighborhood_part = 0
		return true
	neighborhood_part += 1
	var block: Dictionary = layout.blocks[block_id]
	if int(block.phase) > plan.completed_phase or block.get("demolished", false):
		return false
	snapshot.features.append({"identity": "block:%d:%d" % [neighborhood.id, block_id], "kind": "block", "layer": "blocks", "points": block.polygon.duplicate(), "color": Style.PARK if block.park else Style.URBAN, "urban_fill": not block.park, "min_ppk": 0.0})
	if block.park or block_id >= neighborhood.block_zoning.size() or neighborhood.block_zoning[block_id] == 0:
		return false
	var code: int = neighborhood.block_zoning[block_id] - 1
	var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][code / 3]
	var developed: float = neighborhood.built_fraction
	if int(block.get("redevelopment_day", -1)) >= 0:
		developed = minf(developed, clampf(float(snapshot_region.current_day_key - int(block.redevelopment_day)) / 180.0, 0.0, 1.0))
	snapshot.features.append({"identity": "building:%d:%d" % [neighborhood.id, block_id], "kind": "buildings", "layer": "buildings", "points": block.polygon.duplicate(), "block": block.duplicate(true), "zone": zone, "density": code % 3, "character": neighborhood.character_profile, "developed": developed, "masks": neighborhood_masks, "color": map.urban_layer.ZoneColors[zone], "min_ppk": 200.0})
	return false

func _poll_workers() -> void:
	for i in range(workers.size() - 1, -1, -1):
		var job: Dictionary = workers[i]
		if job.thread.is_alive():
			continue
		var result: Dictionary = job.thread.wait_to_finish()
		workers.remove_at(i)
		if int(job.epoch) != epoch:
			discarded_count += 1
			continue
		if job.kind == "index":
			# Old chunks remain visible until their replacements are published.
			source = result
			for id in chunks:
				var fields: PackedStringArray = id.split(":")
				var key := Vector3i(int(fields[1]), int(fields[2]), int(fields[3]))
				var rect := Geometry.tile_rect(source.bounds, key)
				var dirty := false
				for changed_rect in source.changed.get(fields[0], []):
					if rect.intersects(changed_rect):
						dirty = true
						break
				if not dirty:
					chunks[id].epoch = epoch
			requests.clear()
			var resized: bool = traffic_image == null or traffic_slots.size() != source.slots.size()
			traffic_slots = source.slots
			traffic_signature = ""
			if resized:
				_setup_traffic()
		else:
			for packet in result.get("results", [result]):
				packet["part"] = 0
				packet["nodes"] = []
				packet["bytes"] = 0
				uploads.append(packet)

func _chunk_id(key: Vector3i, layer: String) -> String:
	return "%s:%d:%d:%d" % [layer, key.x, key.y, key.z]

func _request(key: Vector3i, layer: String) -> void:
	var id := _chunk_id(key, layer)
	if chunks.has(id) and chunks[id].epoch == epoch:
		return
	if not requests.has(id):
		requests[id] = {"key": key, "layer": layer, "epoch": epoch, "running": false}

func _select_chunks(ppk: float) -> void:
	for entry in chunks.values():
		entry.wanted = false
	visible_buildings = 0
	visible_streets = 0
	visible_districts = 0
	for layer in LAYERS:
		var minimum: float = 200.0 if layer == "buildings" else 0.0
		if ppk < minimum:
			continue
		# Request the destination LOD immediately, not a staircase of parents.
		if layer in ["roads", "water", "borders", "blocks"]:
			_request(Vector3i.ZERO, layer)
		var width: float = source.bounds.size.x / pow(2.0, target_level)
		var count: int = int(pow(2.0, target_level))
		var first := Vector2i((visible_world.position - source.bounds.position) / width).clamp(Vector2i.ZERO, Vector2i.ONE * (count - 1))
		var last := Vector2i((visible_world.end - source.bounds.position) / width).clamp(Vector2i.ZERO, Vector2i.ONE * (count - 1))
		for y in range(maxi(0,first.y - 1), mini(count,last.y + 2)):
			for x in range(maxi(0,first.x - 1), mini(count,last.x + 2)):
				_request(Vector3i(target_level,x,y), layer)
		var coverage := _coverage(Vector3i.ZERO, layer)
		for id in coverage.ids:
			chunks[id].wanted = true
	for entry in chunks.values():
		for node in entry.nodes:
			node.visible = entry.wanted
		if entry.wanted:
			entry.used = tick_id
			visible_buildings += entry.get("buildings", 0)
			visible_streets += entry.get("streets", 0)
			visible_districts += entry.get("districts", 0)

func _coverage(key: Vector3i, layer: String) -> Dictionary:
	var rect := Geometry.tile_rect(source.bounds, key)
	if not rect.intersects(visible_world):
		return {"ids": [], "complete": true}
	var id := _chunk_id(key, layer)
	if key.x >= target_level:
		return {"ids": [id] if chunks.has(id) else [], "complete": chunks.has(id)}
	var ids: Array = []
	var complete := true
	for y in range(2):
		for x in range(2):
			var child := _coverage(Vector3i(key.x + 1,key.y * 2 + x,key.z * 2 + y),layer)
			ids.append_array(child.ids)
			complete = complete and child.complete
	if not complete and chunks.has(id) and not chunks[id].nodes.is_empty():
		return {"ids": [id], "complete": true}
	return {"ids": ids, "complete": complete}

func _job_priority(job: Dictionary) -> float:
	var rect := Geometry.tile_rect(source.bounds, job.key)
	var visible := rect.intersects(visible_world)
	var priority: float = 0.0 if visible else 100.0
	if job.key.x == 0:
		priority -= 10.0
	priority += ["roads","blocks","buildings","clearance","structures","water","borders"].find(job.layer)
	return priority + minf(0.9, rect.get_center().distance_to(visible_world.get_center()) / maxf(1.0,visible_world.size.length()) * 0.1)

func _start_jobs() -> void:
	if map.terrain_base_pending or source.epoch != epoch:
		return
	if workers.size() + map.terrain_detail_workers.size() >= MAX_WORKERS:
		return
	var pending: Array = []
	for id in requests.keys():
		var job: Dictionary = requests[id]
		if job.running or job.epoch != epoch:
			continue
		var rect := Geometry.tile_rect(source.bounds, job.key)
		if not rect.intersects(visible_world.grow(rect.size.x)) or job.key.x not in [0, target_level]:
			requests.erase(id)
			continue
		job["priority"] = _job_priority(job)
		pending.append(id)
	pending.sort_custom(func(a: String, b: String) -> bool: return requests[a].priority < requests[b].priority)
	while not pending.is_empty() and workers.size() + map.terrain_detail_workers.size() < MAX_WORKERS:
		var batch: Array = []
		var ids: Array = []
		var first: Dictionary = requests[pending[0]]
		var limit := 1 if first.layer == "buildings" else 4
		while not pending.is_empty() and batch.size() < limit:
			var id: String = pending[0]
			if requests[id].layer != first.layer:
				break
			pending.pop_front()
			ids.append(id)
			batch.append(requests[id].duplicate())
		var thread := Thread.new()
		if thread.start(Callable(Geometry, "build_batch").bind(source, batch), Thread.PRIORITY_LOW) == OK:
			for id in ids:
				requests[id].running = true
			workers.append({"thread": thread, "kind": "chunks", "epoch": epoch})
			build_count += batch.size()


func _publish(deadline: int) -> void:
	var started := Time.get_ticks_usec()
	while not uploads.is_empty() and Time.get_ticks_usec() < deadline:
		var result: Dictionary = uploads[0]
		if result.epoch != epoch:
			for node in result.nodes:
				retire.append(node)
			uploads.pop_front()
			continue
		if result.part < result.parts.size():
			var part: Dictionary = result.parts[result.part]
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = part.vertices
			arrays[Mesh.ARRAY_TEX_UV] = part.uv
			var flags := 0
			# Line metadata uses float custom attributes, not clamped vertex colors.
			var is_line: bool = part.get("line", false)
			if is_line:
				arrays[Mesh.ARRAY_CUSTOM0] = part.colors.to_byte_array().to_float32_array()
				arrays[Mesh.ARRAY_CUSTOM1] = part.styles
				flags = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
			else:
				arrays[Mesh.ARRAY_COLOR] = part.colors
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
			if mesh.get_surface_count() == 0:
				for failed_node in result.nodes:
					retire.append(failed_node)
				requests.erase(_chunk_id(result.key, result.layer))
				uploads.pop_front()
				push_error("Map mesh upload failed; retaining previous coverage.")
				continue
			var node := MeshInstance2D.new()
			var tile_bounds := Geometry.tile_rect(source.bounds, result.key)
			mesh.custom_aabb = AABB(Vector3(tile_bounds.position.x, tile_bounds.position.y, 0.0), Vector3(tile_bounds.size.x, tile_bounds.size.y, 0.0))
			node.mesh = mesh
			node.visible = false
			node.z_index = LAYERS.find(result.layer) * 2
			if is_line:
				node.material = line_material
				var rect := Geometry.tile_rect(source.bounds, result.key)
				node.set_instance_shader_parameter("clip_rect", Vector4(rect.position.x, rect.position.y, rect.end.x, rect.end.y))
			else:
				node.material = fill_material
				node.set_instance_shader_parameter("fill_role", {"water": 0, "blocks": 1, "buildings": 2, "clearance": 3, "roads": 5}.get(result.layer, 4))
			add_child(node)
			result.nodes.append(node)
			result.bytes += part.vertices.size() * (48 if is_line else 32)
			result.parts[result.part] = {} # Release CPU arrays as each part reaches the GPU.
			result.part += 1
			continue
		var id := _chunk_id(result.key, result.layer)
		if chunks.has(id):
			cache_bytes -= int(chunks[id].bytes)
			for node in chunks[id].nodes:
				node.hide()
				retire.append(node)
		chunks[id] = {"nodes": result.nodes, "epoch": result.epoch, "bytes": result.bytes, "used": tick_id, "wanted": false, "buildings": result.buildings, "streets": result.streets, "districts": result.districts}
		cache_bytes += result.bytes
		requests.erase(id)
		uploads.pop_front()
		publish_count += 1
	last_publish_us = Time.get_ticks_usec() - started

func _evict(deadline: int) -> void:
	if cache_bytes > CACHE_BYTES or chunks.size() > 768:
		var oldest := ""
		var age := tick_id
		for id in chunks:
			var entry: Dictionary = chunks[id]
			if not entry.wanted and entry.used < age and not id.ends_with(":0:0:0"):
				oldest = id
				age = entry.used
		if oldest != "":
			for node in chunks[oldest].nodes:
				retire.append(node)
			cache_bytes -= int(chunks[oldest].bytes)
			chunks.erase(oldest)
	while not retire.is_empty() and Time.get_ticks_usec() < deadline:
		var node: Node = retire.pop_back()
		node.free()

func _setup_traffic() -> void:
	traffic_image = Image.create(256, maxi(2, ceili(float(traffic_slots.size()) / 256.0) * 2), false, Image.FORMAT_RGBA8)
	traffic_image.fill(Color("647687"))
	traffic_texture = ImageTexture.create_from_image(traffic_image)
	previous_texture = traffic_texture
	traffic_cursor = 0
	traffic_pending = false
	traffic_next = 0

func _update_traffic(deadline: int) -> void:
	var now := Time.get_ticks_msec()
	if traffic_image == null or not map.show_traffic_overlay:
		return
	var stamp: String = "%d:%d:%d:%f:%f:%d:%d:%d:%f:%d" % [map.road_traffic_mode, map.selected_hour, map.recorded_bin, map.hour_fraction, map.day_road_fraction, map.road_history_current_hour, map.live_traffic_state.unix_seconds if map.live_traffic_state != null else 0, map.current_day_road_summary.size(), map.road_history_fraction, traffic_revision]
	if not traffic_pending:
		if now < traffic_next or stamp == traffic_signature:
			return
		traffic_signature = stamp
		traffic_pending = true
		traffic_cursor = 0
	var road_count: int = map.region.road_links.size()
	while traffic_cursor < road_count and Time.get_ticks_usec() < deadline:
		var link = map.region.road_links[traffic_cursor]
		var slot: int = traffic_slots.get(link.id, -1)
		if slot >= 0:
			var load: Vector3 = map._road_load_ratio(traffic_cursor, link)
			for direction in range(2):
				traffic_image.set_pixel(slot % 256, (slot / 256) * 2 + direction, map._congestion_color(load[direction]) if load.z > 0.0 else Color("647687"))
		traffic_cursor += 1
	while traffic_cursor >= road_count and traffic_cursor < road_count + source.local_slots.size() and Time.get_ticks_usec() < deadline:
		var address: Vector2i = source.local_slots[traffic_cursor - road_count]
		var slot: int = traffic_slots[address]
		var color := Color("89978e")
		if map.live_traffic_state != null:
			var record: Dictionary = map.live_traffic_state.local_districts.get(address.x, {})
			if not record.is_empty() and address.y < record.queues.size():
				var rate: Vector2 = LocalTraffic.edge_rate(record, address.y)
				var queue: Vector2 = record.queues[address.y]
				color = map._congestion_color(maxf(rate.x, rate.y) / record.capacity + (queue.x + queue.y) / 100.0).lerp(Color("84928b"), 0.5)
		for direction in range(2):
			traffic_image.set_pixel(slot % 256, (slot / 256) * 2 + direction, color)
		traffic_cursor += 1
	if traffic_cursor == road_count + source.local_slots.size():
		var reusable := previous_texture
		previous_texture = traffic_texture
		if reusable == previous_texture:
			traffic_texture = ImageTexture.create_from_image(traffic_image)
		else:
			traffic_texture = reusable
			traffic_texture.update(traffic_image)
		traffic_published = now
		traffic_next = now + 67
		traffic_pending = false

func _update_materials(ppk: float) -> void:
	fill_material.set_shader_parameter("pixels_per_km", ppk)
	fill_material.set_shader_parameter("zoning", map.map_mode == "Zoning")
	var mix_value: float = clampf(float(Time.get_ticks_msec() - traffic_published) / 67.0, 0.0, 1.0)
	for material in current_materials:
		material.set_shader_parameter("pixels_per_km", ppk)
		material.set_shader_parameter("traffic_enabled", map.show_traffic_overlay)
		material.set_shader_parameter("trips", map.map_mode == "Trips")
		material.set_shader_parameter("traffic_previous", previous_texture)
		material.set_shader_parameter("traffic_current", traffic_texture)
		material.set_shader_parameter("traffic_mix", mix_value)
		material.set_shader_parameter("traffic_height", traffic_image.get_height())
		material.set_shader_parameter("selected_slot", traffic_slots.get(map.selected_local_street if map.selected_local_street.x >= 0 else map.selected_road_link_id, -1))

func is_settled() -> bool:
	return not source.is_empty() and source.epoch == epoch and snapshot.is_empty() and workers.is_empty() and uploads.is_empty() and requests.is_empty()
