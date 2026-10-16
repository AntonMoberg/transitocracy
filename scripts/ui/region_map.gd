extends Control

signal neighborhood_selected(neighborhood_id: int)
signal road_node_clicked(node_id: int)
signal road_link_clicked(link_id: int, world_position: Vector2)
signal road_empty_clicked(world_position: Vector2)
signal road_cancel_requested
signal jurisdiction_selected(jurisdiction_id: int)

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const WORLD_CENTER = Vector2(120.0, 80.0)
const WORLD_SIZE = Vector2(240.0, 160.0)
const MIN_VISIBLE_SOCIAL_TRIPS = 0.05
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

var region
var flow_profile
var next_day_profile
var traffic_profile
var next_traffic_profile
var map_mode: String = "Roads"
var detail_level: String = "Neighborhood"
var road_tool: String = "Inspect"
var selected_road_link_id: int = -1
var preview_start_node: int = -1
var preview_waypoints: PackedVector2Array = PackedVector2Array()
var road_preview: Dictionary = {}
var hover_world_position: Vector2 = Vector2.ZERO
var selected_hour: int = 8
var hour_fraction: float = 0.0
var recorded_bin: int = 0
var first_recorded_bin: int = 0
var selected_purpose: String = FlowProfile.ALL
var selected_id: int = -1
var selected_jurisdiction_id: int = -1
var hovered_id: int = -1
var aggregate_cache_region
var aggregate_cache_level: String = ""
var aggregate_neighborhood_groups: PackedInt32Array = PackedInt32Array()
var aggregate_node_groups: PackedInt32Array = PackedInt32Array()
var aggregate_flow_cache: Dictionary = {}
var zoom: float = 1.0
var pan: Vector2 = Vector2.ZERO
var pointer_down: bool = false
var pointer_dragged: bool = false
var pointer_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(480, 320)
	resized.connect(queue_redraw)


func set_region(new_region) -> void:
	region = new_region
	selected_id = -1
	selected_road_link_id = -1
	hovered_id = -1
	zoom = 1.0
	pan = Vector2.ZERO
	queue_redraw()


func set_flow_profile(new_profile) -> void:
	flow_profile = new_profile
	aggregate_flow_cache.clear()
	queue_redraw()


func set_next_day_profile(new_profile) -> void:
	next_day_profile = new_profile
	queue_redraw()


func set_traffic_profile(new_profile) -> void:
	traffic_profile = new_profile
	queue_redraw()


func set_next_traffic_profile(new_profile) -> void:
	next_traffic_profile = new_profile
	queue_redraw()


func set_map_mode(mode: String) -> void:
	map_mode = mode
	queue_redraw()


func set_detail_level(level: String) -> void:
	detail_level = level
	aggregate_cache_level = ""
	aggregate_flow_cache.clear()
	queue_redraw()


func set_road_tool(tool_name: String) -> void:
	road_tool = tool_name
	queue_redraw()


func set_road_preview(start_node: int, waypoints: PackedVector2Array, preview: Dictionary) -> void:
	preview_start_node = start_node
	preview_waypoints = waypoints
	road_preview = preview
	queue_redraw()


func set_selected_road_link(link_id: int) -> void:
	selected_road_link_id = link_id
	queue_redraw()


func set_hour(hour: int) -> void:
	set_time(hour, 0.0)


func set_time(hour: int, fraction: float) -> void:
	selected_hour = clampi(hour, 0, 23)
	hour_fraction = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func set_recorded_bin(bin_index: int, first_bin: int = 0) -> void:
	recorded_bin = bin_index
	first_recorded_bin = first_bin
	queue_redraw()


func set_purpose(purpose: String) -> void:
	selected_purpose = purpose
	queue_redraw()


func set_selected(neighborhood_id: int) -> void:
	selected_id = neighborhood_id
	queue_redraw()


func set_selected_jurisdiction(jurisdiction_id: int) -> void:
	selected_jurisdiction_id = jurisdiction_id
	queue_redraw()


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
		aggregate_node_groups[node.id] = aggregate_neighborhood_groups[region.nearest_neighborhood_id(node.position_km)]


func _aggregate_flow_matrix(profile, hour: int, purpose: String) -> Dictionary:
	var cache_key: String = "%d:%d:%s" % [profile.get_instance_id(), hour, purpose]
	if aggregate_flow_cache.has(cache_key):
		return aggregate_flow_cache[cache_key]
	var matrix: Array = profile.get_hour_matrix(hour, purpose)
	var grouped: Dictionary = {}
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
	if road_class == "Highway":
		return true
	return _road_node_city(from_node_id) != _road_node_city(to_node_id)


func _is_strategic_road(link) -> bool:
	return _is_strategic_road_nodes(link.from_node_id, link.to_node_id, link.road_class)


func _draw_aggregate_roads() -> void:
	var local_km := 0.0
	for link in region.road_links:
		if _is_strategic_road(link):
			continue
		local_km += link.length_km
		draw_polyline(_screen_polyline(link.points), Color("526474", 0.30), 1.0, true)
	for index in range(region.road_links.size()):
		var link = region.road_links[index]
		if not _is_strategic_road(link):
			continue
		var forward_color := Color("3f88b0")
		var reverse_color := forward_color
		if map_mode == "Roads" and not _is_recorded_time():
			forward_color = Color("647687")
			reverse_color = forward_color
		elif map_mode == "Roads" and traffic_profile != null and index < traffic_profile.link_ids.size():
			var served: Vector2 = traffic_profile.interpolated_served_rate(index, selected_hour, hour_fraction, next_traffic_profile)
			var queue: Vector2 = traffic_profile.interpolated_queue(index, selected_hour, hour_fraction)
			var capacity: float = (1800.0 if link.road_class == "Highway" else 900.0) * link.lanes_per_direction
			forward_color = _congestion_color(maxf(served.x / capacity, queue.x / (capacity * 0.5)))
			reverse_color = _congestion_color(maxf(served.y / capacity, queue.y / (capacity * 0.5)))
		if map_mode == "Trips":
			forward_color.a = 0.23
			reverse_color.a = 0.23
		_draw_active_road(_screen_polyline(link.points), link.lanes_per_direction, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
	var font := get_theme_default_font()
	draw_string(font, Vector2(18, size.y - 18), "%s view  •  %.0f km of local roads subdued" % [detail_level, local_km], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("aec5d4"))


func _draw_aggregate_road_projects() -> void:
	for project in region.road_projects:
		match project.kind:
			"New road":
				if _is_strategic_road_nodes(project.from_node_id, project.to_node_id, project.road_class):
					_draw_dashed_road(_screen_polyline(project.points), project.lanes_per_direction, Color("8fbfd8", 0.70))
			"Widen":
				for link in region.road_links:
					if link.id == project.target_link_id and _is_strategic_road(link):
						var screen_points: PackedVector2Array = _screen_polyline(link.points)
						for direction in range(2):
							var new_lane: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction + 1, direction, link.lanes_per_direction))
							_draw_dashed_polyline(new_lane, Color("f0d38d", 0.9), _road_lane_width())
			"Interchange junction":
				draw_arc(_world_to_screen(region.road_nodes[project.target_node_id].position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)
			"Highway exit":
				draw_arc(_world_to_screen(project.position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)


func _draw_aggregate_flows() -> void:
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
		_draw_flow_stroke(start_point, end_point, color, 1.0 + 5.0 * strength, flow["from"] == selected_jurisdiction_id)
		var side: Vector2 = Vector2(-direction.y, direction.x) * (2.0 + 2.0 * strength)
		draw_colored_polygon(PackedVector2Array([end_point, end_point - direction * 10.0 + side, end_point - direction * 10.0 - side]), color)


func _draw_aggregate_nodes() -> void:
	var font := get_theme_default_font()
	for area in _visible_areas():
		var center: Vector2 = _world_to_screen(area.center_km)
		var population := 0
		for neighborhood_id in area.neighborhood_ids:
			population += region.neighborhoods[neighborhood_id].population
		var radius: float = clampf(8.0 + sqrt(float(population)) * 0.03, 12.0, 23.0)
		draw_circle(center, radius + 3.0, Color("0b1421"))
		draw_circle(center, radius, Color("4b9fbd"))
		draw_arc(center, radius + 3.0, 0.0, TAU, 32, Color("f5d482") if area.id == selected_jurisdiction_id else Color("b7d6e5"), 2.0, true)
		var label: String = area.name
		var label_width: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(font, center + Vector2(-label_width * 0.5, -radius - 9.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("d9e9f2"))


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
	draw_rect(Rect2(Vector2.ZERO, size), Color("101b2b"))
	_draw_grid()
	if region == null:
		return
	_draw_boundaries()
	_draw_cities()
	_draw_roads()
	if map_mode == "Trips":
		_draw_hourly_flows()
	_draw_neighborhoods()
	_draw_jurisdiction_labels()
	_draw_jurisdiction_key()
	if map_mode == "Roads":
		_draw_road_nodes()
		_draw_road_preview()
		_draw_road_legend()
	else:
		_draw_legend()


func _draw_roads() -> void:
	if detail_level != "Neighborhood":
		_draw_aggregate_roads()
		_draw_aggregate_road_projects()
		return
	for link_index in range(region.road_links.size()):
		var link = region.road_links[link_index]
		var forward_color := Color("3f88b0")
		var reverse_color := forward_color
		if map_mode == "Roads" and not _is_recorded_time():
			forward_color = Color("647687")
			reverse_color = forward_color
		elif map_mode == "Roads" and traffic_profile != null:
			var served: Vector2 = traffic_profile.interpolated_served_rate(link_index, selected_hour, hour_fraction, next_traffic_profile)
			var queue: Vector2 = traffic_profile.interpolated_queue(link_index, selected_hour, hour_fraction)
			var capacity: float = (1800.0 if link.road_class == "Highway" else 900.0) * link.lanes_per_direction
			forward_color = _congestion_color(maxf(served.x / capacity, queue.x / (capacity * 0.5)))
			reverse_color = _congestion_color(maxf(served.y / capacity, queue.y / (capacity * 0.5)))
		if map_mode == "Trips":
			forward_color.a = 0.23
			reverse_color.a = 0.23
		_draw_active_road(_screen_polyline(link.points), link.lanes_per_direction, forward_color, reverse_color, selected_road_link_id == link.id and map_mode == "Roads")
	for project in region.road_projects:
		match project.kind:
			"New road":
				_draw_dashed_road(_screen_polyline(project.points), project.lanes_per_direction, Color("8fbfd8", 0.70))
			"Widen":
				for link in region.road_links:
					if link.id == project.target_link_id:
						var screen_points: PackedVector2Array = _screen_polyline(link.points)
						for direction in range(2):
							var new_lane: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction + 1, direction, link.lanes_per_direction))
							_draw_dashed_polyline(new_lane, Color("f0d38d", 0.9), _road_lane_width())
			"Interchange junction":
				draw_arc(_world_to_screen(region.road_nodes[project.target_node_id].position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)
			"Highway exit":
				draw_arc(_world_to_screen(project.position_km), 11.0, 0.0, TAU, 24, Color("f0d38d"), 2.0, true)


func _draw_active_road(screen_points: PackedVector2Array, lanes: int, forward_color: Color, reverse_color: Color, selected: bool) -> void:
	if screen_points.size() < 2:
		return
	if map_mode == "Roads":
		var casing_width: float = _road_outer_half_width(lanes) * 2.0
		if selected:
			draw_polyline(screen_points, Color("f7f0bf"), casing_width + 3.0, true)
		draw_polyline(screen_points, Color("091321"), casing_width, true)
	for direction in range(2):
		var lane_color: Color = forward_color if direction == 0 else reverse_color
		for lane_index in range(lanes):
			var lane_points: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(lanes, direction, lane_index))
			draw_polyline(lane_points, lane_color, _road_lane_width(), true)
	if map_mode == "Roads":
		_draw_road_direction_arrows(screen_points, lanes)


func _draw_road_direction_arrows(screen_points: PackedVector2Array, lanes: int) -> void:
	for segment in range(1, screen_points.size()):
		var start_point: Vector2 = screen_points[segment - 1]
		var end_point: Vector2 = screen_points[segment]
		var displacement: Vector2 = end_point - start_point
		var segment_length: float = displacement.length()
		if segment_length < 16.0:
			continue
		var tangent: Vector2 = displacement / segment_length
		var normal: Vector2 = tangent.orthogonal()
		var bundle_offset: float = _road_median_half_gap() + _road_lane_spacing() * float(lanes) * 0.5
		var arrow_length: float = clampf(segment_length * 0.18, 3.0, 6.0)
		for direction in range(2):
			var travel: Vector2 = tangent if direction == 0 else -tangent
			var tip_position: Vector2 = start_point.lerp(end_point, 0.57 if direction == 0 else 0.43) + normal * bundle_offset * _road_direction_side(direction)
			var arrow_base: Vector2 = tip_position - travel * arrow_length
			var wing: Vector2 = travel.orthogonal() * 2.2
			draw_colored_polygon(PackedVector2Array([tip_position, arrow_base + wing, arrow_base - wing]), Color("f1f7fa", 0.88))


func _screen_polyline(world_points: PackedVector2Array) -> PackedVector2Array:
	var screen_points := PackedVector2Array()
	for world_point in world_points:
		screen_points.append(_world_to_screen(world_point))
	return screen_points


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


func _road_lane_spacing() -> float:
	return clampf(2.7 * sqrt(zoom), 2.3, 4.2)


func _road_lane_width() -> float:
	return clampf(1.8 * sqrt(zoom), 1.5, 2.5)


func _road_median_half_gap() -> float:
	return clampf(1.6 * sqrt(zoom), 1.4, 2.4)


func _road_lane_offset(lanes: int, direction: int, lane_index: int) -> float:
	return _road_direction_side(direction) * (_road_median_half_gap() + _road_lane_spacing() * (float(lane_index) + 0.5))


func _road_direction_side(direction: int) -> float:
	# Vector2.orthogonal() points to the screen-left of the road's forward path.
	return -1.0 if direction == 0 else 1.0


func _road_outer_half_width(lanes: int) -> float:
	return _road_median_half_gap() + _road_lane_spacing() * float(lanes) + 0.7


func _draw_dashed_polyline(screen_points: PackedVector2Array, color: Color, width: float) -> void:
	for index in range(1, screen_points.size()):
		_draw_flow_stroke(screen_points[index - 1], screen_points[index], color, width, true)


func _draw_dashed_road(screen_points: PackedVector2Array, lanes: int, color: Color) -> void:
	for direction in range(2):
		for lane_index in range(lanes):
			_draw_dashed_polyline(_offset_polyline(screen_points, _road_lane_offset(lanes, direction, lane_index)), color, _road_lane_width())


func _congestion_color(ratio: float) -> Color:
	if ratio <= 0.7:
		return Color("5abfa5").lerp(Color("e6c56f"), clampf(ratio / 0.7, 0.0, 1.0))
	return Color("e6c56f").lerp(Color("e25e5e"), clampf((ratio - 0.7) / 0.8, 0.0, 1.0))


func _draw_road_nodes() -> void:
	for node in region.road_nodes:
		var position_on_screen: Vector2 = _world_to_screen(node.position_km)
		if detail_level != "Neighborhood" and node.neighborhood_id >= 0 and not node.is_interchange:
			draw_circle(position_on_screen, 2.0, Color("8ea3b1", 0.48))
			continue
		var radius := 5.0 if node.is_interchange else 3.5
		draw_circle(position_on_screen, radius + 2.0, Color("091321"))
		draw_circle(position_on_screen, radius, Color("f2d786") if node.is_interchange else Color("c8d5df"))
		if node.is_interchange:
			draw_arc(position_on_screen, radius + 4.0, 0.0, TAU, 24, Color("f2d786", 0.8), 1.0, true)


func _draw_road_preview() -> void:
	if preview_start_node >= 0:
		var points := PackedVector2Array([region.road_nodes[preview_start_node].position_km])
		for point in preview_waypoints:
			points.append(point)
		if road_preview.get("ok", false):
			points.append(region.road_nodes[int(road_preview["to"])].position_km)
		else:
			points.append(hover_world_position)
		var preview_lanes: int = int(road_preview.get("lanes", 2 if road_tool == "Highway" else 1))
		_draw_dashed_road(_screen_polyline(points), preview_lanes, Color("f4dd91"))
	elif road_preview.get("ok", false) and road_preview.get("kind", "") == "Highway exit":
		draw_arc(_world_to_screen(road_preview["position_km"]), 10.0, 0.0, TAU, 24, Color("f4dd91"), 2.0, true)
	elif road_preview.get("ok", false) and road_preview.get("kind", "") == "Demolish":
		for link in region.road_links:
			if link.id == road_preview["target_link_id"]:
				_draw_dashed_road(_screen_polyline(link.points), link.lanes_per_direction, Color("f06464"))


func _draw_road_legend() -> void:
	var font := get_theme_default_font()
	var base := Vector2(18.0, size.y - 16.0)
	draw_rect(Rect2(base - Vector2(9, 95), Vector2(440, 116)), Color(0.04, 0.09, 0.16, 0.90))
	draw_string(font, base + Vector2(0, -76), "ROAD FLOW / CAPACITY + QUEUES", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("d7e7f1"))
	for index in range(12):
		draw_rect(Rect2(base + Vector2(index * 18.0, -64), Vector2(17, 9)), _congestion_color(float(index) / 7.0))
	draw_string(font, base + Vector2(0, -39), "clear", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, base + Vector2(164, -39), "saturated / queued", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, base + Vector2(0, -17), "One line = one lane  •  Arrows = travel direction", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, base + Vector2(0, 4), "Dashed = under construction  •  Gold = interchange", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))


func _draw_grid() -> void:
	var grid_color := Color(0.32, 0.47, 0.60, 0.15)
	for x in range(0, 241, 20):
		draw_line(_world_to_screen(Vector2(x, 0)), _world_to_screen(Vector2(x, WORLD_SIZE.y)), grid_color, 1.0)
	for y in range(0, 161, 20):
		draw_line(_world_to_screen(Vector2(0, y)), _world_to_screen(Vector2(WORLD_SIZE.x, y)), grid_color, 1.0)


func _draw_boundaries() -> void:
	if selected_jurisdiction_id >= 0:
		var selected = region.jurisdictions[selected_jurisdiction_id]
		if selected.kind in ["Region", "County", "City"]:
			draw_rect(_jurisdiction_screen_rect(selected), Color("e5d69a", 0.055))
	# Draw the smaller divisions first so the broader borders stay legible where they coincide.
	for kind in ["City", "County", "Region"]:
		for area in region.jurisdictions:
			if area.kind != kind:
				continue
			var color: Color = _jurisdiction_color(kind)
			color.a = {"City": 0.46, "County": 0.72, "Region": 0.92}[kind]
			draw_rect(_jurisdiction_screen_rect(area), color, false, {"City": 1.0, "County": 2.0, "Region": 3.0}[kind])
	if selected_jurisdiction_id >= 0:
		var selected = region.jurisdictions[selected_jurisdiction_id]
		if selected.kind in ["Region", "County", "City"]:
			draw_rect(_jurisdiction_screen_rect(selected), Color("fff0b0", 0.95), false, 3.5)


func _jurisdiction_screen_rect(area) -> Rect2:
	var upper_left: Vector2 = _world_to_screen(area.bounds_km.position)
	return Rect2(upper_left, _world_to_screen(area.bounds_km.end) - upper_left)


func _jurisdiction_color(kind: String) -> Color:
	match kind:
		"Region":
			return Color("63c6e5")
		"County":
			return Color("e4be75")
		_:
			return Color("b5a9e8")


func _jurisdiction_label_text(area) -> String:
	var space: float = _jurisdiction_screen_rect(area).size.x
	match area.kind:
		"Region":
			return ("REGION · " if space >= 200.0 else "") + area.name.to_upper()
		"County":
			return ("COUNTY · " + area.name.to_upper()) if space >= 150.0 else area.name.trim_suffix(" County").to_upper()
		_:
			return ("CITY · " if space >= 140.0 else "") + area.name.to_upper()


func _jurisdiction_label_rect(area) -> Rect2:
	var bounds: Rect2 = _jurisdiction_screen_rect(area)
	var font := get_theme_default_font()
	var font_size := 11 if area.kind == "Region" else (10 if area.kind == "County" else 9)
	var width: float = minf(font.get_string_size(_jurisdiction_label_text(area), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0, bounds.size.x - 6.0)
	var top: float = bounds.position.y + 7.0
	if area.kind == "County":
		top = bounds.position.y + bounds.size.y * 0.5 + 3.0
	elif area.kind == "City":
		top = bounds.end.y - 14.0
	return Rect2(Vector2(bounds.position.x + 3.0, top), Vector2(maxf(20.0, width), 14.0 if area.kind == "City" else 18.0))


func _draw_jurisdiction_labels() -> void:
	var font := get_theme_default_font()
	for kind in ["Region", "County", "City"]:
		for area in region.jurisdictions:
			if area.kind != kind:
				continue
			var rect: Rect2 = _jurisdiction_label_rect(area)
			var color: Color = _jurisdiction_color(kind)
			var selected: bool = area.id == selected_jurisdiction_id
			draw_rect(rect, Color("0b1927", 0.82 if kind == "City" else 0.94))
			draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)), Color("fff0b0") if selected else color)
			if selected:
				draw_rect(rect, Color("fff0b0"), false, 1.0)
			var label: String = _jurisdiction_label_text(area)
			var font_size := 11 if kind == "Region" else (10 if kind == "County" else 9)
			while label.length() > 2 and font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > rect.size.x - 8.0:
				label = label.substr(0, label.length() - 2) + "…"
			draw_string(font, rect.position + Vector2(6.0, 10.0 if kind == "City" else 13.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("fff0b0") if selected else color)


func _draw_jurisdiction_key() -> void:
	var font := get_theme_default_font()
	var start := Vector2(size.x - 249.0, 10.0)
	draw_rect(Rect2(start, Vector2(239.0, 25.0)), Color("0b1927", 0.94))
	for item in [
		{"kind": "Region", "label": "Region", "offset": 9.0},
		{"kind": "County", "label": "County", "offset": 85.0},
		{"kind": "City", "label": "City", "offset": 165.0},
	]:
		var x: float = start.x + item["offset"]
		var color: Color = _jurisdiction_color(item["kind"])
		draw_line(Vector2(x, start.y + 13.0), Vector2(x + 12.0, start.y + 13.0), color, 3.0, true)
		draw_string(font, Vector2(x + 17.0, start.y + 17.0), item["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)


func _is_recorded_time() -> bool:
	var requested_bin: int = selected_hour * 4 + floori(hour_fraction * 4.0)
	return requested_bin >= first_recorded_bin and requested_bin < recorded_bin


func _draw_cities() -> void:
	for city in region.cities:
		var center: Vector2 = _world_to_screen(city["center_km"])
		var color: Color = CITY_COLORS[int(city["id"]) % CITY_COLORS.size()]
		var radius: float = 7.5 * _map_scale() * zoom
		draw_circle(center, radius, Color(color.r, color.g, color.b, 0.08))
		draw_arc(center, radius, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.28), 1.0, true)


func _draw_neighborhoods() -> void:
	if detail_level != "Neighborhood":
		for neighborhood in region.neighborhoods:
			draw_circle(_world_to_screen(neighborhood.position_km), 2.5, Color("718899", 0.45))
		return
	if region.accessibility.is_empty():
		return
	var min_access: float = region.accessibility[0]
	var max_access: float = min_access
	for value in region.accessibility:
		min_access = minf(min_access, value)
		max_access = maxf(max_access, value)
	for neighborhood in region.neighborhoods:
		var screen_position: Vector2 = _world_to_screen(neighborhood.position_km)
		var radius: float = _node_radius(neighborhood.population)
		var color := _access_color((region.accessibility[neighborhood.id] - min_access) / maxf(1.0, max_access - min_access))
		draw_circle(screen_position, radius + 3.0, Color("0b1421"))
		draw_circle(screen_position, radius, color)
		draw_arc(screen_position, radius, 0.0, TAU, 32, Color(1, 1, 1, 0.42), 1.0, true)
		var desirability_color := Color("cf6075").lerp(Color("61c99a"), neighborhood.desirability / 100.0)
		draw_arc(screen_position, radius + 2.0, 0.0, TAU, 32, desirability_color, 2.0, true)
		if neighborhood.id == selected_id:
			draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("ffffff"), 2.5, true)
		elif neighborhood.id == hovered_id:
			draw_arc(screen_position, radius + 5.0, 0.0, TAU, 48, Color("a9d7ff"), 2.0, true)
	var label_order: Array[int] = []
	if selected_id >= 0:
		label_order.append(selected_id)
	if hovered_id >= 0 and hovered_id != selected_id:
		label_order.append(hovered_id)
	if zoom >= 1.8:
		for neighborhood in region.neighborhoods:
			if neighborhood.id != selected_id and neighborhood.id != hovered_id:
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
		draw_string(font, label_position + Vector2(1.0, 1.0), neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("07111e"))
		draw_string(font, label_position, neighborhood.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e8f0f7"))


func _draw_hourly_flows() -> void:
	if detail_level != "Neighborhood":
		_draw_aggregate_flows()
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
		_draw_flow_stroke(start_point, end_point, flow_color, line_width, _is_outgoing_from_selected(flow))
		var arrow_tip: Vector2 = end_point
		var arrow_base: Vector2 = end_point - direction * (6.0 + 5.0 * strength)
		var side: Vector2 = Vector2(-direction.y, direction.x) * (3.0 + 2.0 * strength)
		draw_colored_polygon(PackedVector2Array([arrow_tip, arrow_base + side, arrow_base - side]), flow_color)


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


func _draw_flow_stroke(start_point: Vector2, end_point: Vector2, color: Color, width: float, dashed: bool) -> void:
	if not dashed:
		draw_line(start_point, end_point, color, width, true)
		return
	var displacement: Vector2 = end_point - start_point
	var length: float = displacement.length()
	if length <= 0.0:
		return
	var direction: Vector2 = displacement / length
	var offset := 0.0
	while offset < length:
		var dash_end: float = minf(offset + 10.0, length)
		draw_line(start_point + direction * offset, start_point + direction * dash_end, color, width, true)
		offset += 16.0


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


func _draw_legend() -> void:
	var origin := Vector2(18, size.y - 44)
	draw_rect(Rect2(origin - Vector2(9, 110), Vector2(420, 139)), Color(0.04, 0.09, 0.16, 0.90))
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
		draw_line(origin + Vector2(x, -84), origin + Vector2(x + 15.0, -84), swatch_color, 3.0, true)
		draw_string(font, origin + Vector2(x + 21.0, -80), item["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	if selected_id >= 0:
		_draw_flow_stroke(origin + Vector2(0, -62), origin + Vector2(28, -62), Color("dce8f2"), 2.0, true)
		draw_string(font, origin + Vector2(35, -58), "OUT from selected", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
		draw_line(origin + Vector2(191, -62), origin + Vector2(219, -62), Color("dce8f2"), 2.0, true)
		draw_string(font, origin + Vector2(226, -58), "IN to selected", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	else:
		draw_string(font, origin + Vector2(0, -58), "Select a neighborhood for direction styles", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, origin + Vector2(0, -39), "Arrow width and opacity = route flow", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("9db3c5"))
	draw_string(font, origin + Vector2(0, -14), "JOB ACCESSIBILITY", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, origin + Vector2(205, -14), "Node ring = desirability", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	for step in range(8):
		draw_rect(Rect2(origin + Vector2(step * 17.0, 0), Vector2(16, 9)), _access_color(float(step) / 7.0))
	draw_string(font, origin + Vector2(0, 26), "lower", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, origin + Vector2(102, 26), "higher", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("aebfd0"))
	draw_string(font, Vector2(size.x - 178, size.y - 15), "Drag to pan  •  Scroll to zoom", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("8fa4ba"))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and (mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var old_zoom := zoom
			zoom = clampf(zoom * (1.12 if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 1.0, 2.8)
			var ratio := zoom / old_zoom
			pan = mouse_button.position - size * 0.5 - (mouse_button.position - size * 0.5 - pan) * ratio
			queue_redraw()
			accept_event()
		elif mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				hover_world_position = _screen_to_world(mouse_button.position)
				pointer_down = true
				pointer_dragged = false
				pointer_start = mouse_button.position
			else:
				if pointer_down and not pointer_dragged:
					var label_area_id: int = _hit_jurisdiction_label(mouse_button.position)
					if label_area_id >= 0:
						jurisdiction_selected.emit(label_area_id)
						pointer_down = false
						accept_event()
						return
					if map_mode == "Roads":
						var node_id := _hit_road_node(mouse_button.position)
						var link_id := _hit_road_link(mouse_button.position)
						if node_id >= 0:
							road_node_clicked.emit(node_id)
						elif link_id >= 0:
							road_link_clicked.emit(link_id, _screen_to_world(mouse_button.position))
						else:
							var road_area_id: int = -1
							if road_tool == "Inspect":
								road_area_id = _hit_jurisdiction_border(mouse_button.position)
								if road_area_id < 0:
									road_area_id = _jurisdiction_at(mouse_button.position)
							if road_area_id >= 0:
								jurisdiction_selected.emit(road_area_id)
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
			accept_event()
		elif mouse_button.button_index == MOUSE_BUTTON_RIGHT and mouse_button.pressed and map_mode == "Roads":
			road_cancel_requested.emit()
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		hover_world_position = _screen_to_world(motion.position)
		if pointer_down:
			if motion.position.distance_to(pointer_start) > 4.0:
				pointer_dragged = true
			if pointer_dragged:
				pan += motion.relative
				queue_redraw()
		else:
			var new_hover: int = _hit_test(motion.position)
			var hovered_area_id: int = _hit_jurisdiction_label(motion.position)
			if hovered_area_id < 0 and (map_mode == "Trips" or road_tool == "Inspect"):
				hovered_area_id = _hit_jurisdiction_border(motion.position)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hovered_area_id >= 0 or new_hover >= 0 else Control.CURSOR_ARROW
			if new_hover != hovered_id:
				hovered_id = new_hover
				queue_redraw()
			elif preview_start_node >= 0:
				queue_redraw()


func _hit_road_node(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest := -1
	var best := INF
	for node in region.road_nodes:
		var distance: float = screen_position.distance_to(_world_to_screen(node.position_km))
		var hit_radius: float = _node_radius(region.neighborhoods[node.neighborhood_id].population) + 3.0 if node.neighborhood_id >= 0 else 13.0
		if distance <= hit_radius and distance < best:
			best = distance
			closest = node.id
	return closest


func _hit_road_link(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest := -1
	var best := 4.5
	for link in region.road_links:
		var screen_points: PackedVector2Array = _screen_polyline(link.points)
		for direction in range(2):
			for lane_index in range(link.lanes_per_direction):
				var lane_points: PackedVector2Array = _offset_polyline(screen_points, _road_lane_offset(link.lanes_per_direction, direction, lane_index))
				for segment in range(1, lane_points.size()):
					var point: Vector2 = Geometry2D.get_closest_point_to_segment(screen_position, lane_points[segment - 1], lane_points[segment])
					var distance: float = point.distance_to(screen_position)
					if distance < best:
						best = distance
						closest = link.id
	return closest


func _hit_test(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var closest_id := -1
	var closest_distance := INF
	for neighborhood in region.neighborhoods:
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
			if area.kind == kind and _jurisdiction_label_rect(area).has_point(screen_position):
				return area.id
	return -1


func _hit_jurisdiction_border(screen_position: Vector2) -> int:
	if region == null:
		return -1
	for kind in ["Region", "County", "City"]:
		for area in region.jurisdictions:
			if area.kind != kind:
				continue
			var bounds: Rect2 = _jurisdiction_screen_rect(area)
			if screen_position.x >= bounds.position.x - 4.0 and screen_position.x <= bounds.end.x + 4.0 and screen_position.y >= bounds.position.y - 4.0 and screen_position.y <= bounds.end.y + 4.0:
				var edge_distance: float = minf(minf(absf(screen_position.x - bounds.position.x), absf(screen_position.x - bounds.end.x)), minf(absf(screen_position.y - bounds.position.y), absf(screen_position.y - bounds.end.y)))
				if edge_distance <= 4.0:
					return area.id
	return -1


func _jurisdiction_at(screen_position: Vector2) -> int:
	if region == null:
		return -1
	var selected_kind: String = region.jurisdictions[selected_jurisdiction_id].kind if selected_jurisdiction_id >= 0 else "State"
	var target_kind: String = {"State": "Region", "Region": "County", "County": "City", "City": "City", "Neighborhood": "City"}.get(selected_kind, "City")
	if selected_kind in ["Region", "County"] and not _jurisdiction_screen_rect(region.jurisdictions[selected_jurisdiction_id]).has_point(screen_position):
		target_kind = selected_kind
	for area in region.jurisdictions:
		if area.kind == target_kind and _jurisdiction_screen_rect(area).has_point(screen_position):
			return area.id
	return -1


func _map_scale() -> float:
	return maxf(1.0, minf((size.x - 110.0) / WORLD_SIZE.x, (size.y - 110.0) / WORLD_SIZE.y))


func _world_to_screen(world_position: Vector2) -> Vector2:
	return size * 0.5 + pan + (world_position - WORLD_CENTER) * _map_scale() * zoom


func _screen_to_world(screen_position: Vector2) -> Vector2:
	return WORLD_CENTER + (screen_position - size * 0.5 - pan) / (_map_scale() * zoom)


func _node_radius(population: int) -> float:
	return clampf(4.0 + sqrt(float(population)) * 0.05, 6.0, 11.0) * clampf(sqrt(zoom), 0.9, 1.35)


func _access_color(t: float) -> Color:
	return Color("3bb5c8").lerp(Color("f5a45d"), clampf(t, 0.0, 1.0))
