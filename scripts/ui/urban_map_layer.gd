extends RefCounted

const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const LocalTraffic = preload("res://scripts/simulation/local_street_traffic.gd")
const Style = preload("res://scripts/ui/map_style.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const NeighborhoodSpatialIndex = preload("res://scripts/simulation/neighborhood_spatial_index.gd")
const ZoneColors = {"Residential": Color("929d89"), "Commercial": Color("b9a17a"), "Office": Color("8caaaf"), "Mixed": Color("b2ab8c"), "Industry": Color("8d8f9e")}
const BUILDING_BUDGET_US = 4000
const BUILDING_DETAIL_PPM = 0.2
const BUILDING_UPDATE_INTERVAL_S = 0.08
const BLOCKS_PER_MESH = 8

var building_cache: Dictionary = {}
var clearance_cache: Dictionary = {}
var chunk_bounds_cache: Dictionary = {}
var chunk_mesh_cache: Dictionary = {}
var last_street_count: int = 0
var last_building_count: int = 0
var last_block_draw_us: int = 0
var last_street_draw_us: int = 0
var building_update_scheduled := false
var footprint_cache: Dictionary = {}


func hit_street(map, point: Vector2) -> Vector2i:
	if Style.visibility(map._pixels_per_meter() * 1000.0, Style.road_range(Style.RoadStyle.LOCAL)) <= 0.05:
		return Vector2i(-1, -1)
	var world: Vector2 = map._screen_to_world(point)
	var best := Vector2i(-1, -1)
	var best_distance := 5.0
	for neighborhood_id in NeighborhoodSpatialIndex.in_bounds(map.region, Rect2(world, Vector2.ZERO)):
		var neighborhood = map.region.neighborhoods[neighborhood_id]
		var layout = neighborhood.street_layout
		if layout == null or not layout.bounds.has_point(world):
			continue
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.LOCAL or layout.phases[edge_id] > neighborhood.development_plan.completed_phase or layout.closed_edges.has(edge_id):
				continue
			if layout.edge_paths.has(edge_id):
				var path: PackedVector2Array = _screen_edge_path(map, layout, edge_id)
				for segment in range(1, path.size()):
					var distance: float = point.distance_to(Geometry2D.get_closest_point_to_segment(point, path[segment - 1], path[segment]))
					if distance < best_distance:
						best = Vector2i(neighborhood.id, edge_id)
						best_distance = distance
			else:
				var edge: Vector2 = layout.edges[edge_id]
				var first: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)])
				var last: Vector2 = map._world_to_screen(layout.nodes[int(edge.y)])
				var distance: float = point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last))
				if distance < best_distance:
					best = Vector2i(neighborhood.id, edge_id)
					best_distance = distance
	return best


func draw(map, pen) -> void:
	last_street_count = 0
	last_building_count = 0
	last_block_draw_us = 0
	last_street_draw_us = 0
	var meters: float = map._pixels_per_meter()
	if meters < 0.003:
		return
	var viewport: Rect2 = map.view_rect()
	var first_world: Vector2 = map._screen_to_world(viewport.position)
	var last_world: Vector2 = map._screen_to_world(viewport.end)
	var world_viewport := Rect2(first_world.min(last_world), (last_world - first_world).abs())
	var building_deadline_us: int = Time.get_ticks_usec() + BUILDING_BUDGET_US
	var pending_buildings := false
	var casing_lines := PackedVector2Array()
	var street_lines := PackedVector2Array()
	var street_colors := PackedColorArray()
	var dashed_streets := PackedVector2Array()
	var street_width: float = maxf(0.65, meters * 7.0)
	var casing_width: float = street_width + maxf(0.4, meters * 2.0)
	for neighborhood_id in NeighborhoodSpatialIndex.in_bounds(map.region, world_viewport):
		var neighborhood = map.region.neighborhoods[neighborhood_id]
		var layout = neighborhood.street_layout
		var plan = neighborhood.development_plan
		if layout == null or plan == null:
			continue
		var screen_bounds := Rect2(map._world_to_screen(layout.bounds.position), layout.bounds.size * map._map_scale() * map.view_zoom)
		if not screen_bounds.intersects(viewport):
			continue
		if map.map_mode != "Zoning":
			pending_buildings = _draw_footprint(map, pen, neighborhood, building_deadline_us) or pending_buildings
		if meters < 0.025:
			continue
		if meters >= BUILDING_DETAIL_PPM:
			var block_started: int = Time.get_ticks_usec()
			pending_buildings = _draw_blocks(map, pen, neighborhood, viewport, meters, building_deadline_us) or pending_buildings
			last_block_draw_us += Time.get_ticks_usec() - block_started
		var record: Dictionary = {}
		if map.live_traffic_state != null:
			record = map.live_traffic_state.local_districts.get(neighborhood.id, {})
		var street_started: int = Time.get_ticks_usec()
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] == Roads.ARTERIAL or layout.closed_edges.has(edge_id):
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var first: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)])
			var last: Vector2 = map._world_to_screen(layout.nodes[int(edge.y)])
			var curved: bool = layout.edge_paths.has(edge_id)
			if not Rect2(first, Vector2.ZERO).expand(last).grow(maxf(6.0, meters * 30.0) if curved else 6.0).intersects(viewport):
				continue
			var path: PackedVector2Array = _screen_edge_path(map, layout, edge_id) if curved else PackedVector2Array()
			var built: bool = layout.phases[edge_id] <= plan.completed_phase
			if not built:
				if map.map_mode == "Zoning" or plan.constructing_phase == layout.phases[edge_id]:
					if curved:
						for segment in range(1, path.size()):
							pen.draw_dashed_line(path[segment - 1], path[segment], Color("c3ac78", 0.5), 1.0, 5.0, true)
					else:
						pen.draw_dashed_line(first, last, Color("c3ac78", 0.5), 1.0, 5.0, true)
				continue
			if layout.classes[edge_id] != Roads.LOCAL:
				continue
			var color := Color("fcfcf7")
			if not record.is_empty() and map.show_traffic_overlay:
				var rate: Vector2 = LocalTraffic.edge_rate(record, edge_id)
				var queue: Vector2 = record["queues"][edge_id]
				color = map._congestion_color(maxf(rate.x, rate.y) / record["capacity"] + (queue.x + queue.y) / 100.0).lerp(Color("84928b"), 0.5)
			if map.selected_local_street == Vector2i(neighborhood.id, edge_id):
				color = Color("f7e4a0")
			if curved:
				for segment in range(1, path.size()):
					casing_lines.append(path[segment - 1])
					casing_lines.append(path[segment])
					street_lines.append(path[segment - 1])
					street_lines.append(path[segment])
					street_colors.append(color)
			else:
				casing_lines.append(first)
				casing_lines.append(last)
				street_lines.append(first)
				street_lines.append(last)
				street_colors.append(color)
			last_street_count += 1
			if meters >= 0.5:
				if curved:
					for segment in range(1, path.size()):
						dashed_streets.append(path[segment - 1])
						dashed_streets.append(path[segment])
				else:
					dashed_streets.append(first)
					dashed_streets.append(last)
		last_street_draw_us += Time.get_ticks_usec() - street_started
	if not casing_lines.is_empty():
		var batch_started: int = Time.get_ticks_usec()
		pen.draw_multiline(casing_lines, Color("c4ced0"), casing_width, true)
		pen.draw_multiline_colors(street_lines, street_colors, street_width, true)
		for index in range(0, dashed_streets.size(), 2):
			pen.draw_dashed_line(dashed_streets[index], dashed_streets[index + 1], Color("b5baa1", 0.5), maxf(0.6, meters * 0.12), meters * 3.0, true)
		last_street_draw_us += Time.get_ticks_usec() - batch_started
	if map.selected_candidate_id >= 0 and map.map_mode == "Zoning":
		var candidate: Dictionary = map.region.development_candidates[map.selected_candidate_id]
		if int(candidate["neighborhood_id"]) < 0 and candidate.has("layout"):
			var layout = candidate["layout"]
			for edge_id in range(layout.edges.size()):
				if layout.classes[edge_id] == Roads.ARTERIAL:
					continue
				var edge: Vector2 = layout.edges[edge_id]
				var first: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)])
				var last: Vector2 = map._world_to_screen(layout.nodes[int(edge.y)])
				var curved: bool = layout.edge_paths.has(edge_id)
				if Rect2(first, Vector2.ZERO).expand(last).grow(meters * 30.0 if curved else 0.0).intersects(viewport):
					if curved:
						var path: PackedVector2Array = _screen_edge_path(map, layout, edge_id)
						for segment in range(1, path.size()):
							pen.draw_dashed_line(path[segment - 1], path[segment], Color("dbc38a", 0.65), 1.3, 5.0, true)
					else:
						pen.draw_dashed_line(first, last, Color("dbc38a", 0.65), 1.3, 5.0, true)
	if pending_buildings and not building_update_scheduled:
		building_update_scheduled = true
		map.get_tree().create_timer(BUILDING_UPDATE_INTERVAL_S).timeout.connect(func() -> void:
			building_update_scheduled = false
			if is_instance_valid(map):
				map.refresh_static()
		, CONNECT_ONE_SHOT)


func _screen_edge_path(map, layout, edge_id: int) -> PackedVector2Array:
	var path: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array())
	if path.is_empty():
		var edge: Vector2 = layout.edges[edge_id]
		return PackedVector2Array([map._world_to_screen(layout.nodes[int(edge.x)]), map._world_to_screen(layout.nodes[int(edge.y)])])
	var screen := PackedVector2Array()
	for point in path:
		screen.append(map._world_to_screen(point))
	return screen


func _draw_footprint(map, pen, neighborhood, deadline: int) -> bool:
	if neighborhood.built_fraction <= 0.01:
		return false
	var layout = neighborhood.street_layout
	var phase: int = neighborhood.development_plan.completed_phase
	var key: String = "%d:%d:%d" % [layout.get_instance_id(), phase, map.region.road_geometry_revision]
	if not footprint_cache.has(key):
		if Time.get_ticks_usec() > deadline:
			return true
		if footprint_cache.size() > 1024:
			footprint_cache.clear()
		var vertices := PackedVector2Array()
		var colors := PackedColorArray()
		for block in layout.blocks:
			if int(block["phase"]) > phase or block.get("demolished", false):
				continue
			var polygon: PackedVector2Array = block["polygon"]
			var indices: PackedInt32Array = Geometry2D.triangulate_polygon(polygon)
			var color := Color("bee5c9") if block["park"] else Color("f1f2ef")
			for index in indices:
				vertices.append(polygon[index] - layout.bounds.position)
				colors.append(color)
		var mesh: ArrayMesh = null
		if not vertices.is_empty():
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_COLOR] = colors
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		footprint_cache[key] = mesh
	if footprint_cache[key] != null:
		var scale: float = map._map_scale() * map.view_zoom
		var transform := Transform2D(Vector2(scale, 0.0), Vector2(0.0, scale), map._world_to_screen(layout.bounds.position))
		pen.draw_mesh(footprint_cache[key], null, transform)
	return false


func _draw_blocks(map, pen, neighborhood, viewport: Rect2, meters: float, building_deadline_us: int) -> bool:
	var layout = neighborhood.street_layout
	var plan = neighborhood.development_plan
	var pending := false
	var generated := false
	var clearance_key: String = "%d:%d:%d" % [layout.get_instance_id(), map.region.road_geometry_revision, map.region.road_reservations.size()]
	if not clearance_cache.has(clearance_key):
		if clearance_cache.size() > 1024:
			clearance_cache.clear()
		clearance_cache[clearance_key] = RoadLand.masks_for_bounds(map.region, layout.bounds)
	var reserved_masks: Array[PackedVector2Array] = clearance_cache[clearance_key]
	var chunk_bounds: Array[Rect2] = _chunk_bounds(layout)
	var scale: float = map._map_scale() * map.view_zoom
	var origin: Vector2 = map._world_to_screen(layout.bounds.position)
	var transform := Transform2D(Vector2(scale, 0.0), Vector2(0.0, scale), origin)
	var shadow_transform := Transform2D(Vector2(scale, 0.0), Vector2(0.0, scale), origin + Vector2(1.0, 1.5) * minf(3.0, meters * 2.0))
	for chunk_id in range(chunk_bounds.size()):
		var screen_bounds := Rect2(map._world_to_screen(chunk_bounds[chunk_id].position), chunk_bounds[chunk_id].size * scale)
		if not screen_bounds.intersects(viewport):
			continue
		var first: int = chunk_id * BLOCKS_PER_MESH
		var finish: int = mini(first + BLOCKS_PER_MESH, layout.blocks.size())
		var zoning_signature: int = hash(neighborhood.block_zoning.slice(first, finish))
		var redevelopment_epoch := 0
		for block_id in range(first, finish):
			if int(layout.blocks[block_id].get("redevelopment_day", -1)) >= 0:
				redevelopment_epoch = map.region.current_day_key
				break
		var mesh_key: String = "%s:%d:%d:%d:%d:%d:%s:%d" % [clearance_key, chunk_id, zoning_signature, floori(neighborhood.built_fraction * 1000.0), plan.completed_phase, redevelopment_epoch, neighborhood.character_profile, int(map.map_mode == "Zoning")]
		if not chunk_mesh_cache.has(mesh_key):
			if generated and Time.get_ticks_usec() >= building_deadline_us:
				pending = true
				continue
			if chunk_mesh_cache.size() > 512:
				for old_key in chunk_mesh_cache.keys().slice(0, 128):
					chunk_mesh_cache.erase(old_key)
			chunk_mesh_cache[mesh_key] = _build_chunk_mesh(map, neighborhood, first, finish, clearance_key, reserved_masks)
			generated = true
		var cached: Dictionary = chunk_mesh_cache[mesh_key]
		if cached["mesh"] == null:
			continue
		if meters >= 0.3:
			pen.draw_mesh(cached["mesh"], null, shadow_transform, Color("14252a", 0.7))
		pen.draw_mesh(cached["mesh"], null, transform)
		last_building_count += int(cached["count"])
	return pending


func _chunk_bounds(layout) -> Array[Rect2]:
	var layout_id: int = layout.get_instance_id()
	if chunk_bounds_cache.has(layout_id):
		return chunk_bounds_cache[layout_id]
	if chunk_bounds_cache.size() > 1024:
		chunk_bounds_cache.clear()
	var chunks: Array[Rect2] = []
	for first in range(0, layout.blocks.size(), BLOCKS_PER_MESH):
		var polygon: PackedVector2Array = layout.blocks[first]["polygon"]
		var bounds := Rect2(polygon[0], Vector2.ZERO)
		for block_id in range(first, mini(first + BLOCKS_PER_MESH, layout.blocks.size())):
			for point in layout.blocks[block_id]["polygon"]:
				bounds = bounds.expand(point)
		chunks.append(bounds)
	chunk_bounds_cache[layout_id] = chunks
	return chunks


func _build_chunk_mesh(map, neighborhood, first: int, finish: int, clearance_key: String, reserved_masks: Array[PackedVector2Array]) -> Dictionary:
	var layout = neighborhood.street_layout
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var count := 0
	for block_id in range(first, finish):
		var block: Dictionary = layout.blocks[block_id]
		if block.get("demolished", false) or int(block["phase"]) > neighborhood.development_plan.completed_phase:
			continue
		if block["park"]:
			var park: PackedVector2Array = block["polygon"]
			for vertex_id in Geometry2D.triangulate_polygon(park):
				vertices.append(park[vertex_id] - layout.bounds.position)
				colors.append(Color("3a5745"))
			continue
		if block_id >= neighborhood.block_zoning.size() or neighborhood.block_zoning[block_id] == 0:
			continue
		var code: int = neighborhood.block_zoning[block_id] - 1
		var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][floori(float(code) / 3.0)]
		var density: int = code % 3
		var key: String = "%s:%d:%s:%d:%s" % [clearance_key, block_id, zone, density, neighborhood.character_profile]
		if not building_cache.has(key):
			if building_cache.size() > 8192:
				for old_key in building_cache.keys().slice(0, 1024):
					building_cache.erase(old_key)
			var generated_footprints: Array = ParcelGeometry.buildings(block, zone, density, neighborhood.character_profile, map.region.terrain)
			var generated_visible := PackedByteArray()
			for footprint in generated_footprints:
				generated_visible.append(0 if RoadLand.polygon_intersects_masks(footprint, reserved_masks) else 1)
			building_cache[key] = {"footprints": generated_footprints, "visible": generated_visible}
		var cached: Dictionary = building_cache[key]
		var footprints: Array = cached["footprints"]
		var visible: PackedByteArray = cached["visible"]
		var redevelopment_day: int = int(block.get("redevelopment_day", -1))
		var developed: float = neighborhood.built_fraction if redevelopment_day < 0 else minf(neighborhood.built_fraction, clampf(float(map.region.current_day_key - redevelopment_day) / 180.0, 0.0, 1.0))
		for building_id in range(footprints.size()):
			if visible[building_id] == 0 or float(posmod(int(block["seed"]) + building_id * 7919, 1000)) / 1000.0 > developed:
				continue
			var footprint: PackedVector2Array = footprints[building_id]
			for vertex_id in Geometry2D.triangulate_polygon(footprint):
				vertices.append(footprint[vertex_id] - layout.bounds.position)
				colors.append(_building_color(neighborhood, zone, building_id, map.map_mode == "Zoning"))
			count += 1
	if vertices.is_empty():
		return {"mesh": null, "count": 0}
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "count": count}


static func _building_color(neighborhood, zone: String, building_id: int, zoning_mode: bool) -> Color:
	var base: Color = ZoneColors[zone]
	if zoning_mode:
		return base
	var tints := {"Fine Grain": Color("b8aa91"), "Courtyard": Color("a4afb1"), "Garden": Color("9eb29a"), "Large Plot": Color("aaa9a4")}
	var target: Color = tints.get(neighborhood.character_profile, base)
	var city_shift: float = float(posmod(neighborhood.city_id * 23, 17)) / 100.0
	var variation: float = float(posmod(building_id * 37, 13)) / 100.0
	return base.lerp(target, 0.18 + city_shift + variation)
