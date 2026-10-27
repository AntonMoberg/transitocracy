extends Control

const MapStyle = preload("res://scripts/ui/map_style.gd")

signal neighborhood_selected(neighborhood_id: int)
signal candidate_selected(candidate_id: int)
signal local_street_selected(neighborhood_id: int, edge_id: int)
signal road_node_clicked(node_id: int)
signal road_link_clicked(link_id: int, world_position: Vector2)
signal road_empty_clicked(world_position: Vector2)
signal road_empty_double_clicked(world_position: Vector2)
signal road_cancel_requested
signal jurisdiction_selected(jurisdiction_id: int)

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const ChunkRenderer = preload("res://scripts/ui/map_chunk_renderer.gd")
const TerrainLayer = preload("res://scripts/ui/map_terrain_layer.gd")
const UrbanMapLayer = preload("res://scripts/ui/urban_map_layer.gd")
const TerrainDetailTile = preload("res://scripts/ui/terrain_detail_tile.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const StreetLayoutOps = preload("res://scripts/simulation/street_layout_ops.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const WORLD_CENTER = Vector2(120.0, 80.0)
const WORLD_SIZE = Vector2(240.0, 160.0)
const MIN_VISIBLE_SOCIAL_TRIPS = 0.05
const SPATIAL_GRID_SIZE = 32
const MAX_ZOOM = 131072.0
const MAX_PIXELS_PER_KM = 10000.0
const TRACKPAD_PAN_PIXELS = 32.0
const ROAD_LIVE = 0
const ROAD_HOUR = 1
const ROAD_DAY = 2
const ROAD_HISTORY = 3
const CITY_COLORS = [
	Color("4b8fbf"),
	Color("9872c5"),
	Color("bc8d50"),
	Color("58a897"),
	Color("c47789"),
	Color("7eaa68"),
	Color("ba82ac"),
	Color("70a4ba"),
]
const TERRAIN_DETAIL_STEPS = [2.0, 1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625, 0.0078125, 0.00390625, 0.001953125, 0.0009765625, 0.00048828125]
const TERRAIN_DETAIL_CACHE_LIMIT = 160
const TERRAIN_DETAIL_MAX_WORKERS = 2

var region
var urban_layer = UrbanMapLayer.new()
var street_labels = preload("res://scripts/ui/street_labels.gd").new()
var flow_profile
var next_day_profile
var traffic_profile
var map_mode: String = "Roads"
var detail_level: String = "Neighborhood"
var road_tool: String = "Inspect"
var road_draw_mode: String = RoadRouteBuilder.STRAIGHT
var road_snap_enabled: bool = false
var road_length_snap_enabled: bool = false
var selected_road_link_id: int = -1
var selected_local_street := Vector2i(-1, -1)
var preview_start_node: int = -1
var preview_start_position: Vector2 = Vector2.INF
var planning_preview_start: Vector2 = Vector2.INF
var planning_preview_kind: String = ""
var preview_waypoints: PackedVector2Array = PackedVector2Array()
var preview_frozen_route: PackedVector2Array = PackedVector2Array()
var road_preview: Dictionary = {}
var hover_world_position: Vector2 = Vector2.ZERO
var selected_hour: int = 8
var hour_fraction: float = 0.0
var recorded_bin: int = 0
var first_recorded_bin: int = 0
# Coarse mode blends completed traffic hours; it never presents an uncomputed hour.
var road_history_previous_hour: int = -1
var road_history_current_hour: int = -1
var road_history_fraction: float = 1.0
var road_traffic_mode: int = ROAD_LIVE
var live_traffic_state
var hour_carry_summary: Dictionary = {}
var previous_day_road_summary: Dictionary = {}
var current_day_road_summary: Dictionary = {}
var day_road_fraction: float = 0.0
var selected_purpose: String = FlowProfile.ALL
var selected_id: int = -1
var selected_candidate_id: int = -1
var selected_jurisdiction_id: int = -1
var hovered_id: int = -1
var aggregate_cache_region
var aggregate_cache_level: String = ""
var aggregate_neighborhood_groups: PackedInt32Array = PackedInt32Array()
var aggregate_node_groups: PackedInt32Array = PackedInt32Array()
var aggregate_flow_cache: Dictionary = {}
var zoom: float = 1.0:
	set(value):
		zoom = value
		view_zoom = value
var pan: Vector2 = Vector2.ZERO:
	set(value):
		pan = value
		view_pan = value
# Bake-view state: static content is recorded once per zoom band at (bake_pan,
# bake_zoom) covering an extended viewport; pans and zooms between rebakes only
# move that canvas item via a transform.
const ZOOM_BAND_RATIO := 1.5
const BAKE_MARGIN_PX := 256.0
var view_pan: Vector2 = Vector2.ZERO
var view_zoom: float = 1.0
var view_origin: Vector2 = Vector2.ZERO
var view_size: Vector2 = Vector2.ZERO
var bake_pan: Vector2 = Vector2.ZERO
var bake_zoom: float = 1.0
var bake_key: String = ""
var pending_bake_key: String = ""
var pending_bake_pan: Vector2 = Vector2.ZERO
var pending_bake_zoom: float = 1.0
var static_bake_queued := false
var static_bake_count := 0
var chunk_renderer
var terrain_layer
var terrain_view_key := ""
var overlays_dirty := true
var last_overlay_refresh_msec := 0
var static_layer: Control
var dynamic_overlay: Control
var last_overlay_us: int = 0
var crossing_marks: Array = []
var crossing_marks_revision: int = -1
var pointer_down: bool = false
var pointer_dragged: bool = false
var pointer_double_clicked: bool = false
var pointer_start: Vector2 = Vector2.ZERO
var last_frame_process_us: int = 0
var last_draw_us: int = 0
var last_draw_stages_us: Dictionary = {}
var spatial_region
var spatial_seed: int = -1
var spatial_geometry_revision: int = -1
var spatial_neighborhood_count: int = -1
var spatial_link_count: int = -1
var spatial_node_count: int = -1
var spatial_origin: Vector2 = Vector2.ZERO
var spatial_cell_size: Vector2 = Vector2.ONE
var spatial_neighborhoods: Dictionary = {}
var spatial_road_nodes: Dictionary = {}
var spatial_road_links: Dictionary = {}
var spatial_strategic_links: Array[int] = []
var spatial_local_road_km: float = 0.0
var road_arrow_mesh: ArrayMesh
var neighborhood_batches: Array[MultiMesh] = []
var district_fill_meshes: Dictionary = {}
var jurisdiction_layout_key: String = ""
var jurisdiction_label_rects: Dictionary = {}
var last_drawn_neighborhood_borders: int = 0
var terrain_base_textures: Dictionary = {}
var terrain_texture: ImageTexture
var terrain_relief_texture: ImageTexture
var terrain_slope_texture: ImageTexture
var terrain_contour_texture: ImageTexture
var terrain_texture_source = null
var show_terrain_overlay := false
var show_slope_overlay := false
var show_contours := false
var show_traffic_overlay := false
var show_transit_overlay := false
var terrain_toggle_button: Button
var slope_toggle_button: Button
var contour_toggle_button: Button
var traffic_toggle_button: Button
var transit_toggle_button: Button
var terrain_detail_tiles: Dictionary = {}
var terrain_detail_queue: Array[Vector3i] = []
var terrain_detail_requested: Dictionary = {}
var terrain_detail_visible: Dictionary = {}
var terrain_detail_level := -1
var terrain_detail_published_level := -1
var terrain_uploads: Array[Dictionary] = []
var terrain_base_pending := false
var terrain_detail_workers: Array[Dictionary] = []
var terrain_detail_active: Dictionary = {}


func _ready() -> void:
	set_process(true)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(480, 320)
	resized.connect(refresh_static)
	view_pan = pan
	view_zoom = zoom
	view_origin = Vector2.ZERO
	view_size = size
	# Terrain and world geometry retain GPU resources across camera changes.
	# Planning overlays and interactive labels sit below navigation controls.
	terrain_layer = TerrainLayer.new()
	terrain_layer.map = self
	terrain_layer.z_index = 1
	add_child(terrain_layer)
	move_child(terrain_layer, 0)
	chunk_renderer = ChunkRenderer.new()
	chunk_renderer.map = self
	chunk_renderer.z_index = 30
	add_child(chunk_renderer)
	move_child(chunk_renderer, 1)
	static_layer = MapStaticLayer.new()
	static_layer.map = self
	static_layer.z_index = 100
	static_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	static_layer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(static_layer)
	move_child(static_layer, 2)
	dynamic_overlay = MapOverlay.new()
	dynamic_overlay.map = self
	dynamic_overlay.z_index = 101
	dynamic_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	dynamic_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dynamic_overlay)
	move_child(dynamic_overlay, 3)
	var navigation := HBoxContainer.new()
	navigation.name = "MapNavigation"
	navigation.z_index = 200
	navigation.position = Vector2(12, 10)
	navigation.add_theme_constant_override("separation", 4)
	add_child(navigation)
	for label in ["−", "+", "Fit"]:
		var button := Button.new()
		button.text = label
		button.custom_minimum_size = Vector2(32, 28)
		button.focus_mode = Control.FOCUS_NONE
		if label == "Fit":
			button.tooltip_text = "Show the whole state"
			button.pressed.connect(reset_view)
		else:
			var factor: float = 1.6 if label == "+" else 0.625
			button.tooltip_text = "Zoom in" if label == "+" else "Zoom out"
			button.pressed.connect(func() -> void: _zoom_at(size * 0.5, factor))
		navigation.add_child(button)
	var layers := HBoxContainer.new()
	layers.name = "MapLayers"
	layers.z_index = 200
	layers.position = Vector2(12, 44)
	layers.add_theme_constant_override("separation", 4)
	add_child(layers)
	terrain_toggle_button = Button.new()
	terrain_toggle_button.text = "Terrain"
	terrain_toggle_button.tooltip_text = "Show shaded terrain relief over the map colors"
	terrain_toggle_button.toggle_mode = true
	terrain_toggle_button.focus_mode = Control.FOCUS_NONE
	terrain_toggle_button.toggled.connect(func(enabled: bool) -> void:
		show_terrain_overlay = enabled
		refresh_static()
	)
	layers.add_child(terrain_toggle_button)
	slope_toggle_button = Button.new()
	slope_toggle_button.text = "Slope"
	slope_toggle_button.tooltip_text = "Show steep land that limits development"
	slope_toggle_button.toggle_mode = true
	slope_toggle_button.focus_mode = Control.FOCUS_NONE
	slope_toggle_button.toggled.connect(func(enabled: bool) -> void:
		show_slope_overlay = enabled
		refresh_static()
	)
	layers.add_child(slope_toggle_button)
	contour_toggle_button = Button.new()
	contour_toggle_button.text = "Contours"
	contour_toggle_button.tooltip_text = "Show faint terrain elevation lines"
	contour_toggle_button.toggle_mode = true
	contour_toggle_button.focus_mode = Control.FOCUS_NONE
	contour_toggle_button.toggled.connect(func(enabled: bool) -> void:
		show_contours = enabled
		refresh_static()
	)
	layers.add_child(contour_toggle_button)
	traffic_toggle_button = Button.new()
	traffic_toggle_button.text = "Traffic"
	traffic_toggle_button.tooltip_text = "Color roads by traffic flow and congestion"
	traffic_toggle_button.toggle_mode = true
	traffic_toggle_button.button_pressed = show_traffic_overlay
	traffic_toggle_button.focus_mode = Control.FOCUS_NONE
	traffic_toggle_button.toggled.connect(func(enabled: bool) -> void:
		show_traffic_overlay = enabled
		refresh_static()
	)
	layers.add_child(traffic_toggle_button)
	transit_toggle_button = Button.new()
	transit_toggle_button.text = "Transit"
	transit_toggle_button.tooltip_text = "Show planned rail corridors and station sites"
	transit_toggle_button.toggle_mode = true
	transit_toggle_button.focus_mode = Control.FOCUS_NONE
	transit_toggle_button.toggled.connect(func(enabled: bool) -> void:
		show_transit_overlay = enabled
		refresh_static()
	)
	layers.add_child(transit_toggle_button)


func set_region(new_region) -> void:
	region = new_region
	if new_region == null or new_region.terrain != terrain_texture_source:
		terrain_detail_tiles.clear()
		terrain_detail_queue.clear()
		terrain_detail_requested.clear()
		terrain_detail_visible.clear()
		terrain_detail_active.clear()
		terrain_detail_level = -1
		terrain_detail_published_level = -1
		terrain_texture_source = new_region.terrain if new_region != null else null
		terrain_base_textures.clear()
		terrain_texture = null
		terrain_base_pending = new_region != null
		terrain_uploads.clear()
		if new_region == null:
			terrain_relief_texture = null
			terrain_slope_texture = null
			terrain_contour_texture = null
	district_fill_meshes.clear()
	spatial_region = null
	road_history_previous_hour = -1
	road_history_current_hour = -1
	hour_carry_summary = {}
	previous_day_road_summary = {}
	current_day_road_summary = {}
	live_traffic_state = null
	if new_region != null:
		call_deferred("_ensure_spatial_index")
	selected_id = -1
	selected_candidate_id = -1
	selected_road_link_id = -1
	preview_start_node = -1
	preview_start_position = Vector2.INF
	preview_waypoints.clear()
	preview_frozen_route.clear()
	road_preview.clear()
	hovered_id = -1
	zoom = 1.0
	pan = Vector2.ZERO
	refresh_static()


func _exit_tree() -> void:
	for worker in terrain_detail_workers:
		worker["thread"].wait_to_finish()
	terrain_detail_workers.clear()


func _process(_delta: float) -> void:
	var process_started := Time.get_ticks_usec()
	_sync_view()
	view_origin = Vector2.ZERO
	view_size = size
	if region != null:
		chunk_renderer.tick()
		urban_layer.last_building_count = chunk_renderer.visible_buildings
		urban_layer.last_street_count = chunk_renderer.visible_streets
		last_drawn_neighborhood_borders = chunk_renderer.visible_districts
		_apply_static_transform()
		var camera_key := "%s:%s:%s:%s:%s:%s" % [pan, zoom, size, show_terrain_overlay, show_slope_overlay, show_contours]
		if camera_key != terrain_view_key:
			terrain_view_key = camera_key
			_static_update()
			_draw_terrain_detail(null)
			refresh_dynamic()
		terrain_layer.sync()
		if overlays_dirty or Time.get_ticks_msec() - last_overlay_refresh_msec >= 67 and map_mode == "Trips":
			overlays_dirty = true
			_static_update()
			overlays_dirty = false
			last_overlay_refresh_msec = Time.get_ticks_msec()
	var completed := false
	var publish_deadline: int = Time.get_ticks_usec() + maxi(0, 1000 - chunk_renderer.last_publish_us)
	for worker_index in range(terrain_detail_workers.size() - 1, -1, -1):
		var worker: Dictionary = terrain_detail_workers[worker_index]
		var thread: Thread = worker.thread
		if thread.is_alive():
			continue
		var result: Dictionary = thread.wait_to_finish()
		terrain_detail_workers.remove_at(worker_index)
		if worker.source != terrain_texture_source:
			continue
		var key: Vector3i = worker.key
		if result.is_empty():
			terrain_detail_active.erase(key)
			continue
		var names: Array[String] = []
		for name in ["color", "terrain", "slope", "contours", "map_field"]:
			if result.has(name): names.append(name)
		names.append("map_mesh")
		terrain_uploads.append({"key": key, "images": result, "textures": {}, "part": 0, "names": names})
	while not terrain_uploads.is_empty() and Time.get_ticks_usec() < publish_deadline:
		var upload: Dictionary = terrain_uploads[0]
		var names: Array = upload.names
		var name: String = names[upload.part]
		if name == "map_mesh":
			upload.textures[name] = _cartographic_mesh(upload.images)
		else:
			upload.textures[name] = ImageTexture.create_from_image(upload.images[name])
			upload.images.erase(name)
		upload.part += 1
		if upload.part < names.size():
			continue
		var key: Vector3i = upload.key
		if key.x < 0:
			terrain_base_textures = upload.textures
			terrain_texture = upload.textures.color
			terrain_relief_texture = upload.textures.terrain
			terrain_slope_texture = upload.textures.slope
			terrain_contour_texture = upload.textures.contours
			terrain_layer.refresh_base()
		else:
			terrain_detail_tiles[key] = upload.textures
		terrain_detail_active.erase(key)
		terrain_uploads.pop_front()
		completed = true
	if completed:
		_trim_terrain_detail_cache()
		_draw_terrain_detail(null)
		terrain_layer.sync()
	# Reserve capacity for interactive geometry; terrain refinement may not
	# occupy both workers while the camera is requesting roads and buildings.
	var worker_limit: int = maxi(0, mini(1, mini(TERRAIN_DETAIL_MAX_WORKERS, OS.get_processor_count() - 1) - chunk_renderer.workers.size()))
	if terrain_base_pending and terrain_detail_workers.size() < worker_limit:
		var base_thread := Thread.new()
		if base_thread.start(Callable(TerrainDetailTile, "render_base").bind(region.terrain, region.jurisdictions[0].polygon_km), Thread.PRIORITY_LOW) == OK:
			terrain_detail_workers.append({"thread": base_thread, "source": region.terrain, "key": Vector3i(-1, 0, 0)})
			terrain_base_pending = false
	while terrain_detail_workers.size() < worker_limit and not terrain_detail_queue.is_empty():
		var key: Vector3i = terrain_detail_queue.pop_front()
		terrain_detail_requested.erase(key)
		if terrain_texture_source == null or _terrain_tile_ready(key) or key.x != terrain_detail_level or not terrain_detail_visible.has(key):
			continue
		var terrain = terrain_texture_source
		var step_km: float = TERRAIN_DETAIL_STEPS[key.x]
		var tile_km: float = step_km * TerrainDetailTile.PIXELS
		var origin: Vector2 = terrain.bounds.position + Vector2(key.y, key.z) * tile_km
		var thread := Thread.new()
		terrain_detail_active[key] = true
		var land: PackedVector2Array = region.jurisdictions[0].polygon_km
		var error: Error = thread.start(Callable(TerrainDetailTile, "render").bind(terrain, land, origin, step_km, not _needs_terrain_raster()))
		if error == OK:
			terrain_detail_workers.append({"thread": thread, "source": terrain, "key": key})
			continue
		terrain_detail_active.erase(key)
		push_warning("Could not start terrain detail worker: %s" % error_string(error))

	last_frame_process_us = Time.get_ticks_usec() - process_started


func _cartographic_mesh(result: Dictionary) -> ArrayMesh:
	var vertices: PackedVector2Array = result.get("map_vertices", PackedVector2Array())
	if vertices.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = result["map_uvs"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _trim_terrain_detail_cache() -> void:
	if terrain_detail_tiles.size() <= TERRAIN_DETAIL_CACHE_LIMIT:
		return
	for key in terrain_detail_tiles.keys():
		if not terrain_detail_visible.has(key):
			terrain_detail_tiles.erase(key)
			if terrain_detail_tiles.size() <= TERRAIN_DETAIL_CACHE_LIMIT:
				return
	while terrain_detail_tiles.size() > TERRAIN_DETAIL_CACHE_LIMIT:
		terrain_detail_tiles.erase(terrain_detail_tiles.keys()[0])


func set_flow_profile(new_profile) -> void:
	flow_profile = new_profile
	aggregate_flow_cache.clear()
	refresh_static()


func set_next_day_profile(new_profile) -> void:
	next_day_profile = new_profile
	refresh_static()


func set_traffic_profile(new_profile) -> void:
	traffic_profile = new_profile
	if new_profile == null:
		road_history_previous_hour = -1
		road_history_current_hour = -1
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func set_map_mode(mode: String) -> void:
	map_mode = mode
	refresh_static()


func set_transit_overlay(enabled: bool) -> void:
	show_transit_overlay = enabled
	if transit_toggle_button != null:
		transit_toggle_button.set_pressed_no_signal(enabled)
	refresh_static()


func set_selected_candidate(candidate_id: int) -> void:
	selected_candidate_id = candidate_id
	refresh_static()


func set_detail_level(level: String) -> void:
	detail_level = level
	aggregate_cache_level = ""
	aggregate_flow_cache.clear()
	refresh_static()


func set_road_tool(tool_name: String) -> void:
	road_tool = tool_name
	refresh_dynamic()


func set_road_input_mode(mode: String, snap_enabled: bool, length_snap_enabled: bool = false) -> void:
	road_draw_mode = mode
	road_snap_enabled = snap_enabled
	road_length_snap_enabled = length_snap_enabled
	refresh_dynamic()


func set_road_preview(start_node: int, waypoints: PackedVector2Array, preview: Dictionary, start_position:Vector2=Vector2.INF) -> void:
	preview_start_node = start_node
	preview_start_position=start_position
	preview_waypoints = waypoints
	road_preview = preview
	preview_frozen_route = RoadPlanner.frozen_multi_curve(region, start_node, waypoints, road_tool) if region != null and start_node >= 0 and road_draw_mode == RoadRouteBuilder.MULTIPOINT else PackedVector2Array()
	refresh_dynamic()


func set_planning_preview(start_point: Vector2, kind: String = "") -> void:
	planning_preview_start = start_point
	planning_preview_kind = kind
	refresh_dynamic()


func set_selected_road_link(link_id: int) -> void:
	selected_road_link_id = link_id
	refresh_static()


func set_hour(hour: int) -> void:
	set_time(hour, 0.0)


func set_time(hour: int, fraction: float, request_redraw: bool = true) -> void:
	var next_hour: int = clampi(hour, 0, 23)
	var next_fraction: float = clampf(fraction, 0.0, 1.0)
	if selected_hour == next_hour and is_equal_approx(hour_fraction, next_fraction):
		return
	selected_hour = next_hour
	hour_fraction = next_fraction
	if request_redraw and (map_mode == "Trips" or show_traffic_overlay and road_traffic_mode == ROAD_HISTORY):
		refresh_dynamic()


func set_recorded_bin(bin_index: int, first_bin: int = 0) -> void:
	if recorded_bin == bin_index and first_recorded_bin == first_bin:
		return
	recorded_bin = bin_index
	first_recorded_bin = first_bin
	if show_traffic_overlay and road_traffic_mode == ROAD_HISTORY:
		refresh_dynamic()


func set_hourly_road_history(previous_hour: int, current_hour: int, fraction: float) -> void:
	var next_fraction: float = clampf(fraction, 0.0, 1.0)
	if road_history_previous_hour == previous_hour and road_history_current_hour == current_hour and is_equal_approx(road_history_fraction, next_fraction):
		return
	road_history_previous_hour = previous_hour
	road_history_current_hour = current_hour
	road_history_fraction = next_fraction
	if show_traffic_overlay and road_traffic_mode == ROAD_HOUR:
		refresh_dynamic()


func set_road_traffic_mode(mode: int, state) -> void:
	if road_traffic_mode == mode and live_traffic_state == state:
		return
	road_traffic_mode = mode
	live_traffic_state = state
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func set_hour_carry_summary(summary: Dictionary) -> void:
	hour_carry_summary = summary
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func set_current_day_road_summary(summary: Dictionary) -> void:
	current_day_road_summary = summary
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func promote_day_road_summary() -> void:
	previous_day_road_summary = current_day_road_summary
	current_day_road_summary = {}
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func clear_day_road_summaries() -> void:
	previous_day_road_summary = {}
	current_day_road_summary = {}
	if chunk_renderer != null:
		chunk_renderer.traffic_revision += 1
	refresh_dynamic()


func set_day_road_fraction(fraction: float) -> void:
	var next_fraction: float = clampf(fraction, 0.0, 1.0)
	if is_equal_approx(day_road_fraction, next_fraction):
		return
	day_road_fraction = next_fraction
	if show_traffic_overlay and road_traffic_mode == ROAD_DAY:
		refresh_dynamic()


func set_purpose(purpose: String) -> void:
	selected_purpose = purpose
	refresh_static()


func set_selected(neighborhood_id: int) -> void:
	selected_id = neighborhood_id
	if map_mode == "Trips":
		overlays_dirty = true
	refresh_dynamic()


func set_selected_jurisdiction(jurisdiction_id: int) -> void:
	selected_jurisdiction_id = jurisdiction_id
	refresh_static()


func _aggregate_kind() -> String:
	match detail_level:
		"State":
			return "Region"
		"Region":
			return "County"
		"County":
			return "City"
		_:
			return "Neighborhood"


func _visible_areas() -> Array:
	var areas: Array = []
	var filter_parent: int = -1
	if selected_jurisdiction_id >= 0 and region.jurisdictions[selected_jurisdiction_id].kind == detail_level:
		filter_parent = selected_jurisdiction_id
	for area in region.jurisdictions:
		if area.kind == _aggregate_kind() and (filter_parent < 0 or area.parent_id == filter_parent):
			areas.append(area)
	return areas


func _group_for_neighborhood(neighborhood_id: int) -> int:
	_ensure_aggregate_cache()
	return aggregate_neighborhood_groups[neighborhood_id]


func _ensure_aggregate_cache() -> void:
	if aggregate_cache_region == region and aggregate_cache_level == detail_level and aggregate_node_groups.size() == region.road_nodes.size():
		return
	aggregate_cache_region = region
	aggregate_cache_level = detail_level
	aggregate_flow_cache.clear()
	aggregate_neighborhood_groups.resize(region.neighborhoods.size())
	for neighborhood in region.neighborhoods:
		aggregate_neighborhood_groups[neighborhood.id] = region.jurisdiction_for_neighborhood(neighborhood.id, _aggregate_kind()).id
	aggregate_node_groups.resize(region.road_nodes.size())
	for node in region.road_nodes:
		var neighborhood_id: int = node.neighborhood_id
		if neighborhood_id < 0 and node.city_id >= 0:
			neighborhood_id = region.cities[node.city_id]["neighborhood_ids"][0]
		if neighborhood_id < 0:
			neighborhood_id = region.nearest_neighborhood_id(node.position_km)
		aggregate_node_groups[node.id] = aggregate_neighborhood_groups[neighborhood_id]


func _aggregate_flow_matrix(profile, hour: int, purpose: String) -> Dictionary:
	var cache_key: String = "%d:%d:%s" % [profile.get_instance_id(), hour, purpose]
	if aggregate_flow_cache.has(cache_key):
		return aggregate_flow_cache[cache_key]
	var grouped: Dictionary = {}
	if profile.is_compact:
		if _aggregate_kind() == "Region":
			var regional_matrix: Array = profile.compact_region_od[purpose]
			var regional_curves: Dictionary = profile.compact_curves[purpose]
			for origin_region in range(region.region_ids.size()):
				for destination_region in range(region.region_ids.size()):
					if origin_region == destination_region:
						continue
					var key := Vector2i(region.region_ids[origin_region], region.region_ids[destination_region])
					grouped[key] = regional_matrix[origin_region][destination_region] * regional_curves["out"][hour] + regional_matrix[destination_region][origin_region] * regional_curves["back"][hour]
			aggregate_flow_cache[cache_key] = grouped
			return grouped
		var city_matrix: Array = profile.compact_city_od[purpose]
		var curves: Dictionary = profile.compact_curves[purpose]
		for origin_city in range(region.cities.size()):
			var from_group: int = aggregate_neighborhood_groups[region.cities[origin_city]["neighborhood_ids"][0]]
			for destination_city in range(region.cities.size()):
				var to_group: int = aggregate_neighborhood_groups[region.cities[destination_city]["neighborhood_ids"][0]]
				if from_group == to_group:
					continue
				var key := Vector2i(from_group, to_group)
				grouped[key] = float(grouped.get(key, 0.0)) + city_matrix[origin_city][destination_city] * curves["out"][hour] + city_matrix[destination_city][origin_city] * curves["back"][hour]
		aggregate_flow_cache[cache_key] = grouped
		return grouped
	var matrix: Array = profile.get_hour_matrix(hour, purpose)
	for origin_id in range(aggregate_neighborhood_groups.size()):
		var from_group: int = aggregate_neighborhood_groups[origin_id]
		for destination_id in range(aggregate_neighborhood_groups.size()):
			var to_group: int = aggregate_neighborhood_groups[destination_id]
			if from_group == to_group:
				continue
			var key := Vector2i(from_group, to_group)
			grouped[key] = float(grouped.get(key, 0.0)) + matrix[origin_id][destination_id]
	aggregate_flow_cache[cache_key] = grouped
	return grouped


func _road_node_city(node_id: int) -> int:
	var node = region.road_nodes[node_id]
	return node.city_id if node.city_id >= 0 else region.neighborhoods[region.nearest_neighborhood_id(node.position_km)].city_id


func _is_strategic_road_nodes(from_node_id: int, to_node_id: int, road_class: String) -> bool:
	if road_class in ["Highway", "Rural"]:
		return true
	return _road_node_city(from_node_id) != _road_node_city(to_node_id)


func _countryside_road(link) -> bool:
	return link.road_class == "Collector" and link.managed_neighborhood_id < 0


func _is_strategic_road(link) -> bool:
	if link.road_class == "Highway" or _countryside_road(link):
		return true
	return _is_strategic_road_nodes(link.from_node_id, link.to_node_id, link.road_class)


func _show_local_road_detail() -> bool:
	# Individual street-grid links only matter once a road is a couple of
	# pixels wide; below that the urban layer's own street rendering and the
	# neighbourhood batches carry the picture.
	return not region.is_large_scale or _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM >= 40.0


func _draw_aggregate_roads(pen) -> void:
	_ensure_spatial_index()
	var local_km: float = spatial_local_road_km
	var physical_roads: bool = _pixels_per_meter() >= 0.3
	if not region.is_large_scale or detail_level == "County" and view_zoom >= 4.0 or physical_roads:
		var nearby_indices: Array[int] = _spatial_visible_indices(spatial_road_links, _road_cull_margin(), true) if region.is_large_scale else _all_indices(region.road_links.size())
		for index in nearby_indices:
			var local_link = region.road_links[index]
			if not _is_strategic_road(local_link) and _polyline_visible(local_link.points):
				var local_points: PackedVector2Array = _screen_polyline(local_link.points)
				if physical_roads:
					_draw_active_road(pen, local_points, local_link.lanes_per_direction, local_link.road_class, Color("526474", 0.35), Color("526474", 0.35), false)
				else:
					pen.draw_polyline(local_points, Color("526474", 0.30), 1.0, true)
	for index in spatial_strategic_links:
		var link = region.road_links[index]
		if not _polyline_visible(link.points):
			continue
		var forward_color := Color("3f88b0")
		var reverse_color := forward_color
		if show_traffic_overlay:
			var road_load: Vector3 = _road_load_ratio(index, link)
			forward_color = _congestion_color(road_load.x) if road_load.z > 0.0 else Color("647687")
			reverse_color = _congestion_color(road_load.y) if road_load.z > 0.0 else Color("647687")
		if map_mode == "Trips":
			forward_color.a = 0.23
			reverse_color.a = 0.23
		var points: PackedVector2Array = _screen_polyline(link.points)
		if _map_scale() * view_zoom < 60.0:
			_draw_overview_road(pen, points, link.road_class, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
		else:
			_draw_active_road(pen, points, link.lanes_per_direction, link.road_class, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
	var font := get_theme_default_font()
	pen.draw_string(font, Vector2(18, size.y - 18), "%s view  •  %.0f km of local roads subdued" % [detail_level, local_km], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("aec5d4"))


func _draw_aggregate_road_projects(pen) -> void:
	for project in region.road_projects:
		match project.kind:
			"New road":
				if _is_strategic_road_nodes(project.from_node_id, project.to_node_id, project.road_class):
					if _map_scale() * view_zoom < 60.0:
						_draw_dashed_polyline(pen, _screen_polyline(project.points), Color("aa8b5b", 0.82), 2.0)
					else:
						_draw_dashed_road(pen, _screen_polyline(project.points), project.lanes_per_direction, project.road_class, Color("8fbfd8", 0.70))
			"Widen":
				for link in region.road_links:
					if link.id == project.target_link_id and _is_strategic_road(link):
						var screen_points: PackedVector2Array = _screen_polyline(link.points)
						for direction in range(2):
							var new_lane: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction + 1, direction, link.lanes_per_direction, link.road_class))
							_draw_dashed_polyline(pen, new_lane, Color("f0d38d", 0.9), _road_lane_width(link.road_class))
			"Interchange junction":
				pen.draw_arc(_world_to_screen(region.road_nodes[project.target_node_id].position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)
			"Highway exit":
				pen.draw_arc(_world_to_screen(project.position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)


func _draw_aggregate_flows(pen) -> void:
	if flow_profile == null:
		return
	_ensure_aggregate_cache()
	var visible_ids: Dictionary = {}
	for area in _visible_areas():
		visible_ids[area.id] = true
	var purposes: Array = [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL] if selected_purpose == FlowProfile.ALL else [selected_purpose]
	var flows: Array[Dictionary] = []
	for purpose in purposes:
		var current_grouped: Dictionary = _aggregate_flow_matrix(flow_profile, selected_hour, purpose)
		var next_profile = next_day_profile if selected_hour == 23 and next_day_profile != null else flow_profile
		var next_hour: int = 0 if selected_hour == 23 else selected_hour + 1
		var next_grouped: Dictionary = _aggregate_flow_matrix(next_profile, next_hour, purpose)
		var keys: Dictionary = {}
		for key in current_grouped:
			keys[key] = true
		for key in next_grouped:
			keys[key] = true
		for key in keys:
			if not visible_ids.has(key.x) or not visible_ids.has(key.y):
				continue
			var reverse_key: Vector2i = Vector2i(key.y, key.x)
			var trips: float = lerpf(float(current_grouped.get(key, 0.0)), float(next_grouped.get(key, 0.0)), hour_fraction)
			if purpose != FlowProfile.SOCIAL:
				trips -= lerpf(float(current_grouped.get(reverse_key, 0.0)), float(next_grouped.get(reverse_key, 0.0)), hour_fraction)
			if trips > 0.1:
				flows.append({"from": key.x, "to": key.y, "purpose": purpose, "trips": trips})
	flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	var peak: float = float(flows[0]["trips"]) if not flows.is_empty() else 1.0
	for index in range(mini(30, flows.size())):
		var flow: Dictionary = flows[index]
		var start_point: Vector2 = _world_to_screen(region.jurisdictions[flow["from"]].center_km)
		var end_point: Vector2 = _world_to_screen(region.jurisdictions[flow["to"]].center_km)
		var direction: Vector2 = (end_point - start_point).normalized()
		start_point += direction * 17.0
		end_point -= direction * 17.0
		var strength: float = sqrt(float(flow["trips"]) / maxf(1.0, peak))
		var color: Color = _purpose_color(flow["purpose"])
		color.a = 0.2 + 0.65 * strength
		_draw_flow_stroke(pen, start_point, end_point, color, 1.0 + 5.0 * strength, flow["from"] == selected_jurisdiction_id)
		var side: Vector2 = Vector2(-direction.y, direction.x) * (2.0 + 2.0 * strength)
		pen.draw_colored_polygon(PackedVector2Array([end_point, end_point - direction * 10.0 + side, end_point - direction * 10.0 - side]), color)


func _draw_aggregate_nodes(pen) -> void:
	var font := get_theme_default_font()
	for area in _visible_areas():
		var center: Vector2 = _world_to_screen(area.center_km)
		var population := 0
		for neighborhood_id in area.neighborhood_ids:
			population += region.neighborhoods[neighborhood_id].population
		var radius: float = clampf(8.0 + sqrt(float(population)) * 0.03, 12.0, 23.0)
		pen.draw_circle(center, radius + 3.0, Color("0b1421"))
		pen.draw_circle(center, radius, Color("4b9fbd"))
		pen.draw_arc(center, radius + 3.0, 0.0, TAU, 32, Color("f5d482") if area.id == selected_jurisdiction_id else Color("b7d6e5"), 2.0, true)
		var label: String = area.name
		var label_width: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		pen.draw_string(font, center + Vector2(-label_width * 0.5, -radius - 9.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("d9e9f2"))


func _hit_aggregate_node(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var font := get_theme_default_font()
	for area in _visible_areas():
		var center: Vector2 = _world_to_screen(area.center_km)
		var population := 0
		for neighborhood_id in area.neighborhood_ids:
			population += region.neighborhoods[neighborhood_id].population
		var radius: float = clampf(8.0 + sqrt(float(population)) * 0.03, 12.0, 23.0)
		var label_width: float = font.get_string_size(area.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var label_rect := Rect2(center + Vector2(-label_width * 0.5, -radius - 22.0), Vector2(label_width, 17.0))
		if screen_position.distance_to(center) < 26.0 or label_rect.has_point(screen_position):
			return area.id
	return -1


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), MapStyle.WATER)
	# The control supplies the water background. Retained terrain/geometry
	# and interactive overlays draw above it. External redraws refresh labels.
	if dynamic_overlay != null:
		dynamic_overlay.queue_redraw()


func _draw_static_content(pen) -> void:
	# Runs inside static_layer._draw() with the bake view swapped in.
	if region == null:
		pen.draw_rect(Rect2(Vector2.ZERO, size), MapStyle.WATER)
		return
	static_bake_queued = false
	# Commit the pending bake values; the transform in _process uses these
	# so it always matches the content actually on this layer.
	if pending_bake_key != "":
		bake_key = pending_bake_key
		bake_pan = pending_bake_pan
		bake_zoom = pending_bake_zoom
		pending_bake_key = ""
	_apply_static_transform()
	static_bake_count += 1
	var draw_started: int = Time.get_ticks_usec()
	view_pan = bake_pan
	view_zoom = bake_zoom
	view_origin = Vector2(-BAKE_MARGIN_PX, -BAKE_MARGIN_PX)
	view_size = size + Vector2(BAKE_MARGIN_PX, BAKE_MARGIN_PX) * 2.0
	_draw_road_corridors(pen)
	_draw_road_projects(pen)
	last_draw_stages_us["roads"] = Time.get_ticks_usec() - draw_started
	if show_transit_overlay:
		_draw_transit_overlay(pen)
	if map_mode == "Trips":
		_draw_hourly_flows(pen)
	view_pan = pan
	view_zoom = zoom
	view_origin = Vector2.ZERO
	view_size = size
	last_draw_us = Time.get_ticks_usec() - draw_started
	last_draw_stages_us["done"] = last_draw_us


func _draw_dynamic_content(pen) -> void:
	if region == null:
		return
	var draw_started: int = Time.get_ticks_usec()
	if selected_jurisdiction_id >= 0:
		var selected = region.jurisdictions[selected_jurisdiction_id]
		_draw_polygon_border(pen, selected, Color("fff0b0", 0.95), 3.5)
	if map_mode == "Zoning":
		# Interactive suggestions use the live camera, like their hit tests.
		# Keeping them in the band-scaled static bake can lose their coverage
		# when switching modes or crossing a zoom band.
		_draw_zoning_candidates(pen)
	# Accessibility/desirability circles belong to trip analysis. The normal
	# map shows the actual developed blocks and ordinary place labels.
	if map_mode == "Trips":
		_draw_neighborhoods(pen)
	last_draw_stages_us["neighborhoods"] = Time.get_ticks_usec() - draw_started
	_ensure_jurisdiction_labels()
	_draw_jurisdiction_labels(pen)
	street_labels.draw(self,pen)
	last_draw_stages_us["labels"] = Time.get_ticks_usec() - draw_started
	_draw_jurisdiction_key(pen)
	if map_mode == "Roads":
		if road_tool != "Inspect":
			_draw_road_nodes(pen)
		_draw_road_preview(pen)
		_draw_hidden_road_selection(pen)
		_draw_road_legend(pen)
	elif map_mode == "Trips":
		_draw_legend(pen)
	else:
		_draw_zoning_legend(pen)
	_draw_map_scale(pen)
	var font := get_theme_default_font()
	var hint: String = "Pinch / wheel: zoom  •  Two fingers / drag: pan"
	var hint_width: float = font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var hint_y: float = 55.0 if size.x < 800.0 else size.y - 12.0
	pen.draw_string(font, Vector2(size.x - hint_width - 14.0, hint_y), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("aebfd0"))
	last_overlay_us = Time.get_ticks_usec() - draw_started


func _spatial_cell(point: Vector2) -> Vector2i:
	return Vector2i(
		clampi(floori((point.x - spatial_origin.x) / spatial_cell_size.x), 0, SPATIAL_GRID_SIZE - 1),
		clampi(floori((point.y - spatial_origin.y) / spatial_cell_size.y), 0, SPATIAL_GRID_SIZE - 1)
	)


func _spatial_add_point(buckets: Dictionary, point: Vector2, index: int) -> void:
	var cell: Vector2i = _spatial_cell(point)
	var key: int = cell.y * SPATIAL_GRID_SIZE + cell.x
	if not buckets.has(key):
		buckets[key] = []
	buckets[key].append(index)


func _ensure_spatial_index() -> void:
	if region == null:
		return
	if spatial_region != null and spatial_seed == region.generation_seed and spatial_geometry_revision == region.road_geometry_revision and spatial_neighborhood_count == region.neighborhoods.size() and spatial_link_count == region.road_links.size() and spatial_node_count == region.road_nodes.size():
		spatial_region = region
		return
	spatial_region = region
	spatial_seed = region.generation_seed
	spatial_geometry_revision = region.road_geometry_revision
	spatial_neighborhood_count = region.neighborhoods.size()
	spatial_link_count = region.road_links.size()
	spatial_node_count = region.road_nodes.size()
	spatial_neighborhoods.clear()
	spatial_road_nodes.clear()
	spatial_road_links.clear()
	spatial_strategic_links.clear()
	spatial_local_road_km = 0.0
	var bounds: Rect2 = region.jurisdictions[0].bounds_km
	spatial_origin = bounds.position
	spatial_cell_size = bounds.size / float(SPATIAL_GRID_SIZE)
	for neighborhood in region.neighborhoods:
		_spatial_add_point(spatial_neighborhoods, neighborhood.position_km, neighborhood.id)
	for node_index in range(region.road_nodes.size()):
		_spatial_add_point(spatial_road_nodes, region.road_nodes[node_index].position_km, node_index)
	for link_index in range(region.road_links.size()):
		var link = region.road_links[link_index]
		if _is_strategic_road(link):
			spatial_strategic_links.append(link_index)
		else:
			spatial_local_road_km += link.length_km
		var points: PackedVector2Array = link.points
		if points.is_empty():
			continue
		var link_bounds := Rect2(points[0], Vector2.ZERO)
		for point in points:
			link_bounds = link_bounds.expand(point)
		var first: Vector2i = _spatial_cell(link_bounds.position)
		var last: Vector2i = _spatial_cell(link_bounds.end)
		for cell_y in range(first.y, last.y + 1):
			for cell_x in range(first.x, last.x + 1):
				var key: int = cell_y * SPATIAL_GRID_SIZE + cell_x
				if not spatial_road_links.has(key):
					spatial_road_links[key] = []
				spatial_road_links[key].append(link_index)


func _spatial_visible_indices(buckets: Dictionary, margin: float, unique: bool = false) -> Array[int]:
	return _spatial_rect_indices(buckets, view_rect().position - Vector2(margin, margin), view_rect().end + Vector2(margin, margin), unique)


func _spatial_near_indices(buckets: Dictionary, screen_point: Vector2, radius: float, unique: bool = false) -> Array[int]:
	return _spatial_rect_indices(buckets, screen_point - Vector2(radius, radius), screen_point + Vector2(radius, radius), unique)


func _spatial_rect_indices(buckets: Dictionary, screen_first: Vector2, screen_last: Vector2, unique: bool = false) -> Array[int]:
	_ensure_spatial_index()
	var first: Vector2i = _spatial_cell(_screen_to_world(screen_first))
	var last: Vector2i = _spatial_cell(_screen_to_world(screen_last))
	var result: Array[int] = []
	var seen: Dictionary = {}
	for cell_y in range(first.y, last.y + 1):
		for cell_x in range(first.x, last.x + 1):
			var key: int = cell_y * SPATIAL_GRID_SIZE + cell_x
			if not buckets.has(key):
				continue
			for index in buckets[key]:
				if unique:
					if seen.has(index):
						continue
					seen[index] = true
				result.append(index)
	return result


func _all_indices(count: int) -> Array[int]:
	var indices: Array[int] = []
	indices.resize(count)
	for index in range(count):
		indices[index] = index
	return indices


func _draw_roads(pen) -> void:
	if detail_level != "Neighborhood":
		_draw_aggregate_roads(pen)
		_draw_aggregate_road_projects(pen)
		return
	var overview: bool = _map_scale() * view_zoom < 60.0
	var road_indices: Array[int] = _spatial_visible_indices(spatial_road_links, _road_cull_margin(), true) if region.is_large_scale and view_zoom >= 2.0 else _all_indices(region.road_links.size())
	var batch_roads: bool = region.is_large_scale and view_zoom >= 2.0 and _pixels_per_meter() < 0.025
	var show_local_roads: bool = _show_local_road_detail()
	var casing_lines: Dictionary = {}
	var lane_lines := PackedVector2Array()
	var lane_colors := PackedColorArray()
	var arrow_vertices := PackedVector2Array()
	var arrow_colors := PackedColorArray()
	var local_casing_lines := PackedVector2Array()
	var local_lines := PackedVector2Array()
	var local_colors := PackedColorArray()
	var selected_local_points := PackedVector2Array()
	var selected_points := PackedVector2Array()
	var selected_lanes: int = 0
	var drawn_by_class := {}
	for link_index in road_indices:
		var link = region.road_links[link_index]
		# The rural web is far too dense to draw wholesale; it appears once the
		# spatial culling view_zoom is active.
		if region.is_large_scale and view_zoom < 2.0 and _countryside_road(link):
			continue
		# Countryside collectors keep the lighter rural styling; the class
		# hierarchy no longer carries a separate Rural type.
		var road_class: String = "Rural" if _countryside_road(link) else link.road_class
		if not show_local_roads and not _is_strategic_road(link):
			continue
		if not _polyline_visible(link.points):
			continue
		var forward_color := Color("3f88b0")
		var reverse_color := forward_color
		if show_traffic_overlay:
			var road_load: Vector3 = _road_load_ratio(link_index, link)
			forward_color = _congestion_color(road_load.x) if road_load.z > 0.0 else Color("647687")
			reverse_color = _congestion_color(road_load.y) if road_load.z > 0.0 else Color("647687")
		if map_mode == "Trips":
			forward_color.a = 0.23
			reverse_color.a = 0.23
		var screen_points: PackedVector2Array = _screen_polyline(link.points)
		if overview:
			if road_class == "Local" or (road_class == "Collector" and not _is_strategic_road(link)):
				var color: Color = forward_color.lerp(reverse_color, 0.5) if show_traffic_overlay else Color("a7afb1", 0.55)
				if selected_road_link_id == link.id and map_mode == "Roads":
					selected_local_points = screen_points
				if batch_roads:
					for segment in range(1, screen_points.size()):
						local_lines.append(screen_points[segment - 1])
						local_lines.append(screen_points[segment])
						local_colors.append(color)
				else:
					pen.draw_polyline(screen_points, color, 0.8, true)
			elif road_class == "Rural" and batch_roads:
				var rural_color: Color = forward_color.lerp(reverse_color, 0.5) if show_traffic_overlay else Color("a5aeb4")
				if map_mode == "Trips":
					rural_color.a = 0.25
				if selected_road_link_id == link.id and map_mode == "Roads":
					selected_local_points = screen_points
				for segment in range(1, screen_points.size()):
					local_lines.append(screen_points[segment - 1])
					local_lines.append(screen_points[segment])
					local_colors.append(rural_color)
			else:
				_draw_overview_road(pen, screen_points, road_class, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
			continue
		if road_class == "Local":
			if not batch_roads:
				_draw_active_road(pen, screen_points, link.lanes_per_direction, road_class, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
			else:
				if selected_road_link_id == link.id and map_mode == "Roads":
					selected_local_points = screen_points
				for segment in range(1, screen_points.size()):
					local_lines.append(screen_points[segment - 1])
					local_lines.append(screen_points[segment])
					local_colors.append(forward_color.lerp(reverse_color, 0.5))
					if map_mode == "Roads":
						local_casing_lines.append(screen_points[segment - 1])
						local_casing_lines.append(screen_points[segment])
			continue
		if not batch_roads:
			_draw_active_road(pen, screen_points, link.lanes_per_direction, road_class, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
			continue
		if selected_road_link_id == link.id and map_mode == "Roads":
			selected_points = screen_points
			selected_lanes = link.lanes_per_direction
		if map_mode == "Roads":
			var casing: PackedVector2Array = casing_lines.get(link.lanes_per_direction, PackedVector2Array())
			for segment in range(1, screen_points.size()):
				casing.append(screen_points[segment - 1])
				casing.append(screen_points[segment])
			casing_lines[link.lanes_per_direction] = casing
		for direction in range(2):
			var lane_color: Color = forward_color if direction == 0 else reverse_color
			for lane_index in range(link.lanes_per_direction):
				var lane_points: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction, direction, lane_index, road_class))
				for segment in range(1, lane_points.size()):
					lane_lines.append(lane_points[segment - 1])
					lane_lines.append(lane_points[segment])
					lane_colors.append(lane_color)
		if map_mode == "Roads":
			_append_road_arrow_triangles(screen_points, link.lanes_per_direction, arrow_vertices, arrow_colors)
	if batch_roads:
		var local_width: float = 0.8 if overview else maxf(1.8, 6.0 * _pixels_per_meter())
		if not selected_local_points.is_empty():
			pen.draw_polyline(selected_local_points, Color("f7f0bf"), local_width + 4.0, true)
		if not local_casing_lines.is_empty():
			pen.draw_multiline(local_casing_lines, Color("17252c"), local_width + 1.5, true)
		if not local_lines.is_empty():
			pen.draw_multiline_colors(local_lines, local_colors, local_width, true)
		if not selected_points.is_empty():
			pen.draw_polyline(selected_points, Color("f7f0bf"), _road_outer_half_width(selected_lanes, "Highway") * 2.0 + 3.0, true)
		for lane_count in casing_lines:
			pen.draw_multiline(casing_lines[lane_count], Color("091321"), _road_outer_half_width(lane_count, "Highway") * 2.0, true)
		if not lane_lines.is_empty():
			pen.draw_multiline_colors(lane_lines, lane_colors, _road_lane_width("Highway"), true)
		if not arrow_vertices.is_empty():
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = arrow_vertices
			arrays[Mesh.ARRAY_COLOR] = arrow_colors
			road_arrow_mesh = ArrayMesh.new()
			road_arrow_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			pen.draw_mesh(road_arrow_mesh, null)
	if _pixels_per_meter() >= 0.035:
		for link_index in road_indices:
			var link = region.road_links[link_index]
			for span in link.terrain_spans:
				if span["kind"] not in ["Bridge", "Tunnel"]:
					continue
				var path: PackedVector2Array = span.get("points", PackedVector2Array([span["from"], span["to"]]))
				if path.size() >= 2 and _polyline_visible(path):
					pen.draw_polyline(_screen_polyline(path), Color("a9d9e2", 0.82) if span["kind"] == "Bridge" else Color("b4a2cc", 0.72), 2.2, true)
	for project in region.road_projects:
		match project.kind:
			"New road":
				var work:Array=project.build_plan.get("work",[{"points":project.points,"road_class":project.road_class}])
				for item in work:
					if overview:
						_draw_dashed_polyline(pen, _screen_polyline(item.points), Color("aa8b5b", 0.82), 2.0)
					else:
						_draw_dashed_road(pen, _screen_polyline(item.points), project.lanes_per_direction, item.road_class, Color("8fbfd8", 0.70))
			"Widen":
				for link in region.road_links:
					if link.id == project.target_link_id:
						var screen_points: PackedVector2Array = _screen_polyline(link.points)
						for direction in range(2):
							var new_lane: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction + 1, direction, link.lanes_per_direction, link.road_class))
							_draw_dashed_polyline(pen, new_lane, Color("f0d38d", 0.9), _road_lane_width(link.road_class))
			"Interchange junction":
				pen.draw_arc(_world_to_screen(region.road_nodes[project.target_node_id].position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)
			"Highway exit":
				pen.draw_arc(_world_to_screen(project.position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)


func _draw_road_projects(pen) -> void:
	var overview: bool = _map_scale() * view_zoom < 60.0
	for project in region.road_projects:
		match project.kind:
			"New road":
				if overview:
					_draw_dashed_polyline(pen, _screen_polyline(project.points), Color("aa8b5b", 0.82), 2.0)
				else:
					_draw_dashed_road(pen, _screen_polyline(project.points), project.lanes_per_direction, project.road_class, Color("8fbfd8", 0.70))
			"Widen":
				for link in region.road_links:
					if link.id == project.target_link_id:
						var screen_points: PackedVector2Array = _screen_polyline(link.points)
						for direction in range(2):
							var new_lane: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction + 1, direction, link.lanes_per_direction, link.road_class))
							_draw_dashed_polyline(pen, new_lane, Color("f0d38d", 0.9), _road_lane_width(link.road_class))
			"Interchange junction":
				pen.draw_arc(_world_to_screen(region.road_nodes[project.target_node_id].position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)
			"Highway exit":
				pen.draw_arc(_world_to_screen(project.position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)


func _append_road_arrow_triangles(screen_points: PackedVector2Array, lanes: int, vertices: PackedVector2Array, colors: PackedColorArray) -> void:
	var total_length := 0.0
	for segment in range(1, screen_points.size()):
		total_length += screen_points[segment - 1].distance_to(screen_points[segment])
	if total_length < 16.0:
		return
	var station: float = minf(24.0, total_length * 0.5)
	var traveled := 0.0
	for segment in range(1, screen_points.size()):
		var start_point: Vector2 = screen_points[segment - 1]
		var end_point: Vector2 = screen_points[segment]
		var displacement: Vector2 = end_point - start_point
		var segment_length: float = displacement.length()
		if segment_length < 0.001:
			continue
		var tangent: Vector2 = displacement / segment_length
		var normal: Vector2 = tangent.orthogonal()
		var bundle_offset: float = _road_median_half_gap("Highway") + _road_lane_spacing("Highway") * float(lanes) * 0.5
		while station <= traveled + segment_length and station <= total_length - 8.0:
			var point: Vector2 = start_point + tangent * (station - traveled)
			for direction in range(2):
				var travel: Vector2 = tangent if direction == 0 else -tangent
				var tip: Vector2 = point + normal * bundle_offset * _road_direction_side(direction)
				var base: Vector2 = tip - travel * 4.0
				var wing: Vector2 = travel.orthogonal() * 2.2
				vertices.append(tip)
				vertices.append(base + wing)
				vertices.append(base - wing)
				for corner in range(3):
					colors.append(Color("f1f7fa", 0.88))
			station += 72.0
		traveled += segment_length


func _draw_active_road(pen, screen_points: PackedVector2Array, lanes: int, road_class: String, forward_color: Color, reverse_color: Color, selected: bool) -> void:
	if screen_points.size() < 2:
		return
	if road_class == "Local":
		var width: float = maxf(1.8, 6.0 * _pixels_per_meter())
		if selected and map_mode == "Roads":
			pen.draw_polyline(screen_points, Color("f7f0bf"), width + 4.0, true)
		if map_mode == "Roads":
			pen.draw_polyline(screen_points, Color("17252c"), width + 1.5, true)
		pen.draw_polyline(screen_points, forward_color.lerp(reverse_color, 0.5), width, true)
		return
	if map_mode == "Roads":
		var casing_width: float = _road_outer_half_width(lanes, road_class) * 2.0
		if selected:
			pen.draw_polyline(screen_points, Color("f7f0bf"), casing_width + 3.0, true)
		pen.draw_polyline(screen_points, Color("091321"), casing_width, true)
	for direction in range(2):
		var lane_color: Color = forward_color if direction == 0 else reverse_color
		for lane_index in range(lanes):
			var lane_points: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(lanes, direction, lane_index, road_class))
			pen.draw_polyline(lane_points, lane_color, _road_lane_width(road_class), true)
	if map_mode == "Roads":
		_draw_road_direction_arrows(pen, screen_points, lanes, road_class)


func _draw_overview_road(pen, screen_points: PackedVector2Array, road_class: String, forward_color: Color, reverse_color: Color, selected: bool) -> void:
	if screen_points.size() < 2:
		return
	var highway: bool = road_class == "Highway"
	var rural: bool = road_class == "Rural"
	var outer_width: float = 4.0 if highway else (2.0 if rural else 2.8)
	var inner_width: float = 2.45 if highway else (1.0 if rural else 1.55)
	var route_color: Color = Color("8193b1") if highway else Color("a5aeb4")
	if show_traffic_overlay:
		route_color = forward_color.lerp(reverse_color, 0.5)
	if map_mode == "Trips":
		route_color.a = 0.25
	if selected:
		pen.draw_polyline(screen_points, Color("f3cd70"), outer_width + 4.0, true)
	pen.draw_polyline(screen_points, Color("fbfaf5", route_color.a), outer_width, true)
	pen.draw_polyline(screen_points, route_color, inner_width, true)


func _draw_road_direction_arrows(pen, screen_points: PackedVector2Array, lanes: int, road_class: String) -> void:
	if road_class in ["Collector", "Rural"] and _pixels_per_meter() >= 0.025:
		return
	var lane_width: float = _road_lane_width(road_class)
	var arrow_spacing: float = maxf(180.0, lane_width * 7.0)
	var bundle_offset: float = _road_median_half_gap(road_class) + _road_lane_spacing(road_class) * float(lanes) * 0.5
	for segment in range(1, screen_points.size()):
		var start_point: Vector2 = screen_points[segment - 1]
		var end_point: Vector2 = screen_points[segment]
		var displacement: Vector2 = end_point - start_point
		var segment_length: float = displacement.length()
		if segment_length < 16.0:
			continue
		var tangent: Vector2 = displacement / segment_length
		var normal: Vector2 = tangent.orthogonal()
		var visible_offsets: Vector2 = _visible_segment_offsets(start_point, tangent, segment_length, bundle_offset + lane_width)
		if visible_offsets.x > visible_offsets.y:
			continue
		var first_arrow: int = maxi(0, ceili(visible_offsets.x / arrow_spacing - 0.5))
		var last_arrow: int = floori(visible_offsets.y / arrow_spacing - 0.5)
		if segment_length <= arrow_spacing:
			first_arrow = 0
			last_arrow = 0
		for arrow_index in range(first_arrow, last_arrow + 1):
			var along: float = segment_length * 0.5 if segment_length <= arrow_spacing else (float(arrow_index) + 0.5) * arrow_spacing
			for direction in range(2):
				var travel: Vector2 = tangent if direction == 0 else -tangent
				var tip_position: Vector2 = start_point + tangent * along + normal * bundle_offset * _road_direction_side(direction)
				if not _screen_visible(tip_position, lane_width):
					continue
				var arrow_length: float = maxf(6.0, lane_width * 0.45)
				var arrow_base: Vector2 = tip_position - travel * arrow_length
				var wing: Vector2 = travel.orthogonal() * maxf(2.2, lane_width * 0.18)
				pen.draw_colored_polygon(PackedVector2Array([tip_position, arrow_base + wing, arrow_base - wing]), Color("f1f7fa", 0.88))


func _visible_segment_offsets(start_point: Vector2, tangent: Vector2, segment_length: float, margin: float) -> Vector2:
	var viewport: Rect2 = view_rect().grow(margin)
	var min_offset: float = INF
	var max_offset: float = -INF
	for corner in [viewport.position, Vector2(viewport.end.x, viewport.position.y), viewport.end, Vector2(viewport.position.x, viewport.end.y)]:
		var along: float = (corner - start_point).dot(tangent)
		min_offset = minf(min_offset, along)
		max_offset = maxf(max_offset, along)
	return Vector2(maxf(0.0, min_offset), minf(segment_length, max_offset))


func _screen_polyline(world_points: PackedVector2Array) -> PackedVector2Array:
	return _screen_transform() * world_points


func _screen_transform() -> Transform2D:
	var scale: float = _map_scale() * view_zoom
	return Transform2D(Vector2(scale, 0.0), Vector2(0.0, scale), size * 0.5 + view_pan - _world_center() * scale)


func _offset_polyline(screen_points: PackedVector2Array, offset: float) -> PackedVector2Array:
	var shifted := PackedVector2Array()
	for index in range(screen_points.size()):
		var first_segment: Vector2 = (screen_points[index] - screen_points[maxi(0, index - 1)]).normalized()
		var second_segment: Vector2 = (screen_points[mini(screen_points.size() - 1, index + 1)] - screen_points[index]).normalized()
		if first_segment == Vector2.ZERO:
			first_segment = second_segment
		if second_segment == Vector2.ZERO:
			second_segment = first_segment
		var first_normal: Vector2 = first_segment.orthogonal()
		var second_normal: Vector2 = second_segment.orthogonal()
		var bisector: Vector2 = (first_normal + second_normal).normalized()
		var direction: Vector2 = second_normal if bisector == Vector2.ZERO else bisector / maxf(0.35, bisector.dot(second_normal))
		shifted.append(screen_points[index] + direction * offset)
	return shifted


func _pixels_per_meter() -> float:
	return _map_scale() * view_zoom / 1000.0


func _road_lane_spacing(road_class: String) -> float:
	var lane_meters: float = 3.6 if road_class == "Highway" else 3.25
	if road_class in ["Collector", "Rural"] and _pixels_per_meter() >= 0.025:
		return maxf(0.9, lane_meters * _pixels_per_meter())
	return maxf(clampf(2.7 * sqrt(view_zoom), 2.3, 4.2), lane_meters * _pixels_per_meter())


func _road_lane_width(road_class: String) -> float:
	var lane_meters: float = 3.5 if road_class == "Highway" else 3.15
	if road_class in ["Collector", "Rural"] and _pixels_per_meter() >= 0.025:
		return maxf(0.8, lane_meters * _pixels_per_meter())
	return maxf(clampf(1.8 * sqrt(view_zoom), 1.5, 2.5), lane_meters * _pixels_per_meter())


func _road_median_half_gap(road_class: String) -> float:
	var half_meters: float = 1.5 if road_class == "Highway" else 0.35
	if road_class in ["Collector", "Rural"] and _pixels_per_meter() >= 0.025:
		return half_meters * _pixels_per_meter()
	return maxf(clampf(1.6 * sqrt(view_zoom), 1.4, 2.4), half_meters * _pixels_per_meter())


func _road_lane_offset(_lanes: int, direction: int, lane_index: int, road_class: String) -> float:
	return _road_direction_side(direction) * (_road_median_half_gap(road_class) + _road_lane_spacing(road_class) * (float(lane_index) + 0.5))


func _road_direction_side(direction: int) -> float:
	# Vector2.orthogonal() points to the screen-left of the road's forward path.
	return -1.0 if direction == 0 else 1.0


func _road_outer_half_width(lanes: int, road_class: String) -> float:
	var shoulder_meters: float = 2.0 if road_class == "Highway" else 0.8
	return _road_median_half_gap(road_class) + _road_lane_spacing(road_class) * float(lanes) + maxf(0.7, shoulder_meters * _pixels_per_meter())


func _road_cull_margin() -> float:
	return maxf(25.0, _road_outer_half_width(5, "Highway") + 4.0)


func _draw_dashed_polyline(pen, screen_points: PackedVector2Array, color: Color, width: float) -> void:
	var dash_length: float = maxf(10.0, width * 1.5)
	var period: float = dash_length + maxf(6.0, width * 0.6)
	var traveled := 0.0
	var viewport := view_rect().grow(width)
	for index in range(1, screen_points.size()):
		var first: Vector2 = screen_points[index - 1]
		var last: Vector2 = screen_points[index]
		var length: float = first.distance_to(last)
		if length < 0.0001:
			continue
		var direction: Vector2 = (last - first) / length
		var cursor := 0.0
		while cursor < length - 0.0001:
			var phase: float = fposmod(traveled + cursor, period)
			var drawing: bool = phase < dash_length
			var run: float = minf(length - cursor, (dash_length - phase) if drawing else (period - phase))
			if run < 0.0001:
				run = minf(length - cursor, 0.0001)
			if drawing:
				var start_point: Vector2 = first + direction * cursor
				var end_point: Vector2 = first + direction * (cursor + run)
				if viewport.intersects(Rect2(start_point, Vector2.ZERO).expand(end_point)):
					pen.draw_line(start_point, end_point, color, width, true)
			cursor += run
		traveled += length


func _draw_dashed_road(pen, screen_points: PackedVector2Array, lanes: int, road_class: String, color: Color) -> void:
	if road_class == "Local":
		_draw_dashed_polyline(pen, screen_points, color, maxf(1.8, 6.0 * _pixels_per_meter()))
		return
	for direction in range(2):
		for lane_index in range(lanes):
			_draw_dashed_polyline(pen, _offset_polyline(screen_points, _road_lane_offset(lanes, direction, lane_index, road_class)), color, _road_lane_width(road_class))


func _congestion_color(ratio: float) -> Color:
	if ratio <= 0.7:
		return Color("5abfa5").lerp(Color("e6c56f"), clampf(ratio / 0.7, 0.0, 1.0))
	return Color("e6c56f").lerp(Color("e25e5e"), clampf((ratio - 0.7) / 0.8, 0.0, 1.0))


func _road_load_ratio(link_index: int, link) -> Vector3:
	var sample: Vector4 = _road_sample(link_index, link)
	if not is_finite(sample.x):
		return Vector3.ZERO
	var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
	return Vector3(maxf(sample.x / capacity, sample.z / (capacity * 0.5)), maxf(sample.y / capacity, sample.w / (capacity * 0.5)), 1.0)


func _road_sample(link_index: int, link) -> Vector4:
	match road_traffic_mode:
		ROAD_LIVE:
			return _live_road_sample(link_index, link)
		ROAD_HOUR:
			return _hour_road_sample(link_index, link)
		ROAD_DAY:
			var previous: Vector4 = _summary_road_sample(previous_day_road_summary, link.id) if _previous_day_summary_valid() else Vector4(INF, 0.0, 0.0, 0.0)
			var current: Vector4 = _summary_road_sample(current_day_road_summary, link.id) if _current_day_summary_valid() else Vector4(INF, 0.0, 0.0, 0.0)
			if is_finite(previous.x) and is_finite(current.x):
				return previous.lerp(current, day_road_fraction)
			if is_finite(current.x):
				return current
			if is_finite(previous.x):
				return previous
			return _live_road_sample(link_index, link)
		ROAD_HISTORY:
			return _history_road_sample(link_index, link)
	return Vector4(INF, 0.0, 0.0, 0.0)


func _live_road_sample(link_index: int, link) -> Vector4:
	if not _has_live_road_sample(link_index, link):
		return _recent_day_road_sample(link.id)
	var served: Vector2 = live_traffic_state.last_served[link_index]
	var queue: Vector2 = live_traffic_state.queues[link_index]
	return Vector4(served.x, served.y, queue.x, queue.y)


func _has_live_road_sample(link_index: int, link) -> bool:
	return live_traffic_state != null and live_traffic_state.has_live_sample and link_index >= 0 and link_index < live_traffic_state.link_ids.size() and live_traffic_state.link_ids[link_index] == link.id


func _live_road_time(link_index: int, link, queue: Vector2) -> Vector2:
	var capacity: float = RoadGraph.capacity_per_lane(link.road_class) * link.lanes_per_direction
	var free_minutes: float = live_traffic_state.free_link_costs[link_index].x
	return Vector2(free_minutes + 60.0 * queue.x / capacity, free_minutes + 60.0 * queue.y / capacity)


func _hour_road_sample(link_index: int, link) -> Vector4:
	if road_history_current_hour < 0:
		var carried: Vector4 = _summary_road_sample(hour_carry_summary, link.id) if _hour_carry_valid() else Vector4(INF, 0.0, 0.0, 0.0)
		return carried if is_finite(carried.x) else _live_road_sample(link_index, link)
	if traffic_profile == null or link_index >= traffic_profile.link_ids.size() or traffic_profile.link_ids[link_index] != link.id:
		var carried: Vector4 = _summary_road_sample(hour_carry_summary, link.id) if _hour_carry_valid() else Vector4(INF, 0.0, 0.0, 0.0)
		return carried if is_finite(carried.x) else _live_road_sample(link_index, link)
	var hour: int = road_history_current_hour
	var current_served: Vector2 = traffic_profile.hourly_served[hour][link_index]
	var current_queue: Vector2 = traffic_profile.quarter_hour_queues[hour * 4 + 3][link_index]
	var previous_served: Vector2 = current_served
	var previous_queue: Vector2 = current_queue
	if road_history_previous_hour >= 0:
		previous_served = traffic_profile.hourly_served[road_history_previous_hour][link_index]
		previous_queue = traffic_profile.quarter_hour_queues[road_history_previous_hour * 4 + 3][link_index]
	else:
		var carry_index: int = _summary_link_index(hour_carry_summary, link.id) if _hour_carry_valid() else -1
		if carry_index >= 0:
			previous_served = hour_carry_summary["served"][carry_index]
			previous_queue = hour_carry_summary["queue"][carry_index]
		else:
			var recent: Vector4 = _recent_day_road_sample(link.id)
			if is_finite(recent.x):
				previous_served = Vector2(recent.x, recent.y)
				previous_queue = Vector2(recent.z, recent.w)
	var served: Vector2 = previous_served.lerp(current_served, road_history_fraction)
	var queue: Vector2 = previous_queue.lerp(current_queue, road_history_fraction)
	return Vector4(served.x, served.y, queue.x, queue.y)


func _history_road_sample(link_index: int, link) -> Vector4:
	if traffic_profile == null or not _is_recorded_time() or link_index >= traffic_profile.link_ids.size() or traffic_profile.link_ids[link_index] != link.id:
		return Vector4(INF, 0.0, 0.0, 0.0)
	var bin_index: int = selected_hour * 4 + floori(hour_fraction * 4.0)
	var served: Vector2 = traffic_profile.quarter_hour_served[bin_index][link_index] * 4.0
	if live_traffic_state != null and live_traffic_state.has_live_sample and bin_index == (live_traffic_state.unix_seconds % 86400) / 900:
		served = live_traffic_state.last_served[link_index]
	var queue: Vector2 = traffic_profile.quarter_hour_queues[bin_index][link_index]
	return Vector4(served.x, served.y, queue.x, queue.y)


func _summary_link_index(summary: Dictionary, link_id: int) -> int:
	return int(summary.get("by_link_id", {}).get(link_id, -1))


func _hour_carry_valid() -> bool:
	return live_traffic_state != null and int(hour_carry_summary.get("day_key", -1)) == live_traffic_state.day_key - 1


func _current_day_summary_valid() -> bool:
	return live_traffic_state != null and int(current_day_road_summary.get("day_key", -1)) == live_traffic_state.day_key


func _previous_day_summary_valid() -> bool:
	return live_traffic_state != null and int(previous_day_road_summary.get("day_key", -1)) == live_traffic_state.day_key - 1


func _summary_road_sample(summary: Dictionary, link_id: int) -> Vector4:
	var index: int = _summary_link_index(summary, link_id)
	if index < 0:
		return Vector4(INF, 0.0, 0.0, 0.0)
	var served: Vector2 = summary["served"][index]
	var queue: Vector2 = summary["queue"][index]
	return Vector4(served.x, served.y, queue.x, queue.y)


func _recent_day_road_sample(link_id: int) -> Vector4:
	if live_traffic_state == null:
		return Vector4(INF, 0.0, 0.0, 0.0)
	if _current_day_summary_valid():
		var current: Vector4 = _summary_road_sample(current_day_road_summary, link_id)
		if is_finite(current.x):
			return current
	if _previous_day_summary_valid():
		return _summary_road_sample(previous_day_road_summary, link_id)
	return Vector4(INF, 0.0, 0.0, 0.0)


func _recent_day_metric(link_id: int, key: String) -> Vector2:
	if live_traffic_state == null:
		return Vector2.ZERO
	if _current_day_summary_valid():
		var current_index: int = _summary_link_index(current_day_road_summary, link_id)
		if current_index >= 0:
			return current_day_road_summary[key][current_index]
	if _previous_day_summary_valid():
		var previous_index: int = _summary_link_index(previous_day_road_summary, link_id)
		if previous_index >= 0:
			return previous_day_road_summary[key][previous_index]
	return Vector2.ZERO


func get_road_traffic_metrics(link_index: int, link) -> Dictionary:
	var sample: Vector4 = _road_sample(link_index, link)
	if not is_finite(sample.x):
		return {}
	var demand: Vector2 = Vector2.ZERO
	var time: Vector2 = Vector2.ZERO
	var label: String = "SELECTED TIME"
	match road_traffic_mode:
		ROAD_LIVE:
			if _has_live_road_sample(link_index, link):
				demand = live_traffic_state.last_arrivals[link_index]
				time = _live_road_time(link_index, link, Vector2(sample.z, sample.w))
				label = "LIVE TRAFFIC"
			else:
				demand = _recent_day_metric(link.id, "demand")
				time = _recent_day_metric(link.id, "time")
				label = "RECENT DAILY ESTIMATE"
		ROAD_HOUR:
			var hour: int = road_history_current_hour
			if hour >= 0 and traffic_profile != null and link_index < traffic_profile.link_ids.size() and traffic_profile.link_ids[link_index] == link.id:
				var current_demand: Vector2 = traffic_profile.hourly_volumes[hour][link_index]
				var current_time: Vector2 = traffic_profile.hourly_link_times[hour][link_index]
				var previous_demand: Vector2 = current_demand
				var previous_time: Vector2 = current_time
				if road_history_previous_hour >= 0:
					previous_demand = traffic_profile.hourly_volumes[road_history_previous_hour][link_index]
					previous_time = traffic_profile.hourly_link_times[road_history_previous_hour][link_index]
				else:
					var carry_index: int = _summary_link_index(hour_carry_summary, link.id) if _hour_carry_valid() else -1
					if carry_index >= 0:
						previous_demand = hour_carry_summary["demand"][carry_index]
						previous_time = hour_carry_summary["time"][carry_index]
					elif is_finite(_recent_day_road_sample(link.id).x):
						previous_demand = _recent_day_metric(link.id, "demand")
						previous_time = _recent_day_metric(link.id, "time")
				demand = previous_demand.lerp(current_demand, road_history_fraction)
				time = previous_time.lerp(current_time, road_history_fraction)
				label = "COMPLETED HOURS"
			else:
				var carry_index: int = _summary_link_index(hour_carry_summary, link.id) if _hour_carry_valid() else -1
				if carry_index >= 0:
					demand = hour_carry_summary["demand"][carry_index]
					time = hour_carry_summary["time"][carry_index]
					label = "PREVIOUS COMPLETED HOUR"
				elif _has_live_road_sample(link_index, link):
					demand = live_traffic_state.last_arrivals[link_index]
					time = _live_road_time(link_index, link, Vector2(sample.z, sample.w))
					label = "LATEST TRAFFIC ESTIMATE"
				else:
					demand = _recent_day_metric(link.id, "demand")
					time = _recent_day_metric(link.id, "time")
					label = "RECENT DAILY ESTIMATE"
		ROAD_DAY:
			var previous_index: int = _summary_link_index(previous_day_road_summary, link.id) if _previous_day_summary_valid() else -1
			var current_index: int = _summary_link_index(current_day_road_summary, link.id) if _current_day_summary_valid() else -1
			if previous_index >= 0 and current_index >= 0:
				demand = previous_day_road_summary["demand"][previous_index].lerp(current_day_road_summary["demand"][current_index], day_road_fraction)
				time = previous_day_road_summary["time"][previous_index].lerp(current_day_road_summary["time"][current_index], day_road_fraction)
				label = "DAILY AVERAGE ESTIMATE"
			elif current_index >= 0:
				demand = current_day_road_summary["demand"][current_index]
				time = current_day_road_summary["time"][current_index]
				label = "DAILY AVERAGE ESTIMATE"
			elif previous_index >= 0:
				demand = previous_day_road_summary["demand"][previous_index]
				time = previous_day_road_summary["time"][previous_index]
				label = "PREVIOUS DAILY ESTIMATE"
			elif _has_live_road_sample(link_index, link):
				demand = live_traffic_state.last_arrivals[link_index]
				time = _live_road_time(link_index, link, Vector2(sample.z, sample.w))
				label = "LATEST TRAFFIC ESTIMATE"
			else:
				demand = _recent_day_metric(link.id, "demand")
				time = _recent_day_metric(link.id, "time")
				label = "RECENT DAILY ESTIMATE"
		ROAD_HISTORY:
			var bin_index: int = selected_hour * 4 + floori(hour_fraction * 4.0)
			demand = traffic_profile.hourly_volumes[selected_hour][link_index]
			time = traffic_profile.quarter_hour_link_times[bin_index][link_index]
	return {"demand": demand, "served": Vector2(sample.x, sample.y), "queue": Vector2(sample.z, sample.w), "time": time, "label": label}


func _draw_road_nodes(pen) -> void:
	var overview_ppk: float = _map_scale() * view_zoom
	var show_local_roads: bool = overview_ppk >= 25.0 or road_tool != "Inspect"
	var node_indices: Array[int] = _spatial_visible_indices(spatial_road_nodes, 16.0) if region.is_large_scale and zoom >= 2.0 else _all_indices(region.road_nodes.size())
	for node_id in node_indices:
		var node = region.road_nodes[node_id]
		if node.managed_neighborhood_id >= 0 and road_tool == "Inspect":
			continue
		if road_tool == "Inspect" and _pixels_per_meter() >= 0.03 and not node.is_interchange:
			continue
		if not show_local_roads and node.kind != "City" and not node.is_interchange:
			continue
		var position_on_screen: Vector2 = _world_to_screen(node.position_km)
		if not _screen_visible(position_on_screen, 16.0):
			continue
		if detail_level != "Neighborhood" and node.neighborhood_id >= 0 and not node.is_interchange:
			pen.draw_circle(position_on_screen, 2.0, Color("8ea3b1", 0.48))
			continue
		var overview: bool = _map_scale() * zoom < 60.0
		var radius := (3.0 if overview else 5.0) if node.is_interchange else (2.5 if overview else 3.5)
		var dormant: bool = node.neighborhood_id >= 0 and region.neighborhoods[node.neighborhood_id].development_state == "Dormant"
		if node.kind == "City":
			dormant = region.city_development_state(region.city_jurisdiction_ids[node.city_id]) == "Dormant"
		if dormant:
			if road_tool == "Inspect" and overview_ppk < 25.0:
				continue
			pen.draw_arc(position_on_screen, 3.5, 0.0, TAU, 12, Color("718899", 0.65), 1.0, true)
			continue
		pen.draw_circle(position_on_screen, radius + (1.0 if overview else 2.0), Color("f7f6f1") if overview else Color("091321"))
		pen.draw_circle(position_on_screen, radius, Color("f2d786") if node.is_interchange else Color("c8d5df"))
		if node.is_interchange and not overview:
			pen.draw_arc(position_on_screen, radius + 4.0, 0.0, TAU, 24, Color("f2d786", 0.8), 1.0, true)


func _draw_road_preview(pen) -> void:
	if planning_preview_start.is_finite():
		var guide_color: Color = Color("9fc7f0") if planning_preview_kind == "Rail corridor" else Color("ecc679")
		pen.draw_circle(_world_to_screen(planning_preview_start), 5.0, guide_color)
		pen.draw_dashed_line(_world_to_screen(planning_preview_start), _world_to_screen(hover_world_position), guide_color, 2.0, 7.0, true)
	if preview_start_node >= 0 or preview_start_position.is_finite():
		var start:Vector2=region.road_nodes[preview_start_node].position_km if preview_start_node>=0 else preview_start_position
		var points: PackedVector2Array = road_preview["points"] if road_preview.get("ok", false) else PackedVector2Array([start])
		if not road_preview.get("ok", false):
			var multi_curve: bool = road_draw_mode == RoadRouteBuilder.MULTIPOINT
			var awaiting_guide: bool = multi_curve and preview_waypoints.size() % 2 == 0
			if multi_curve and not preview_frozen_route.is_empty():
				points = preview_frozen_route
			var snap_guide: Dictionary = RoadPlanner.snap_guidance(region, preview_start_node, preview_waypoints, hover_world_position, road_tool, road_draw_mode, road_snap_enabled, road_length_snap_enabled) if preview_start_node>=0 and (road_snap_enabled or road_length_snap_enabled) else {}
			var ghost: Vector2 = snap_guide.get("position", hover_world_position)
			var guide_origin: Vector2 = preview_waypoints[-1] if not preview_waypoints.is_empty() else start
			var ray: Vector2 = ghost - guide_origin
			if ray.length() > 0.001:
				pen.draw_dashed_line(_world_to_screen(guide_origin), _world_to_screen(ghost), Color("a9d4ee", 0.6), 1.0, 6.0, true)
				if not snap_guide.is_empty():
					if road_snap_enabled and snap_guide["has_reference"] and (preview_waypoints.is_empty() or multi_curve):
						var reference: Vector2 = snap_guide["reference"]
						pen.draw_line(_world_to_screen(guide_origin - reference * 0.12), _world_to_screen(guide_origin), Color("85d4ff"), 3.0, true)
					pen.draw_string(get_theme_default_font(), _world_to_screen(ghost) + Vector2(10, -8), snap_guide["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("d1eaff"))
			if (multi_curve and not awaiting_guide) or (road_draw_mode == RoadRouteBuilder.CURVED and not preview_waypoints.is_empty()):
				var curved: PackedVector2Array
				if preview_start_node<0:
					curved=RoadRouteBuilder.build_player(region,start,ghost,road_tool,preview_waypoints,road_draw_mode)
				else:
					curved=RoadPlanner.multi_curve_preview(region,preview_start_node,preview_waypoints,ghost,road_tool,preview_frozen_route) if multi_curve else RoadPlanner.player_route(region,preview_start_node,ghost,road_tool,preview_waypoints,road_draw_mode)
				if not curved.is_empty():
					points = curved
				elif not multi_curve:
					points.append_array(preview_waypoints)
					points.append(ghost)
			elif not multi_curve:
				points.append(ghost)
		var preview_lanes: int = int(road_preview.get("lanes", 2 if road_tool == "Highway" else 1))
		if road_preview.has("build_plan"):
			for reused in road_preview.build_plan.reused_intervals:
				pen.draw_polyline(_screen_polyline(reused.points),Color("91c9ac",.8),4.0,true)
			for work in road_preview.build_plan.work:
				_draw_dashed_road(pen,_screen_polyline(work.points),preview_lanes,work.road_class,Color("f4dd91"))
			for action in road_preview.build_plan.junction_actions:
				for node in road_preview.build_plan.nodes:
					if node.id==action.node_id: pen.draw_arc(_world_to_screen(node.point),7.0,0,TAU,24,Color("f4dd91"),2.0,true)
		else:
			_draw_dashed_road(pen, _screen_polyline(points), preview_lanes, road_tool, Color("f4dd91"))
		for span in road_preview.get("terrain_impact", {}).get("spans", []):
			var color: Color = Color("8ed6e8") if span["kind"] == "Bridge" else (Color("bd9ee9") if span["kind"] == "Tunnel" else Color("e7b984"))
			pen.draw_polyline(_screen_polyline(span["points"]), color, 5.0, true)
		if road_draw_mode == RoadRouteBuilder.MULTIPOINT and not road_preview.get("ok", false):
			for index in range(preview_waypoints.size()):
				pen.draw_circle(_world_to_screen(preview_waypoints[index]), 4.0, Color("85d4ff") if index % 2 == 0 else Color("f4dd91"))
		for crossing in road_preview.get("crossings", []):
			var screen_point: Vector2 = _world_to_screen(crossing["point"])
			pen.draw_circle(screen_point, 8.0, Color("20354b"))
			pen.draw_string(get_theme_default_font(), screen_point + Vector2(12, 4), "Above" if crossing["above"] else "Below", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("fff0b0"))
	elif road_preview.get("ok", false) and road_preview.get("kind", "") == "Highway exit":
		pen.draw_arc(_world_to_screen(road_preview["position_km"]), 10.0, 0.0, TAU, 24, Color("f4dd91"), 2.0, true)
	elif road_preview.get("ok", false) and road_preview.get("kind", "") == "Demolish":
		for link in region.road_links:
			if link.id == road_preview["target_link_id"]:
				_draw_dashed_road(pen, _screen_polyline(link.points), link.lanes_per_direction, link.road_class, Color("f06464"))


func _draw_road_corridors(pen) -> void:
	for corridor in region.urban_corridors:
		var line: PackedVector2Array = _screen_polyline(corridor["points"])
		if line.size() >= 2 and _screen_visible((line[0] + line[-1]) * 0.5, line[0].distance_to(line[-1]) * 0.5 + 20.0):
			_draw_dashed_polyline(pen, line, Color("ecc679", 0.9), 2.0)


func _draw_transit_overlay(pen) -> void:
	for corridor in region.rail_reservations:
		var line: PackedVector2Array = _screen_polyline(corridor["points"])
		if line.size() >= 2 and _screen_visible((line[0] + line[-1]) * 0.5, line[0].distance_to(line[-1]) * 0.5 + 20.0):
			_draw_dashed_polyline(pen, line, Color("364f73", 0.9), 4.0)
			_draw_dashed_polyline(pen, line, Color("a9d0f2"), 2.0)
	for station in region.station_sites:
		var marker: Vector2 = _world_to_screen(station["point"])
		if _screen_visible(marker, 12.0):
			pen.draw_circle(marker, 7.0, Color("364f73"))
			pen.draw_circle(marker, 4.5, Color("a9d0f2"))
			pen.draw_circle(marker, 1.5, Color("253c55"))


func _draw_grade_crossings(pen) -> void:
	if _map_scale() * view_zoom < 60.0:
		return
	# The over/under resolution scans the whole web per crossing; cache the
	# resolved marks per geometry revision and only project them here.
	for mark in _grade_crossing_marks():
		var center: Vector2 = _world_to_screen(mark["point"])
		if not _screen_visible(center, 30.0):
			continue
		var half_span: float = maxf(9.0, 0.055 * _map_scale() * view_zoom)
		var offset: Vector2 = mark["direction"] * half_span
		var width: float = maxf(6.0, _road_outer_half_width(mark["lanes"], mark["road_class"]) * 2.0)
		pen.draw_line(center - offset, center + offset, Color("101e29"), width + 4.0, true)
		pen.draw_line(center - offset, center + offset, Color("b8cad3"), width, true)


func _link_near_crossing(preferred_id: int, point: Vector2, excluded_id: int):
	for link in region.road_links:
		if link.id == preferred_id and RoadPlanner._point_near_polyline(link.points, point):
			return link
	for link in region.road_links:
		if link.id != excluded_id and RoadPlanner._point_near_polyline(link.points, point):
			return link
	return null


func _draw_road_legend(pen) -> void:
	var font := get_theme_default_font()
	var base := Vector2(18.0, size.y - 16.0)
	pen.draw_rect(Rect2(base - Vector2(9, 95), Vector2(440, 116)), Color(0.04, 0.09, 0.16, 0.90))
	pen.draw_string(font, base + Vector2(0, -76), "ROAD FLOW / CAPACITY + QUEUES" if show_traffic_overlay else "ROAD NETWORK", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("d7e7f1"))
	if show_traffic_overlay:
		for index in range(12):
			pen.draw_rect(Rect2(base + Vector2(index * 18.0, -64), Vector2(17, 9)), _congestion_color(float(index) / 7.0))
		pen.draw_string(font, base + Vector2(0, -39), "clear", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
		pen.draw_string(font, base + Vector2(164, -39), "saturated / queued", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	else:
		pen.draw_string(font, base + Vector2(0, -39), "Traffic overlay off · Use the Traffic button to show flow", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, base + Vector2(0, -17), "One line = one lane  •  Arrows = travel direction" if show_traffic_overlay else "Zoom in for street names, crossings and buildings", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, base + Vector2(0, 4), "Dashed = construction" if road_tool == "Inspect" else "Dashed = construction  •  Gold = interchange  •  Hollow = dormant", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("aebfd0"))


func _draw_zoning_legend(pen) -> void:
	var font := get_theme_default_font()
	var base := Vector2(18.0, size.y - 16.0)
	pen.draw_rect(Rect2(base - Vector2(9, 60), Vector2(440, 81)), Color(0.04, 0.09, 0.16, 0.90))
	pen.draw_string(font, base + Vector2(0, -42), "ZONING · SUGGESTED DISTRICTS", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("d7e7f1"))
	pen.draw_string(font, base + Vector2(0, -17), "Amber dots or outlines = suggested · Green = developed", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, base + Vector2(0, 4), "Zoom toward a city, then click a suggestion to approve", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("aebfd0"))


func _draw_zoning_candidates(pen) -> void:
	var detailed: bool = _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM >= 4.0
	if not detailed:
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) >= 0:
				continue
			var marker: Vector2 = _world_to_screen(candidate["center_km"])
			if not _screen_visible(marker, 8.0):
				continue
			pen.draw_circle(marker, 5.0 if int(candidate["id"]) == selected_candidate_id else 3.5, Color("fff0b0"))
		if selected_candidate_id < 0:
			return
	if region.development_candidates.is_empty():
		return
	var visible_ids: Array[int] = []
	var visible_seen: Dictionary = {}
	if detailed:
		var first: Vector2 = _screen_to_world(view_rect().position - Vector2(30.0, 30.0))
		var last: Vector2 = _screen_to_world(view_rect().end + Vector2(30.0, 30.0))
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for corner in [first, Vector2(last.x, first.y), last, Vector2(first.x, last.y)]:
			var axial: Vector2 = StateGeography.cell_axial_coordinates(corner)
			minimum = minimum.min(axial)
			maximum = maximum.max(axial)
		for grid_y in range(floori(minimum.y) - 2, ceili(maximum.y) + 3):
			for grid_x in range(floori(minimum.x) - 2, ceili(maximum.x) + 3):
				for candidate_id in region.development_candidate_cells.get("%d:%d" % [grid_x, grid_y], []):
					if not visible_seen.has(candidate_id):
						visible_seen[candidate_id] = true
						visible_ids.append(candidate_id)
	else:
		visible_ids.append(selected_candidate_id)
	for candidate_id in visible_ids:
		var candidate: Dictionary = region.development_candidates[candidate_id]
		var id: int = candidate["id"]
		var center: Vector2 = _world_to_screen(candidate["center_km"])
		if not _screen_visible(center, 20.0):
			continue
		var polygon: PackedVector2Array = _screen_polyline(candidate["polygon"])
		if polygon.size() < 3:
			continue
		var neighborhood_id: int = candidate["neighborhood_id"]
		var approved: bool = neighborhood_id >= 0 and region.neighborhoods[neighborhood_id].development_approved
		var color: Color = Color("62c89d") if approved else Color("e4bd70")
		if int(candidate["frontage_link_id"]) < 0:
			color = Color("7d888d")
		color.a = 0.24 if id == selected_candidate_id else (0.18 if neighborhood_id < 0 else 0.10)
		if not Geometry2D.triangulate_polygon(polygon).is_empty():
			pen.draw_colored_polygon(polygon, color)
		polygon.append(polygon[0])
		pen.draw_polyline(polygon, Color("fff0b0") if id == selected_candidate_id else Color(color.r, color.g, color.b, 0.90 if neighborhood_id < 0 else 0.65), 2.5 if id == selected_candidate_id else (1.5 if neighborhood_id < 0 else 1.0), true)
		if id == selected_candidate_id and neighborhood_id < 0:
			var layout = candidate["layout"]
			for edge_id in range(layout.edges.size()):
				var edge: Vector2 = layout.edges[edge_id]
				var path: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]]))
				if path.size() < 2:
					continue
				pen.draw_polyline(_screen_polyline(path), Color("f9d78e", 0.82) if layout.classes[edge_id] == Roads.COLLECTOR else Color("e6eef1", 0.60), 2.2 if layout.classes[edge_id] == Roads.COLLECTOR else 1.2, true)


func _visible_zoning_candidate_at(point: Vector2) -> int:
	if _map_scale() * zoom * StateGeography.CELL_SIZE_KM < 4.0:
		var screen_point: Vector2 = _world_to_screen(point)
		var nearest := 10.0
		var nearest_id := -1
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) >= 0:
				continue
			var distance: float = screen_point.distance_to(_world_to_screen(candidate["center_km"]))
			if distance < nearest:
				nearest = distance
				nearest_id = int(candidate["id"])
		return nearest_id
	var grid: Vector2i = StateGeography.cell_grid_at_point(region.generation_seed, point)
	var built_id := -1
	for offset_y in range(-2, 3):
		for offset_x in range(-2, 3):
			for candidate_id in region.development_candidate_cells.get("%d:%d" % [grid.x + offset_x, grid.y + offset_y], []):
				var candidate: Dictionary = region.development_candidates[candidate_id]
				if not JurisdictionData.polygon_contains_point(point, candidate["polygon"]):
					continue
				if int(candidate["neighborhood_id"]) < 0:
					return candidate_id
				built_id = candidate_id
	return built_id


func _draw_boundaries(pen) -> void:
	var state_polygon: PackedVector2Array = _screen_polyline(region.jurisdictions[0].polygon_km)
	if state_polygon.size() >= 3:
		pen.draw_colored_polygon(state_polygon, Color("c7e9d6"))
		if terrain_texture != null:
			var bounds: Rect2 = region.terrain.bounds
			var base_texture: ImageTexture = terrain_relief_texture if show_terrain_overlay else terrain_texture
			pen.draw_texture_rect(base_texture, Rect2(_world_to_screen(bounds.position), bounds.size * _map_scale() * view_zoom), false)
			if show_slope_overlay and terrain_slope_texture != null:
				pen.draw_texture_rect(terrain_slope_texture, Rect2(_world_to_screen(bounds.position), bounds.size * _map_scale() * view_zoom), false)
			if show_contours and terrain_contour_texture != null:
				pen.draw_texture_rect(terrain_contour_texture, Rect2(_world_to_screen(bounds.position), bounds.size * _map_scale() * view_zoom), false)
			_draw_terrain_detail(pen)
		_draw_terrain_water(pen)
		_draw_polygon_border(pen, region.jurisdictions[0], Color("9eaca2"), 3.0)
	if selected_jurisdiction_id >= 0:
		var selected = region.jurisdictions[selected_jurisdiction_id]
		if selected.kind in ["Region", "County", "City", "Neighborhood"]:
			pen.draw_colored_polygon(_screen_polyline(selected.polygon_km), Color("e5d69a", 0.055))
	_draw_neighborhood_boundaries(pen)
	# Draw the smaller divisions first so the broader borders stay legible where they coincide.
	for kind in ["City", "County", "Region"]:
		if region.is_large_scale and view_zoom < 3.0 and kind == "City":
			continue
		for area in region.jurisdictions:
			if area.kind != kind:
				continue
			if not _jurisdiction_screen_rect(area).intersects(view_rect()):
				continue
			var color: Color = _jurisdiction_color(kind)
			color.a = {"City": 0.46, "County": 0.72, "Region": 0.92}[kind]
			if map_mode != "Zoning":
				color.a = 0.12
			if region.is_large_scale and view_zoom < 2.0:
				color.a = 0.11 if kind == "County" else 0.31
			_draw_polygon_border(pen, area, color, {"City": 1.0, "County": 1.5, "Region": 2.0}[kind])
	if selected_jurisdiction_id >= 0:
		var selected = region.jurisdictions[selected_jurisdiction_id]
		if selected.kind in ["Region", "County", "City", "Neighborhood"]:
			_draw_polygon_border(pen, selected, Color("fff0b0", 0.95), 3.5)


func _needs_terrain_raster() -> bool:
	return show_terrain_overlay or show_slope_overlay or show_contours


func _terrain_tile_ready(key: Vector3i) -> bool:
	return terrain_detail_tiles.has(key) and (not _needs_terrain_raster() or terrain_detail_tiles[key].has("terrain"))


func _draw_terrain_detail(pen) -> void:
	var pixels_per_km: float = _map_scale() * view_zoom
	var level := -1
	if pixels_per_km >= 2.0:
		var target_texel_pixels := 2.0
		if show_terrain_overlay:
			target_texel_pixels = 2.5
		if show_terrain_overlay and pixels_per_km < 20.0:
			target_texel_pixels = 1.5
		for index in range(TERRAIN_DETAIL_STEPS.size()):
			level = index
			if pixels_per_km * TERRAIN_DETAIL_STEPS[index] <= target_texel_pixels:
				break
	if level < 0:
		terrain_detail_visible.clear()
		terrain_detail_level = -1
		terrain_detail_published_level = -1
		terrain_detail_queue.clear()
		terrain_detail_requested.clear()
		return
	if level != terrain_detail_level:
		terrain_detail_level = level
		terrain_detail_published_level = -1
		terrain_detail_queue.clear()
		terrain_detail_requested.clear()
	var terrain = region.terrain
	var step_km: float = TERRAIN_DETAIL_STEPS[level]
	var tile_km: float = step_km * TerrainDetailTile.PIXELS
	var first: Vector2 = _screen_to_world(view_rect().position)
	var last: Vector2 = _screen_to_world(view_rect().end)
	var visible_world: Rect2 = Rect2(first, last - first).intersection(terrain.bounds)
	terrain_detail_visible.clear()
	if not visible_world.has_area():
		return
	var left: int = maxi(0, floori((visible_world.position.x - terrain.bounds.position.x) / tile_km))
	var top: int = maxi(0, floori((visible_world.position.y - terrain.bounds.position.y) / tile_km))
	var right: int = mini(ceili(terrain.bounds.size.x / tile_km) - 1, floori((visible_world.end.x - terrain.bounds.position.x) / tile_km))
	var bottom: int = mini(ceili(terrain.bounds.size.y / tile_km) - 1, floori((visible_world.end.y - terrain.bounds.position.y) / tile_km))
	var missing: Array[Vector3i] = []
	var ready_count := 0
	var tile_count := 0
	for y in range(top, bottom + 1):
		for x in range(left, right + 1):
			var key := Vector3i(level, x, y)
			terrain_detail_visible[key] = true
			tile_count += 1
			if _terrain_tile_ready(key):
				ready_count += 1
			elif not terrain_detail_requested.has(key) and not terrain_detail_active.has(key):
				missing.append(key)
	# Keep the previous view_zoom's tiles until this viewport's new level is ready.
	# After that, short pans may show a small unfinished strip at the edge.
	for fallback_level in range(level):
		if pen != null:
			_draw_cached_terrain_level(pen, terrain, fallback_level, visible_world, pixels_per_km)
	if tile_count > 0 and ready_count == tile_count:
		terrain_detail_published_level = level
	else:
		terrain_detail_published_level = -1
	if ready_count > 0 and pen != null:
		_draw_cached_terrain_level(pen, terrain, level, visible_world, pixels_per_km)
	if not missing.is_empty():
		var center: Vector2 = (visible_world.get_center() - terrain.bounds.position) / tile_km
		missing.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			return Vector2(a.y, a.z).distance_squared_to(center) < Vector2(b.y, b.z).distance_squared_to(center)
		)
		for key in missing:
			terrain_detail_requested[key] = true
			terrain_detail_queue.append(key)
		set_process(true)


func _draw_cached_terrain_level(pen, terrain, level: int, visible_world: Rect2, pixels_per_km: float) -> void:
	var tile_km: float = TERRAIN_DETAIL_STEPS[level] * TerrainDetailTile.PIXELS
	var left: int = maxi(0, floori((visible_world.position.x - terrain.bounds.position.x) / tile_km))
	var top: int = maxi(0, floori((visible_world.position.y - terrain.bounds.position.y) / tile_km))
	var right: int = mini(ceili(terrain.bounds.size.x / tile_km) - 1, floori((visible_world.end.x - terrain.bounds.position.x) / tile_km))
	var bottom: int = mini(ceili(terrain.bounds.size.y / tile_km) - 1, floori((visible_world.end.y - terrain.bounds.position.y) / tile_km))
	for y in range(top, bottom + 1):
		for x in range(left, right + 1):
			var key := Vector3i(level, x, y)
			if not terrain_detail_tiles.has(key):
				continue
			var tile: Dictionary = terrain_detail_tiles[key]
			var origin: Vector2 = terrain.bounds.position + Vector2(x, y) * tile_km
			var screen_rect := Rect2(_world_to_screen(origin), Vector2.ONE * tile_km * pixels_per_km)
			var texture_key: String = "terrain" if show_terrain_overlay else "color"
			if not show_terrain_overlay and tile.get("map_mesh") != null:
				var transform := Transform2D(Vector2(pixels_per_km, 0.0), Vector2(0.0, pixels_per_km), screen_rect.position)
				pen.draw_mesh(tile["map_mesh"], null, transform)
			else:
				pen.draw_texture_rect(tile[texture_key], screen_rect, false)
			if show_slope_overlay:
				pen.draw_texture_rect(tile["slope"], screen_rect, false)
			if show_contours:
				pen.draw_texture_rect(tile["contours"], screen_rect, false)


func _draw_terrain_water(pen) -> void:
	if region.terrain == null:
		return
	var terrain = region.terrain
	for lake in terrain.lakes:
		var center: Vector2 = lake["center"]
		var radius: Vector2 = lake["radius"]
		if minf(radius.x, radius.y) * _map_scale() * view_zoom < 1.0:
			continue
		if not _screen_visible(_world_to_screen(center), radius.length() * 1.25 * _map_scale() * view_zoom):
			continue
		var polygon := PackedVector2Array()
		for point in lake["polygon"]:
			polygon.append(_world_to_screen(point))
		pen.draw_colored_polygon(polygon, Color("79cde2"))
	for river in terrain.rivers:
		if _map_scale() * view_zoom < 2.0 and float(river["width_km"]) < 0.12:
			continue
		var river_bounds: Rect2 = river["bounds"]
		var visible_a: Vector2 = _world_to_screen(river_bounds.position)
		var visible_b: Vector2 = _world_to_screen(river_bounds.end)
		if not Rect2(visible_a, Vector2.ZERO).expand(visible_b).intersects(view_rect()):
			continue
		var line: PackedVector2Array = river["points"]
		var widths: PackedFloat32Array = river.get("widths_km", PackedFloat32Array())
		var water_color: Color = Color("6cc2dc")
		for i in range(1, line.size()):
			var a: Vector2 = _world_to_screen(line[i - 1])
			var b: Vector2 = _world_to_screen(line[i])
			if not Rect2(a, Vector2.ZERO).expand(b).grow(10.0).intersects(view_rect()):
				continue
			var width_km: float = (widths[i - 1] + widths[i]) * 0.5 if widths.size() == line.size() else float(river["width_km"])
			var screen_width: float = maxf(1.0, width_km * _map_scale() * view_zoom)
			pen.draw_line(a, b, water_color, screen_width, true)
			if screen_width >= 3.0:
				pen.draw_circle(b, screen_width * 0.5, water_color, true, -1.0, true)


func _neighborhood_borders_visible(city) -> bool:
	if region.is_large_scale and (view_zoom < 3.0 or _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM < 12.0):
		return false
	var bounds: Rect2 = _jurisdiction_screen_rect(city)
	if not bounds.intersects(view_rect()):
		return false
	var parcel_extent: float = sqrt(bounds.get_area() / float(maxi(1, city.neighborhood_ids.size())))
	return maxf(bounds.size.x, bounds.size.y) >= 55.0 and parcel_extent >= 16.0


func _draw_neighborhood_boundaries(pen) -> void:
	last_drawn_neighborhood_borders = 0
	for city_id in region.city_jurisdiction_ids:
		var city = region.jurisdictions[city_id]
		if not _neighborhood_borders_visible(city):
			continue
		for neighborhood_id in city.neighborhood_ids:
			var neighborhood = region.neighborhoods[neighborhood_id]
			if neighborhood.street_layout == null:
				continue
			var district = region.jurisdictions[neighborhood.jurisdiction_id]
			if not _jurisdiction_screen_rect(district).intersects(view_rect()):
				continue
			var inhabited: bool = neighborhood.population > 0 or neighborhood.jobs > 0
			var color: Color = CITY_COLORS[neighborhood.city_id % CITY_COLORS.size()]
			color.a = 0.18 if inhabited else 0.035 + float(neighborhood_id % 3) * 0.015
			var layout_id: int = neighborhood.street_layout.get_instance_id()
			if not district_fill_meshes.has(layout_id):
				if district_fill_meshes.size() > 1024:
					for old_id in district_fill_meshes.keys().slice(0, 128):
						district_fill_meshes.erase(old_id)
				var vertices := PackedVector2Array()
				for vertex_id in StreetLayoutOps.triangulate(district.polygon_km):
					vertices.append(district.polygon_km[vertex_id] - district.bounds_km.position)
				var mesh: ArrayMesh
				if not vertices.is_empty():
					var arrays: Array = []
					arrays.resize(Mesh.ARRAY_MAX)
					arrays[Mesh.ARRAY_VERTEX] = vertices
					mesh = ArrayMesh.new()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				district_fill_meshes[layout_id] = mesh
			var cached_mesh: ArrayMesh = district_fill_meshes[layout_id]
			if cached_mesh != null:
				var world_scale: float = _map_scale() * view_zoom
				var transform := Transform2D(Vector2(world_scale, 0.0), Vector2(0.0, world_scale), _world_to_screen(district.bounds_km.position))
				pen.draw_mesh(cached_mesh, null, transform, color)
			_draw_polygon_border(pen, district, Color("c1d0b3", 0.65 if inhabited else 0.34), 1.0)
			last_drawn_neighborhood_borders += 1


func _draw_polygon_border(pen, area, color: Color, width: float) -> void:
	var points: PackedVector2Array = _screen_polyline(area.polygon_km)
	if points.size() < 3:
		return
	points.append(points[0])
	pen.draw_polyline(points, color, width, true)


func _jurisdiction_screen_rect(area) -> Rect2:
	var upper_left: Vector2 = _world_to_screen(area.bounds_km.position)
	return Rect2(upper_left, _world_to_screen(area.bounds_km.end) - upper_left)


func _jurisdiction_color(kind: String) -> Color:
	match kind:
		"Region":
			return Color("63c6e5")
		"County":
			return Color("e4be75")
		"Neighborhood":
			return Color("c1d0b3")
		_:
			return Color("b5a9e8")


func _jurisdiction_label_text(area) -> String:
	if area.kind == "City":
		return area.name
	var space: float = _jurisdiction_screen_rect(area).size.x
	if area.kind == "City" and region.city_development_state(area.id) != "Dormant":
		space = maxf(space, 140.0)
	var label: String
	match area.kind:
		"Region":
			label = ("REGION · " if space >= 200.0 else "") + area.name.to_upper()
		"County":
			label = ("COUNTY · " + area.name.to_upper()) if space >= 150.0 else area.name.trim_suffix(" County").to_upper()
		_:
			label = ("CITY · " if space >= 140.0 else "") + area.name.to_upper()
	if area.name.to_upper().begins_with(area.kind.to_upper()):
		label = area.name.to_upper()
	var font := get_theme_default_font()
	var font_size := 11 if area.kind == "Region" else (10 if area.kind == "County" else 9)
	var available: float = maxf(20.0, minf(180.0, space - 6.0)) - 8.0
	while label.length() > 1 and font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > available:
		label = label.substr(0, label.length() - 2) + "…"
	return label


func _jurisdiction_label_rect(area) -> Rect2:
	_ensure_jurisdiction_labels()
	var entry: Dictionary = jurisdiction_label_rects.get(area.id, {})
	if entry.is_empty():
		return Rect2()
	return Rect2(_world_to_screen(entry["anchor"]) + entry["offset"], entry["size"])


func _jurisdiction_label_visible(area) -> bool:
	return _jurisdiction_label_eligible(area) and _jurisdiction_label_rect(area).has_area()


func _jurisdiction_label_eligible(area) -> bool:
	if area.kind not in ["Region", "County", "City"]:
		return false
	if not _jurisdiction_screen_rect(area).intersects(Rect2(Vector2.ZERO, size)):
		return false
	if region.is_large_scale and area.id != selected_jurisdiction_id:
		if area.kind == "County" and zoom < 2.0:
			return false
		if area.kind == "City" and zoom < 4.0 and region.city_development_state(area.id) == "Dormant":
			return false
	if region.is_large_scale and zoom < 4.0:
		if detail_level == "State" and area.kind != "Region":
			return false
		if detail_level == "Region" and area.kind == "City":
			return false
	return _jurisdiction_screen_rect(area).size.x >= 35.0 or (area.kind == "City" and region.city_development_state(area.id) != "Dormant")


func _ensure_jurisdiction_labels() -> void:
	# Cache world-space anchors within zoom bands and 256-pixel pan cells.
	# Recompute when new areas enter view, not on every navigation frame.
	var band := _zoom_band()
	var key: String = "%d:%s:%d:%s:%d:%s:%d" % [region.generation_seed, size, band, detail_level, selected_jurisdiction_id, Vector2i(pan / 256.0), region.current_day_key]
	if key == jurisdiction_layout_key:
		return
	jurisdiction_layout_key = key
	jurisdiction_label_rects.clear()
	var ordered: Array = []
	if selected_jurisdiction_id >= 0 and _jurisdiction_label_eligible(region.jurisdictions[selected_jurisdiction_id]):
		ordered.append(region.jurisdictions[selected_jurisdiction_id])
	for kind in ["Region", "County", "City"]:
		for area in region.jurisdictions:
			if area.kind == kind and area.id != selected_jurisdiction_id and _jurisdiction_label_eligible(area):
				ordered.append(area)
	var city_label_points: Dictionary = {}
	for city in region.cities:
		city_label_points[city["jurisdiction_id"]] = city["center_km"]
	var occupied: Array[Rect2] = []
	var font := get_theme_default_font()
	var band_scale: float = _map_scale() * _band_zoom(band)
	for area in ordered:
		var font_size := 13 if area.kind == "City" else (11 if area.kind == "Region" else (10 if area.kind == "County" else 9))
		var width: float = maxf(20.0, font.get_string_size(_jurisdiction_label_text(area), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0)
		var anchor: Vector2 = city_label_points.get(area.id, area.center_km)
		var center: Vector2 = size * 0.5 + pan + (anchor - _world_center()) * band_scale
		var top: float = -30.0 if area.kind == "City" else (8.0 if area.kind == "County" else -12.0)
		for offset in [Vector2.ZERO, Vector2(0, -20), Vector2(0, 20), Vector2(0, -40), Vector2(0, 40), Vector2(-30, 0), Vector2(30, 0)]:
			var candidate := Rect2(center + Vector2(-width * 0.5, top) + offset, Vector2(width, 14.0 if area.kind == "City" else 18.0))
			if not Rect2(Vector2(4, 4), size - Vector2(8, 8)).encloses(candidate):
				continue
			var overlaps := false
			for prior in occupied:
				if candidate.grow(2.0).intersects(prior):
					overlaps = true
					break
			if not overlaps:
				jurisdiction_label_rects[area.id] = {"anchor": anchor, "offset": candidate.position - center, "size": candidate.size}
				occupied.append(candidate)
				break


func _draw_jurisdiction_labels(pen) -> void:
	var font := get_theme_default_font()
	for kind in ["Region", "County", "City"]:
		if region.is_large_scale and detail_level == "State" and view_zoom < 4.0 and kind != "Region":
			continue
		if region.is_large_scale and detail_level == "Region" and view_zoom < 4.0 and kind == "City":
			continue
		for area_id in jurisdiction_label_rects:
			var area = region.jurisdictions[area_id]
			if area.kind != kind:
				continue
			if not _jurisdiction_label_rect(area).intersects(Rect2(Vector2.ZERO, size)):
				continue
			var rect: Rect2 = _jurisdiction_label_rect(area)
			var color: Color = _jurisdiction_color(kind)
			var selected: bool = area.id == selected_jurisdiction_id
			if kind == "City":
				var position: Vector2 = rect.position + Vector2(4.0, 12.0)
				pen.draw_string_outline(font, position, area.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color("f5f6ef"))
				pen.draw_string(font, position, area.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("4b5b60"))
				continue
			pen.draw_rect(rect, Color("0b1927", 0.82 if kind == "City" else 0.94))
			pen.draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)), Color("fff0b0") if selected else color)
			if selected:
				pen.draw_rect(rect, Color("fff0b0"), false, 1.0)
			var label: String = _jurisdiction_label_text(area)
			var font_size := 11 if kind == "Region" else (10 if kind == "County" else 9)
			while label.length() > 2 and font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > rect.size.x - 8.0:
				label = label.substr(0, label.length() - 2) + "…"
			pen.draw_string(font, rect.position + Vector2(6.0, 10.0 if kind == "City" else 13.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("fff0b0") if selected else color)


func _draw_jurisdiction_key(pen) -> void:
	var font := get_theme_default_font()
	var start := Vector2(size.x - 362.0, 42.0 if size.x < 720.0 else 10.0)
	pen.draw_rect(Rect2(start, Vector2(352.0, 25.0)), Color("0b1927", 0.94))
	for item in [
		{"kind": "Region", "label": "Region", "offset": 9.0},
		{"kind": "County", "label": "County", "offset": 85.0},
		{"kind": "City", "label": "City", "offset": 165.0},
		{"kind": "Neighborhood", "label": "Neighborhood", "offset": 220.0},
	]:
		var x: float = start.x + item["offset"]
		var color: Color = _jurisdiction_color(item["kind"])
		pen.draw_line(Vector2(x, start.y + 13.0), Vector2(x + 12.0, start.y + 13.0), color, 3.0, true)
		pen.draw_string(font, Vector2(x + 17.0, start.y + 17.0), item["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)


func _is_recorded_time() -> bool:
	var requested_bin: int = selected_hour * 4 + floori(hour_fraction * 4.0)
	return requested_bin >= first_recorded_bin and requested_bin < recorded_bin


func _draw_cities(pen) -> void:
	if map_mode != "Zoning":
		return
	for city in region.cities:
		var area = region.jurisdictions[city["jurisdiction_id"]]
		var bounds: Rect2 = _jurisdiction_screen_rect(area)
		if not bounds.intersects(view_rect()):
			continue
		var color: Color = CITY_COLORS[int(city["id"]) % CITY_COLORS.size()]
		if maxf(bounds.size.x, bounds.size.y) >= 8.0:
			color.a = 0.035
			pen.draw_colored_polygon(_screen_polyline(area.polygon_km), color)


func _circle_mesh(inner_radius: float) -> ArrayMesh:
	var vertices := PackedVector2Array()
	for segment in range(32):
		var first: Vector2 = Vector2.from_angle(float(segment) * TAU / 32.0)
		var second: Vector2 = Vector2.from_angle(float(segment + 1) * TAU / 32.0)
		if inner_radius <= 0.0:
			vertices.append(Vector2.ZERO)
			vertices.append(first)
			vertices.append(second)
		else:
			vertices.append(first)
			vertices.append(second)
			vertices.append(first * inner_radius)
			vertices.append(second)
			vertices.append(second * inner_radius)
			vertices.append(first * inner_radius)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _ensure_neighborhood_batches(count: int) -> void:
	if neighborhood_batches.is_empty():
		var disc: ArrayMesh = _circle_mesh(0.0)
		var thin_ring: ArrayMesh = _circle_mesh(0.92)
		var thick_ring: ArrayMesh = _circle_mesh(0.85)
		for mesh in [disc, disc, thin_ring, thick_ring]:
			var batch := MultiMesh.new()
			batch.transform_format = MultiMesh.TRANSFORM_2D
			batch.use_colors = true
			batch.mesh = mesh
			batch.instance_count = maxi(512, count)
			neighborhood_batches.append(batch)
	if count > neighborhood_batches[0].instance_count:
		for batch in neighborhood_batches:
			batch.instance_count = count


func _set_neighborhood_batch(batch: MultiMesh, index: int, center: Vector2, radius: float, color: Color) -> void:
	batch.set_instance_transform_2d(index, Transform2D(Vector2(radius, 0.0), Vector2(0.0, radius), center))
	batch.set_instance_color(index, color)


func _draw_neighborhoods(pen) -> void:
	if region.is_large_scale and _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM < 8.0:
		return
	var neighborhood_indices: Array[int] = _spatial_visible_indices(spatial_neighborhoods, 25.0) if region.is_large_scale and view_zoom >= 2.0 else _all_indices(region.neighborhoods.size())
	if detail_level != "Neighborhood":
		if region.is_large_scale and detail_level in ["State", "Region"]:
			return
		for neighborhood_index in neighborhood_indices:
			var neighborhood = region.neighborhoods[neighborhood_index]
			if neighborhood.street_layout == null:
				continue
			var point: Vector2 = _world_to_screen(neighborhood.position_km)
			if _screen_visible(point, 3.0) and (not region.is_large_scale or view_zoom >= 2.0):
				pen.draw_circle(point, 2.5, Color("718899", 0.45))
		return
	if region.accessibility.is_empty():
		return
	var min_access: float = region.accessibility[0]
	var max_access: float = min_access
	for value in region.accessibility:
		min_access = minf(min_access, value)
		max_access = maxf(max_access, value)
	var visible_count := 0
	for neighborhood_index in neighborhood_indices:
		var neighborhood = region.neighborhoods[neighborhood_index]
		if neighborhood.street_layout == null:
			continue
		if _screen_visible(_world_to_screen(neighborhood.position_km), 15.0):
			visible_count += 1
	var detail_limit: float = 256.0 if zoom < 3.0 else 512.0
	var stride: int = maxi(1, ceili(float(visible_count) / detail_limit)) if region.is_large_scale else 1
	var batch_nodes: bool = region.is_large_scale and zoom >= 2.0
	var batch_count: int = 0
	if batch_nodes:
		_ensure_neighborhood_batches(mini(visible_count + 2, 1024))
	for neighborhood_index in neighborhood_indices:
		var neighborhood = region.neighborhoods[neighborhood_index]
		if neighborhood.street_layout == null:
			continue
		var screen_position: Vector2 = _world_to_screen(neighborhood.position_km)
		if neighborhood.street_layout != null and _pixels_per_meter() >= 0.04:
			continue
		if not _screen_visible(screen_position, 15.0) or (neighborhood.id % stride != 0 and not neighborhood.initially_developed and neighborhood.id != selected_id and neighborhood.id != hovered_id):
			continue
		var radius: float = _node_radius(neighborhood.population)
		if neighborhood.development_state == "Dormant":
			if region.is_large_scale and zoom < 2.0 and neighborhood.id != selected_id and neighborhood.id != hovered_id:
				continue
			pen.draw_arc(screen_position, 3.0, 0.0, TAU, 12, Color("82938e", 0.65), 1.0, true)
			if neighborhood.id == selected_id or neighborhood.id == hovered_id:
				pen.draw_arc(screen_position, 7.0, 0.0, TAU, 16, Color("f5d482"), 1.5, true)
			continue
		var color := _access_color((region.accessibility[neighborhood.id] - min_access) / maxf(1.0, max_access - min_access))
		var desirability_color := Color("cf6075").lerp(Color("61c99a"), neighborhood.desirability / 100.0)
		if batch_nodes:
			_set_neighborhood_batch(neighborhood_batches[0], batch_count, screen_position, radius + 3.0, Color("0b1421"))
			_set_neighborhood_batch(neighborhood_batches[1], batch_count, screen_position, radius, color)
			_set_neighborhood_batch(neighborhood_batches[2], batch_count, screen_position, radius + 0.5, Color(1, 1, 1, 0.42))
			_set_neighborhood_batch(neighborhood_batches[3], batch_count, screen_position, radius + 2.5, desirability_color)
			batch_count += 1
		else:
			pen.draw_circle(screen_position, radius + 3.0, Color("0b1421"))
			pen.draw_circle(screen_position, radius, color)
			pen.draw_arc(screen_position, radius, 0.0, TAU, 32, Color(1, 1, 1, 0.42), 1.0, true)
			pen.draw_arc(screen_position, radius + 2.0, 0.0, TAU, 32, desirability_color, 2.0, true)
			if neighborhood.id == selected_id:
				pen.draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("ffffff"), 2.5, true)
			elif neighborhood.id == hovered_id:
				pen.draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("a9d7ff"), 2.0, true)
	if batch_nodes:
		for batch in neighborhood_batches:
			batch.visible_instance_count = batch_count
			if batch_count > 0:
				pen.draw_multimesh(batch, null)
		for highlighted_id in [selected_id, hovered_id]:
			if highlighted_id < 0:
				continue
			var highlighted = region.neighborhoods[highlighted_id]
			var center: Vector2 = _world_to_screen(highlighted.position_km)
			if _screen_visible(center, 20.0):
				pen.draw_arc(center, _node_radius(highlighted.population) + 5.0, 0.0, TAU, 48, Color("ffffff") if highlighted_id == selected_id else Color("a9d7ff"), 2.5 if highlighted_id == selected_id else 2.0, true)
	var label_order: Array[int] = []
	if selected_id >= 0:
		label_order.append(selected_id)
	if hovered_id >= 0 and hovered_id != selected_id:
		label_order.append(hovered_id)
	if view_zoom >= 1.8 and _pixels_per_meter() >= 0.15 and (not region.is_large_scale or _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM >= 20.0):
		for neighborhood_index in neighborhood_indices:
			var neighborhood = region.neighborhoods[neighborhood_index]
			if neighborhood.id != selected_id and neighborhood.id != hovered_id and _screen_visible(_world_to_screen(neighborhood.position_km), 25.0) and neighborhood.id % stride == 0:
				label_order.append(neighborhood.id)
	var font := get_theme_default_font()
	var label_boxes: Array[Rect2] = []
	for neighborhood_id in label_order:
		var neighborhood = region.neighborhoods[neighborhood_id]
		var screen_position: Vector2 = _world_to_screen(neighborhood.position_km)
		var label_position: Vector2 = screen_position + Vector2(_node_radius(neighborhood.population) + 7.0, 4.0)
		var label_width: float = font.get_string_size(neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var label_box := Rect2(label_position + Vector2(0.0, -13.0), Vector2(label_width, 16.0))
		if neighborhood_id != selected_id and neighborhood_id != hovered_id:
			var overlaps := false
			for placed_box in label_boxes:
				if label_box.intersects(placed_box):
					overlaps = true
					break
			if overlaps:
				continue
		label_boxes.append(label_box)
		pen.draw_string(font, label_position + Vector2(1.0, 1.0), neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("07111e"))
		pen.draw_string(font, label_position, neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e8f0f7"))


func _draw_hourly_flows(pen) -> void:
	if region.is_large_scale and detail_level == "Neighborhood":
		_draw_compact_city_flows(pen)
		return
	if detail_level != "Neighborhood":
		_draw_aggregate_flows(pen)
		return
	if flow_profile == null:
		return
	var visible_flows: Array[Dictionary] = _get_net_flows()
	visible_flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	if visible_flows.is_empty():
		return
	var strongest: float = flow_profile.peak_net_trips_by_purpose.get(selected_purpose, 1.0)
	var drawn_flows: Array[Dictionary] = _choose_flows_for_display(visible_flows)
	drawn_flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] < b["trips"])
	for flow in drawn_flows:
		var origin = region.neighborhoods[flow["origin"]]
		var destination = region.neighborhoods[flow["destination"]]
		var start_point: Vector2 = _world_to_screen(origin.position_km)
		var end_point: Vector2 = _world_to_screen(destination.position_km)
		var direction: Vector2 = (end_point - start_point).normalized()
		if direction == Vector2.ZERO:
			continue
		var lane_offset: float = _flow_lane_offset(flow)
		var pair_start: Vector2 = _world_to_screen(region.neighborhoods[mini(flow["origin"], flow["destination"])].position_km)
		var pair_end: Vector2 = _world_to_screen(region.neighborhoods[maxi(flow["origin"], flow["destination"])].position_km)
		var pair_direction: Vector2 = (pair_end - pair_start).normalized()
		var side_offset := Vector2(-pair_direction.y, pair_direction.x) * lane_offset
		start_point += side_offset
		end_point += side_offset
		start_point += direction * (_node_radius(origin.population) + 2.0)
		end_point -= direction * (_node_radius(destination.population) + 5.0)
		var strength: float = clampf(sqrt(float(flow["trips"]) / strongest), 0.0, 1.0)
		var flow_color: Color = _purpose_color(flow["purpose"])
		if flow["origin"] == selected_id or flow["destination"] == selected_id:
			flow_color.a = 0.37 + 0.58 * strength
		else:
			flow_color.a = 0.18 + 0.49 * strength if selected_id < 0 else 0.12 + 0.35 * strength
		var line_width: float = 1.0 + 5.0 * strength
		_draw_flow_stroke(pen, start_point, end_point, flow_color, line_width, _is_outgoing_from_selected(flow))
		var arrow_tip: Vector2 = end_point
		var arrow_base: Vector2 = end_point - direction * (6.0 + 5.0 * strength)
		var side: Vector2 = Vector2(-direction.y, direction.x) * (3.0 + 2.0 * strength)
		pen.draw_colored_polygon(PackedVector2Array([arrow_tip, arrow_base + side, arrow_base - side]), flow_color)


func _draw_compact_city_flows(pen) -> void:
	if flow_profile == null:
		return
	if view_zoom < 2.0:
		_draw_compact_region_flows(pen)
		return
	var purposes: Array = [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL] if selected_purpose == FlowProfile.ALL else [selected_purpose]
	var flows: Array[Dictionary] = []
	var next_profile = next_day_profile if selected_hour == 23 and next_day_profile != null else flow_profile
	var next_hour: int = (selected_hour + 1) % 24
	for purpose in purposes:
		for from_city in range(region.cities.size()):
			if not _screen_visible(_world_to_screen(region.cities[from_city]["center_km"]), 30.0):
				continue
			for to_city in range(region.cities.size()):
				if from_city == to_city or not _screen_visible(_world_to_screen(region.cities[to_city]["center_km"]), 30.0):
					continue
				var current: float = flow_profile._compact_city_hour_pair(from_city, to_city, selected_hour, purpose)
				var following: float = next_profile._compact_city_hour_pair(from_city, to_city, next_hour, purpose)
				var trips: float = lerpf(current, following, hour_fraction)
				if purpose != FlowProfile.SOCIAL:
					trips -= lerpf(flow_profile._compact_city_hour_pair(to_city, from_city, selected_hour, purpose), next_profile._compact_city_hour_pair(to_city, from_city, next_hour, purpose), hour_fraction)
				if trips > 0.1:
					flows.append({"from": from_city, "to": to_city, "purpose": purpose, "trips": trips})
	flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	var peak: float = float(flows[0]["trips"]) if not flows.is_empty() else 1.0
	for index in range(mini(40, flows.size())):
		var flow: Dictionary = flows[index]
		var start_point: Vector2 = _world_to_screen(region.cities[flow["from"]]["center_km"])
		var end_point: Vector2 = _world_to_screen(region.cities[flow["to"]]["center_km"])
		var direction: Vector2 = (end_point - start_point).normalized()
		var strength: float = sqrt(float(flow["trips"]) / maxf(1.0, peak))
		var color: Color = _purpose_color(flow["purpose"])
		color.a = 0.2 + 0.65 * strength
		_draw_flow_stroke(pen, start_point + direction * 5.0, end_point - direction * 8.0, color, 1.0 + 5.0 * strength, selected_id >= 0 and region.neighborhoods[selected_id].city_id == flow["from"])
		var side: Vector2 = direction.orthogonal() * (2.0 + 2.0 * strength)
		pen.draw_colored_polygon(PackedVector2Array([end_point, end_point - direction * 10.0 + side, end_point - direction * 10.0 - side]), color)


func _draw_compact_region_flows(pen) -> void:
	var purposes: Array = [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL] if selected_purpose == FlowProfile.ALL else [selected_purpose]
	var next_profile = next_day_profile if selected_hour == 23 and next_day_profile != null else flow_profile
	var next_hour: int = (selected_hour + 1) % 24
	var flows: Array[Dictionary] = []
	for purpose in purposes:
		for from_region in range(region.region_ids.size()):
			for to_region in range(region.region_ids.size()):
				if from_region == to_region:
					continue
				var trips: float = lerpf(flow_profile._compact_region_hour_pair(from_region, to_region, selected_hour, purpose), next_profile._compact_region_hour_pair(from_region, to_region, next_hour, purpose), hour_fraction)
				if purpose != FlowProfile.SOCIAL:
					trips -= lerpf(flow_profile._compact_region_hour_pair(to_region, from_region, selected_hour, purpose), next_profile._compact_region_hour_pair(to_region, from_region, next_hour, purpose), hour_fraction)
				if trips > 0.1:
					flows.append({"from": from_region, "to": to_region, "purpose": purpose, "trips": trips})
	flows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["trips"] > b["trips"])
	var peak: float = float(flows[0]["trips"]) if not flows.is_empty() else 1.0
	for index in range(mini(30, flows.size())):
		var flow: Dictionary = flows[index]
		var start_point: Vector2 = _world_to_screen(region.jurisdictions[region.region_ids[flow["from"]]].center_km)
		var end_point: Vector2 = _world_to_screen(region.jurisdictions[region.region_ids[flow["to"]]].center_km)
		var direction: Vector2 = (end_point - start_point).normalized()
		var strength: float = sqrt(float(flow["trips"]) / maxf(1.0, peak))
		var color: Color = _purpose_color(flow["purpose"])
		color.a = 0.2 + 0.65 * strength
		_draw_flow_stroke(pen, start_point + direction * 12.0, end_point - direction * 12.0, color, 1.0 + 5.0 * strength, false)
		var side: Vector2 = direction.orthogonal() * (2.0 + 2.0 * strength)
		pen.draw_colored_polygon(PackedVector2Array([end_point, end_point - direction * 10.0 + side, end_point - direction * 10.0 - side]), color)


func _purpose_color(purpose: String) -> Color:
	match purpose:
		FlowProfile.WORK:
			return Color("6cc6d5")
		FlowProfile.COMMERCIAL:
			return Color("d49bdf")
		_:
			return Color("f2b678")


func _flow_lane_offset(flow: Dictionary) -> float:
	var lane := 0.0
	if selected_purpose == FlowProfile.ALL:
		match flow["purpose"]:
			FlowProfile.WORK:
				lane = -7.0
			FlowProfile.SOCIAL:
				lane = 7.0
	if flow["purpose"] == FlowProfile.SOCIAL:
		var direction_offset := -3.0 if flow["origin"] < flow["destination"] else 3.0
		if selected_purpose != FlowProfile.ALL:
			direction_offset *= 4.0 / 3.0
		lane += direction_offset
	return lane


func _is_outgoing_from_selected(flow: Dictionary) -> bool:
	return selected_id >= 0 and flow["origin"] == selected_id


func _draw_flow_stroke(pen, start_point: Vector2, end_point: Vector2, color: Color, width: float, dashed: bool) -> void:
	if not dashed:
		pen.draw_line(start_point, end_point, color, width, true)
		return
	var displacement: Vector2 = end_point - start_point
	var length: float = displacement.length()
	if length <= 0.0:
		return
	var direction: Vector2 = displacement / length
	if not Rect2(start_point, Vector2.ZERO).expand(end_point).grow(width).intersects(view_rect()):
		return
	var visible_offsets: Vector2 = _visible_segment_offsets(start_point, direction, length, width)
	var dash_length: float = maxf(10.0, width * 1.5)
	var dash_period: float = dash_length + maxf(6.0, width * 0.6)
	var offset: float = floorf(visible_offsets.x / dash_period) * dash_period
	while offset < visible_offsets.y:
		var dash_end: float = minf(offset + dash_length, length)
		pen.draw_line(start_point + direction * offset, start_point + direction * dash_end, color, width, true)
		offset += dash_period


func _choose_flows_for_display(visible_flows: Array[Dictionary]) -> Array[Dictionary]:
	if selected_purpose == FlowProfile.ALL:
		return _choose_all_flows(visible_flows)
	var drawn_flows: Array[Dictionary] = []
	var included_pairs: Dictionary = {}
	var flow_limit := 30
	var selected_limit := 12
	var social_extra_routes := 0
	if selected_purpose == "Social":
		var day_peak := 1.0
		for hourly_trips in flow_profile.hourly_social_trips:
			day_peak = maxf(day_peak, hourly_trips)
		var current_trips: float = flow_profile.get_interpolated_hourly_total(selected_hour, hour_fraction, "Social", next_day_profile)
		social_extra_routes = clampi(roundi(5.0 + 18.0 * sqrt(current_trips / day_peak)), 5, 23)
		selected_limit = 6
	if selected_id >= 0:
		for flow in visible_flows:
			if flow["origin"] != selected_id and flow["destination"] != selected_id:
				continue
			drawn_flows.append(flow)
			included_pairs[flow["pair_key"]] = true
			if drawn_flows.size() == selected_limit:
				break
	if selected_purpose == "Social":
		for neighborhood in region.neighborhoods:
			if neighborhood.population <= 0:
				continue
			var already_covered := false
			for flow in drawn_flows:
				if flow["origin"] == neighborhood.id or flow["destination"] == neighborhood.id:
					already_covered = true
					break
			if already_covered:
				continue
			for flow in visible_flows:
				if flow["origin"] != neighborhood.id and flow["destination"] != neighborhood.id:
					continue
				if included_pairs.has(flow["pair_key"]):
					continue
				drawn_flows.append(flow)
				included_pairs[flow["pair_key"]] = true
				break
		flow_limit = drawn_flows.size() + social_extra_routes
	for flow in visible_flows:
		if drawn_flows.size() >= flow_limit:
			break
		if included_pairs.has(flow["pair_key"]):
			continue
		drawn_flows.append(flow)
		included_pairs[flow["pair_key"]] = true
	return drawn_flows


func _choose_all_flows(visible_flows: Array[Dictionary]) -> Array[Dictionary]:
	var drawn_flows: Array[Dictionary] = []
	var included_pairs: Dictionary = {}
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		var selected_count := 0
		for flow in visible_flows:
			if flow["purpose"] != purpose or selected_id < 0:
				continue
			if flow["origin"] != selected_id and flow["destination"] != selected_id:
				continue
			drawn_flows.append(flow)
			included_pairs[flow["pair_key"]] = true
			selected_count += 1
			if selected_count >= 4:
				break
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		var purpose_count := 0
		for flow in drawn_flows:
			if flow["purpose"] == purpose:
				purpose_count += 1
		for flow in visible_flows:
			if purpose_count >= 9:
				break
			if flow["purpose"] != purpose or included_pairs.has(flow["pair_key"]):
				continue
			drawn_flows.append(flow)
			included_pairs[flow["pair_key"]] = true
			purpose_count += 1
	for flow in visible_flows:
		if drawn_flows.size() >= 30:
			break
		if included_pairs.has(flow["pair_key"]):
			continue
		drawn_flows.append(flow)
		included_pairs[flow["pair_key"]] = true
	return drawn_flows


func _get_net_flows() -> Array[Dictionary]:
	var net_flows: Array[Dictionary] = []
	if flow_profile == null or region == null:
		return net_flows
	if selected_purpose == FlowProfile.ALL:
		for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
			net_flows.append_array(_flows_for_purpose(purpose))
	else:
		net_flows = _flows_for_purpose(selected_purpose)
	return net_flows


func _flows_for_purpose(purpose: String) -> Array[Dictionary]:
	var net_flows: Array[Dictionary] = []
	var current_matrix: Array = flow_profile.get_hour_matrix(selected_hour, purpose)
	var next_profile = next_day_profile if selected_hour == 23 and next_day_profile != null else flow_profile
	var next_matrix: Array = next_profile.get_hour_matrix(0 if selected_hour == 23 else selected_hour + 1, purpose)
	var count: int = region.neighborhoods.size()
	for first_id in range(count):
		for second_id in range(first_id + 1, count):
			if purpose == FlowProfile.SOCIAL:
				for endpoints in [[first_id, second_id], [second_id, first_id]]:
					var trips: float = lerpf(current_matrix[endpoints[0]][endpoints[1]], next_matrix[endpoints[0]][endpoints[1]], hour_fraction)
					if trips < MIN_VISIBLE_SOCIAL_TRIPS:
						continue
					net_flows.append({
						"purpose": purpose,
						"origin": endpoints[0],
						"destination": endpoints[1],
						"trips": trips,
						"pair_key": "%s:%d:%d" % [purpose, first_id * count + second_id, int(endpoints[0] == second_id)],
					})
				continue
			var current_net: float = current_matrix[first_id][second_id] - current_matrix[second_id][first_id]
			var next_net: float = next_matrix[first_id][second_id] - next_matrix[second_id][first_id]
			var net_trips: float = lerpf(current_net, next_net, hour_fraction)
			if absf(net_trips) < 1.0:
				continue
			net_flows.append({
				"purpose": purpose,
				"origin": first_id if net_trips > 0.0 else second_id,
				"destination": second_id if net_trips > 0.0 else first_id,
				"trips": absf(net_trips),
				"pair_key": "%s:%d" % [purpose, first_id * count + second_id],
			})
	return net_flows


func _draw_legend(pen) -> void:
	var origin := Vector2(18, size.y - 44)
	pen.draw_rect(Rect2(origin - Vector2(9, 110), Vector2(420, 139)), Color(0.04, 0.09, 0.16, 0.90))
	var font := get_theme_default_font()
	for item in [
		{"purpose": FlowProfile.WORK, "label": "Work", "x": 0.0},
		{"purpose": FlowProfile.COMMERCIAL, "label": "Commercial", "x": 87.0},
		{"purpose": FlowProfile.SOCIAL, "label": "Social", "x": 230.0},
	]:
		var x: float = item["x"]
		var swatch_color: Color = _purpose_color(item["purpose"])
		if selected_purpose != FlowProfile.ALL and selected_purpose != item["purpose"]:
			swatch_color.a = 0.35
		pen.draw_line(origin + Vector2(x, -84), origin + Vector2(x + 15.0, -84), swatch_color, 3.0, true)
		pen.draw_string(font, origin + Vector2(x + 21.0, -80), item["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	if selected_id >= 0:
		_draw_flow_stroke(pen, origin + Vector2(0, -62), origin + Vector2(28, -62), Color("dce8f2"), 2.0, true)
		pen.draw_string(font, origin + Vector2(35, -58), "OUT from selected", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
		pen.draw_line(origin + Vector2(191, -62), origin + Vector2(219, -62), Color("dce8f2"), 2.0, true)
		pen.draw_string(font, origin + Vector2(226, -58), "IN to selected", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	else:
		pen.draw_string(font, origin + Vector2(0, -58), "Select a neighborhood for direction styles", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, origin + Vector2(0, -39), "Arrow width and opacity = route flow", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("9db3c5"))
	pen.draw_string(font, origin + Vector2(0, -14), "JOB ACCESSIBILITY", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, origin + Vector2(205, -14), "Node ring = desirability", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	for step in range(8):
		pen.draw_rect(Rect2(origin + Vector2(step * 17.0, 0), Vector2(16, 9)), _access_color(float(step) / 7.0))
	pen.draw_string(font, origin + Vector2(0, 26), "lower", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	pen.draw_string(font, origin + Vector2(102, 26), "higher", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))


func _draw_map_scale(pen) -> void:
	var pixels_per_km: float = _map_scale() * zoom
	if pixels_per_km <= 0.0:
		return
	var maximum_km: float = 110.0 / pixels_per_km
	var magnitude: float = pow(10.0, floorf(log(maximum_km) / log(10.0)))
	var distance_km: float = magnitude
	for multiplier in [5.0, 2.0]:
		if magnitude * multiplier <= maximum_km:
			distance_km = magnitude * multiplier
			break
	var origin := Vector2(size.x - 150.0, 94.0 if size.x < 800.0 else size.y - 48.0)
	var width: float = distance_km * pixels_per_km
	pen.draw_rect(Rect2(origin - Vector2(10, 24), Vector2(140, 38)), Color("0b1927", 0.9))
	var label: String = "%.0f km" % distance_km if distance_km >= 1.0 else "%.0f m" % (distance_km * 1000.0)
	pen.draw_string(get_theme_default_font(), origin + Vector2(0, -7), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("d7e7f1"))
	pen.draw_line(origin, origin + Vector2(width, 0), Color("d7e7f1"), 2.0)
	for offset in [0.0, width]:
		pen.draw_line(origin + Vector2(offset, -3), origin + Vector2(offset, 3), Color("d7e7f1"), 2.0)


func reset_view() -> void:
	zoom = 1.0
	pan = Vector2.ZERO
	pointer_down = false
	_sync_view()
	refresh_dynamic()


func _zoom_at(screen_position: Vector2, factor: float) -> void:
	if not is_finite(factor) or factor <= 0.0:
		return
	var old_zoom: float = zoom
	zoom = clampf(zoom * factor, 1.0, minf(MAX_ZOOM, MAX_PIXELS_PER_KM / maxf(_map_scale(), 0.001)))
	var ratio: float = zoom / old_zoom
	pan = screen_position - size * 0.5 - (screen_position - size * 0.5 - pan) * ratio
	if pointer_down:
		pointer_dragged = true
	_sync_view()
	hover_world_position = _screen_to_world(screen_position)
	refresh_dynamic()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		accept_event()
	elif event is InputEventPanGesture:
		if event.ctrl_pressed or event.meta_pressed:
			_zoom_at(event.position, exp(-event.delta.y * 0.08))
		else:
			pan -= event.delta * TRACKPAD_PAN_PIXELS
			if pointer_down:
				pointer_dragged = true
			_sync_view()
			hover_world_position = _screen_to_world(event.position)
			refresh_dynamic()
		accept_event()
	elif event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and (mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var direction: float = 1.0 if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			var amount: float = mouse_button.factor if mouse_button.factor > 0.0 else 1.0
			_zoom_at(mouse_button.position, pow(1.35, direction * amount))
			accept_event()
		elif mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				pointer_double_clicked = mouse_button.double_click
				hover_world_position = _screen_to_world(mouse_button.position)
				pointer_down = true
				pointer_dragged = false
				pointer_start = mouse_button.position
			else:
				if pointer_down and not pointer_dragged:
					var clicked_label: int = _hit_jurisdiction_label(mouse_button.position)
					if clicked_label >= 0:
						jurisdiction_selected.emit(clicked_label)
						pointer_down = false
						pointer_double_clicked = false
						accept_event()
						return
					if map_mode == "Zoning":
						var candidate_id: int = _visible_zoning_candidate_at(_screen_to_world(mouse_button.position))
						if candidate_id >= 0:
							candidate_selected.emit(candidate_id)
						else:
							var zone_area_id: int = _hit_jurisdiction_label(mouse_button.position)
							if zone_area_id < 0:
								zone_area_id = _jurisdiction_at(mouse_button.position)
							if zone_area_id >= 0:
								jurisdiction_selected.emit(zone_area_id)
					elif map_mode == "Roads":
						var node_id := _hit_road_node(mouse_button.position)
						var link_id := _hit_road_link(mouse_button.position)
						if node_id >= 0:
							road_node_clicked.emit(node_id)
						elif link_id >= 0:
							road_link_clicked.emit(link_id, _screen_to_world(mouse_button.position))
						else:
							var local_street: Vector2i = urban_layer.hit_street(self, mouse_button.position) if road_tool == "Inspect" else Vector2i(-1, -1)
							if local_street.x >= 0:
								local_street_selected.emit(local_street.x, local_street.y)
								pointer_down = false
								accept_event()
								return
							var road_area_id: int = -1
							if road_tool == "Inspect":
								road_area_id = _hit_jurisdiction_border(mouse_button.position)
								if road_area_id < 0:
									road_area_id = _jurisdiction_at(mouse_button.position)
							if road_area_id >= 0:
								jurisdiction_selected.emit(road_area_id)
							else:
								if pointer_double_clicked and road_tool in ["Arterial", "Highway"]:
									road_empty_double_clicked.emit(_screen_to_world(mouse_button.position))
								else:
									road_empty_clicked.emit(_screen_to_world(mouse_button.position))
					else:
						var neighborhood_id: int = _hit_test(mouse_button.position)
						if neighborhood_id >= 0:
							neighborhood_selected.emit(neighborhood_id)
						else:
							var trip_area_id: int = _hit_jurisdiction_border(mouse_button.position)
							if trip_area_id < 0:
								trip_area_id = _jurisdiction_at(mouse_button.position)
							if trip_area_id >= 0:
								jurisdiction_selected.emit(trip_area_id)
				pointer_down = false
				pointer_double_clicked = false
			accept_event()
		elif mouse_button.button_index == MOUSE_BUTTON_RIGHT and mouse_button.pressed and map_mode == "Roads":
			road_cancel_requested.emit()
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_sync_view()
		hover_world_position = _screen_to_world(motion.position)
		if pointer_down:
			if motion.position.distance_to(pointer_start) > 4.0:
				pointer_dragged = true
			if pointer_dragged:
				pan += motion.relative
				_sync_view()
				refresh_dynamic()
		else:
			var new_hover: int = -1 if map_mode == "Zoning" else _hit_test(motion.position)
			var candidate_hover: int = _visible_zoning_candidate_at(_screen_to_world(motion.position)) if map_mode == "Zoning" and region != null else -1
			var hovered_area_id: int = _hit_jurisdiction_label(motion.position)
			if hovered_area_id < 0 and (map_mode == "Trips" or road_tool == "Inspect"):
				hovered_area_id = _hit_jurisdiction_border(motion.position)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hovered_area_id >= 0 or new_hover >= 0 or candidate_hover >= 0 else Control.CURSOR_ARROW
			if new_hover != hovered_id:
				hovered_id = new_hover
				refresh_dynamic()
			elif preview_start_node >= 0 or preview_start_position.is_finite() or planning_preview_start.is_finite():
				refresh_dynamic()


func _hit_road_node(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest := -1
	var best := INF
	var show_local_roads: bool = _map_scale() * view_zoom >= 25.0 or road_tool != "Inspect"
	var node_indices: Array[int] = _spatial_near_indices(spatial_road_nodes, screen_position, 25.0) if region.is_large_scale and view_zoom >= 2.0 else _all_indices(region.road_nodes.size())
	for node_index in node_indices:
		var node = region.road_nodes[node_index]
		if node.managed_neighborhood_id >= 0 and road_tool == "Inspect":
			continue
		if road_tool == "Inspect" and _pixels_per_meter() >= 0.03 and not node.is_interchange:
			continue
		if not show_local_roads and node.kind != "City" and not node.is_interchange:
			continue
		var distance: float = screen_position.distance_to(_world_to_screen(node.position_km))
		var hit_radius: float = _node_radius(region.neighborhoods[node.neighborhood_id].population) + 3.0 if node.neighborhood_id >= 0 else 13.0
		if distance <= hit_radius and distance < best:
			best = distance
			closest = node.id
	return closest


func _draw_hidden_road_selection(pen) -> void:
	var points := PackedVector2Array()
	var ppk: float = _map_scale() * zoom
	if selected_local_street.x >= 0:
		if MapStyle.visibility(ppk, MapStyle.road_range(MapStyle.RoadStyle.LOCAL)) > 0.05: return
		var neighborhood = region.neighborhoods[selected_local_street.x]
		var layout = neighborhood.street_layout
		var index: int = selected_local_street.y
		if layout != null and index >= 0 and index < layout.edges.size():
			var edge: Vector2 = layout.edges[index]
			points = layout.edge_paths.get(index, PackedVector2Array([layout.nodes[int(edge.x)],layout.nodes[int(edge.y)]]))
	elif selected_road_link_id >= 0:
		var index: int = RoadGraph.link_index(region, selected_road_link_id)
		if index >= 0 and not MapStyle.road_visible(region.road_links[index], ppk):
			points = region.road_links[index].points
	if points.size() >= 2:
		pen.draw_polyline(_screen_polyline(points), Color("f7e3a1"), 3.0, true)


func _hit_road_link(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest := -1
	var best := INF
	var link_indices: Array[int] = _spatial_near_indices(spatial_road_links, screen_position, _road_cull_margin(), true) if region.is_large_scale and zoom >= 2.0 else _all_indices(region.road_links.size())
	for link_index in link_indices:
		var link = region.road_links[link_index]
		if link.id != selected_road_link_id and not MapStyle.road_visible(link, _map_scale() * zoom):
			continue
		var screen_points: PackedVector2Array = _screen_polyline(link.points)
		if _map_scale() * zoom < 60.0:
			for segment in range(1, screen_points.size()):
				var near: Vector2 = Geometry2D.get_closest_point_to_segment(screen_position, screen_points[segment - 1], screen_points[segment])
				var center_distance: float = near.distance_to(screen_position)
				if center_distance <= 6.0 and center_distance < best:
					best = center_distance
					closest = link.id
			continue
		var lane_hit_radius: float = maxf(4.5, _road_lane_width(link.road_class) * 0.5 + 2.0)
		for direction in range(2):
			for lane_index in range(link.lanes_per_direction):
				var lane_points: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction, direction, lane_index, link.road_class))
				for segment in range(1, lane_points.size()):
					var point: Vector2 = Geometry2D.get_closest_point_to_segment(screen_position, lane_points[segment - 1], lane_points[segment])
					var distance: float = point.distance_to(screen_position)
					if distance <= lane_hit_radius and distance < best:
						best = distance
						closest = link.id
		for segment in range(1, screen_points.size()):
			var center_point: Vector2 = Geometry2D.get_closest_point_to_segment(screen_position, screen_points[segment - 1], screen_points[segment])
			var center_distance: float = center_point.distance_to(screen_position)
			if center_distance <= _road_outer_half_width(link.lanes_per_direction, link.road_class) + 2.0 and center_distance < best:
				best = center_distance
				closest = link.id
	return closest


func _hit_test(screen_position: Vector2) -> int:
	if region == null:
		return -1
	if region.is_large_scale and _map_scale() * view_zoom * StateGeography.CELL_SIZE_KM < 8.0:
		return -1
	var closest_id := -1
	var closest_distance := INF
	var neighborhood_indices: Array[int] = _spatial_near_indices(spatial_neighborhoods, screen_position, 25.0) if region.is_large_scale and view_zoom >= 2.0 else _all_indices(region.neighborhoods.size())
	for neighborhood_index in neighborhood_indices:
		var neighborhood = region.neighborhoods[neighborhood_index]
		if neighborhood.street_layout == null:
			continue
		var distance: float = screen_position.distance_to(_world_to_screen(neighborhood.position_km))
		if distance <= _node_radius(neighborhood.population) + 7.0 and distance < closest_distance:
			closest_id = neighborhood.id
			closest_distance = distance
	return closest_id


func _hit_jurisdiction_label(screen_position: Vector2) -> int:
	if region == null:
		return -1
	for kind in ["City", "County", "Region"]:
		for area in region.jurisdictions:
			if area.kind == kind and _jurisdiction_label_visible(area) and _jurisdiction_label_rect(area).has_point(screen_position):
				return area.id
	return -1


func _hit_jurisdiction_border(screen_position: Vector2) -> int:
	if region == null:
		return -1
	for kind in ["Region", "County", "City"]:
		for area in region.jurisdictions:
			if area.kind != kind:
				continue
			var polygon: PackedVector2Array = _screen_polyline(area.polygon_km)
			for vertex in range(polygon.size()):
				var closest: Vector2 = Geometry2D.get_closest_point_to_segment(screen_position, polygon[vertex], polygon[(vertex + 1) % polygon.size()])
				if closest.distance_to(screen_position) <= 4.0:
					return area.id
	return -1


func _jurisdiction_at(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var world_position: Vector2 = _screen_to_world(screen_position)
	for city_id in region.city_jurisdiction_ids:
		var city = region.jurisdictions[city_id]
		if _neighborhood_borders_visible(city) and city.contains_point(world_position):
			return region.jurisdiction_at_point(world_position)
	var selected_kind: String = region.jurisdictions[selected_jurisdiction_id].kind if selected_jurisdiction_id >= 0 else "State"
	var target_kind: String = {"State": "Region", "Region": "County", "County": "City", "City": "City", "Neighborhood": "City"}.get(selected_kind, "City")
	if selected_kind in ["Region", "County"] and not region.jurisdictions[selected_jurisdiction_id].contains_point(world_position):
		target_kind = selected_kind
	for area in region.jurisdictions:
		if area.kind == target_kind and area.contains_point(world_position):
			return area.id
	if region.jurisdictions[0].contains_point(world_position):
		return region.jurisdiction_at_point(world_position)
	return -1


func _map_scale() -> float:
	var world_size: Vector2 = _world_size()
	return minf((size.x - 110.0) / world_size.x, (size.y - 110.0) / world_size.y)


func _world_size() -> Vector2:
	return region.jurisdictions[0].bounds_km.size if region != null else WORLD_SIZE


func _world_center() -> Vector2:
	return region.jurisdictions[0].bounds_km.get_center() if region != null else WORLD_CENTER


func _screen_visible(point: Vector2, margin: float = 0.0) -> bool:
	return point.x >= view_origin.x - margin and point.y >= view_origin.y - margin and point.x <= view_origin.x + view_size.x + margin and point.y <= view_origin.y + view_size.y + margin


func _polyline_visible(points: PackedVector2Array) -> bool:
	if points.is_empty():
		return false
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	var xform := _screen_transform()
	var screen_bounds := Rect2(xform * bounds.position, Vector2.ZERO).expand(xform * bounds.end)
	return screen_bounds.grow(_road_cull_margin()).intersects(view_rect())


func _world_to_screen(world_position: Vector2) -> Vector2:
	return size * 0.5 + view_pan + (world_position - _world_center()) * _map_scale() * view_zoom


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return _world_center() + (screen_position - size * 0.5 - view_pan) / (_map_scale() * view_zoom)


func _node_radius(population: int) -> float:
	return clampf(4.0 + sqrt(float(population)) * 0.05, 6.0, 11.0) * clampf(sqrt(view_zoom), 0.9, 1.35)


func _access_color(t: float) -> Color:
	return Color("3bb5c8").lerp(Color("f5a45d"), clampf(t, 0.0, 1.0))


func view_rect() -> Rect2:
	return Rect2(view_origin, view_size)


func refresh_static() -> void:
	overlays_dirty = true
	terrain_view_key = ""
	refresh_dynamic()


func refresh_dynamic() -> void:
	if dynamic_overlay != null:
		dynamic_overlay.queue_redraw()


func _sync_view() -> void:
	view_pan = pan
	view_zoom = zoom


func _zoom_band() -> int:
	return maxi(0, floori(log(maxf(zoom, 0.0001)) / log(ZOOM_BAND_RATIO)))


func _band_zoom(band: int) -> float:
	# Baking at the band base keeps ratio = zoom / bake_zoom >= 1.0, so the
	# live viewport always fits inside the baked content between rebakes.
	return pow(ZOOM_BAND_RATIO, float(band))


func _static_bake_key(band: int) -> String:
	return "%s:%s:%s:%s:%d" % [size, map_mode, show_transit_overlay, selected_candidate_id, band]


func _static_update() -> void:
	# Every-frame gate: schedule a rebake when the zoom band, the bake
	# signature, or the live view escapes the margin the baked content
	# covers. Pending values only become the committed bake state once the
	# static layer actually redraws, so the transform never runs ahead of
	# the drawn content.
	if region == null:
		return
	var band := _zoom_band()
	var key := _static_bake_key(band)
	var ratio: float = zoom / bake_zoom if bake_zoom > 0.0 else 1.0
	var origin: Vector2 = (Vector2.ONE - Vector2(ratio, ratio)) * size * 0.5 + pan - bake_pan * ratio
	var needed: Rect2 = Rect2(-origin / ratio, size / ratio)
	var coverage: Rect2 = Rect2(Vector2(-BAKE_MARGIN_PX, -BAKE_MARGIN_PX), size + Vector2(BAKE_MARGIN_PX, BAKE_MARGIN_PX) * 2.0).grow(-32.0)
	if overlays_dirty or key != bake_key or not coverage.encloses(needed):
		pending_bake_key = key
		pending_bake_zoom = _band_zoom(band)
		# pan is a screen-pixel offset for the live zoom; re-anchor it for the
		# band zoom so the bake shows the same world point at the center.
		pending_bake_pan = pan * (pending_bake_zoom / maxf(zoom, 0.0001))
		if static_layer != null and not static_bake_queued:
			static_bake_queued = true
			static_layer.queue_redraw()
	_apply_static_transform()


func _apply_static_transform() -> void:
	if static_layer == null or bake_zoom <= 0.0:
		return
	var ratio: float = zoom / bake_zoom
	var origin: Vector2 = (Vector2.ONE - Vector2(ratio, ratio)) * size * 0.5 + pan - bake_pan * ratio
	RenderingServer.canvas_item_set_transform(static_layer.get_canvas_item(), Transform2D(Vector2(ratio, 0.0), Vector2(0.0, ratio), origin))


func _grade_crossing_marks() -> Array:
	if crossing_marks_revision == region.road_geometry_revision and not crossing_marks.is_empty():
		return crossing_marks
	crossing_marks.clear()
	for link in region.road_links:
		for crossing in link.crossings:
			var over_link = link if crossing["above"] else _link_near_crossing(int(crossing["link_id"]), crossing["point"], link.id)
			if over_link == null:
				continue
			var point: Vector2 = crossing["point"]
			var direction := Vector2.RIGHT
			var best := INF
			for segment in range(1, over_link.points.size()):
				var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(point, over_link.points[segment - 1], over_link.points[segment])
				if nearest.distance_squared_to(point) < best:
					best = nearest.distance_squared_to(point)
					direction = (over_link.points[segment] - over_link.points[segment - 1]).normalized()
			crossing_marks.append({"point": point, "direction": direction, "lanes": over_link.lanes_per_direction, "road_class": over_link.road_class})
	crossing_marks_revision = region.road_geometry_revision
	return crossing_marks


class MapStaticLayer:
	extends Control
	var map
	func _draw() -> void:
		if map != null:
			map._draw_static_content(self)


class MapOverlay:
	extends Control
	var map
	func _draw() -> void:
		if map != null:
			map._draw_dynamic_content(self)
	func _gui_input(event: InputEvent) -> void:
		if map != null:
			map._gui_input(event)
