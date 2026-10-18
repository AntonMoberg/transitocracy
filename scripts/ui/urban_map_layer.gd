extends RefCounted

const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const LocalTraffic = preload("res://scripts/simulation/local_street_traffic.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const ZoneColors = {"Residential": Color("929d89"), "Commercial": Color("b9a17a"), "Office": Color("8caaaf"), "Mixed": Color("b2ab8c"), "Industry": Color("8d8f9e")}

var building_cache: Dictionary = {}
var last_street_count: int = 0
var last_building_count: int = 0


func hit_street(map, point: Vector2) -> Vector2i:
	if map._pixels_per_meter() < 0.025:
		return Vector2i(-1, -1)
	var world: Vector2 = map._screen_to_world(point)
	var best := Vector2i(-1, -1)
	var best_distance := 5.0
	for neighborhood in map.region.neighborhoods:
		var layout = neighborhood.street_layout
		if layout == null or not layout.bounds.has_point(world):
			continue
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.LOCAL or layout.phases[edge_id] > neighborhood.development_plan.completed_phase:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var first: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)])
			var last: Vector2 = map._world_to_screen(layout.nodes[int(edge.y)])
			var distance: float = point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last))
			if distance < best_distance:
				best = Vector2i(neighborhood.id, edge_id)
				best_distance = distance
	return best


func draw(map) -> void:
	last_street_count = 0
	last_building_count = 0
	var meters: float = map._pixels_per_meter()
	if meters < 0.025:
		return
	var viewport := Rect2(Vector2.ZERO, map.size)
	for neighborhood in map.region.neighborhoods:
		var layout = neighborhood.street_layout
		var plan = neighborhood.development_plan
		if layout == null or plan == null:
			continue
		var screen_bounds := Rect2(map._world_to_screen(layout.bounds.position), layout.bounds.size * map._map_scale() * map.zoom)
		if not screen_bounds.intersects(viewport):
			continue
		if meters >= 0.08:
			_draw_blocks(map, neighborhood, viewport, meters)
		var record: Dictionary = {}
		if map.live_traffic_state != null:
			record = map.live_traffic_state.local_districts.get(neighborhood.id, {})
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] == Roads.ARTERIAL:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var first: Vector2 = map._world_to_screen(layout.nodes[int(edge.x)])
			var last: Vector2 = map._world_to_screen(layout.nodes[int(edge.y)])
			if not Rect2(first, Vector2.ZERO).expand(last).grow(6.0).intersects(viewport):
				continue
			var built: bool = layout.phases[edge_id] <= plan.completed_phase
			if not built:
				if map.map_mode == "Zoning" or plan.constructing_phase == layout.phases[edge_id]:
					map.draw_dashed_line(first, last, Color("c3ac78", 0.5), 1.0, 5.0, true)
				continue
			if layout.classes[edge_id] != Roads.LOCAL:
				continue
			var width: float = maxf(1.3, meters * 7.0)
			map.draw_line(first, last, Color("17252c"), width + maxf(1.0, meters * 2.0), true)
			var color := Color("6f7f80")
			if not record.is_empty() and map.map_mode == "Roads":
				var rate: Vector2 = LocalTraffic.edge_rate(record, edge_id)
				var queue: Vector2 = record["queues"][edge_id]
				color = map._congestion_color(maxf(rate.x, rate.y) / record["capacity"] + (queue.x + queue.y) / 100.0).lerp(Color("84928b"), 0.5)
			if map.selected_local_street == Vector2i(neighborhood.id, edge_id):
				color = Color("f7e4a0")
			map.draw_line(first, last, color, width, true)
			last_street_count += 1
			if meters >= 0.5:
				map.draw_dashed_line(first, last, Color("b5baa1", 0.5), maxf(0.6, meters * 0.12), meters * 3.0, true)
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
				if Rect2(first, Vector2.ZERO).expand(last).intersects(viewport):
					map.draw_dashed_line(first, last, Color("dbc38a", 0.65), 1.3, 5.0, true)


func _draw_blocks(map, neighborhood, viewport: Rect2, meters: float) -> void:
	var layout = neighborhood.street_layout
	var plan = neighborhood.development_plan
	var occupancy: float = neighborhood.built_fraction
	for block_id in range(layout.blocks.size()):
		var block: Dictionary = layout.blocks[block_id]
		if block["phase"] > plan.completed_phase:
			continue
		var polygon: PackedVector2Array = block["polygon"]
		var bounds := Rect2(map._world_to_screen(polygon[0]), Vector2.ZERO)
		for point in polygon:
			bounds = bounds.expand(map._world_to_screen(point))
		if not bounds.intersects(viewport):
			continue
		if block["park"]:
			map.draw_colored_polygon(map._screen_polyline(polygon), Color("3a5745"))
			continue
		if block_id >= neighborhood.block_zoning.size() or neighborhood.block_zoning[block_id] == 0:
			continue
		var code: int = neighborhood.block_zoning[block_id] - 1
		var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][code / 3]
		var density: int = code % 3
		var key: String = "%d:%d:%s:%d" % [layout.get_instance_id(), block_id, zone, density]
		if not building_cache.has(key):
			if building_cache.size() > 4096:
				building_cache.clear()
			building_cache[key] = LayoutGenerator.buildings(block, zone, density)
		var footprints: Array = building_cache[key]
		for building_id in range(footprints.size()):
			var appearance: float = float(posmod(int(block["seed"]) + building_id * 7919, 1000)) / 1000.0
			if appearance > occupancy:
				continue
			var points: PackedVector2Array = map._screen_polyline(footprints[building_id])
			if meters >= 0.3:
				var shadow := PackedVector2Array()
				for point in points:
					shadow.append(point + Vector2(1.0, 1.5) * minf(3.0, meters * float(density + 1)))
				map.draw_colored_polygon(shadow, Color("14252a", 0.7))
			map.draw_colored_polygon(points, ZoneColors[zone])
			last_building_count += 1


static func _zone(neighborhood, seed_value: int) -> String:
	var chosen: int = posmod(seed_value, 100)
	for zone in ["Residential", "Commercial", "Office", "Mixed", "Industry"]:
		chosen -= int(neighborhood.zone_shares[zone])
		if chosen < 0:
			return zone
	return "Residential"
