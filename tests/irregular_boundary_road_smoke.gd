extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Streets = preload("res://scripts/simulation/street_layout_generator.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var checked := 0
	for seed_value in [5424046, 8752568, 1729]:
		var region = Setup.build(seed_value, 256, 0.1)["region"]
		var key: String = {5424046: "130:382:344:234:1", 8752568: "136:315:424:27:1", 1729: "205:441:510:284:1"}[seed_value]
		var found := false
		for candidate in region.development_candidates:
			if candidate["key"] != key:
				continue
			found = true
			var layout = candidate["layout"]
			var total := 0.0
			var roaded := 0.0
			for segment in range(layout.polygon.size()):
				var first: Vector2 = layout.polygon[segment]
				var last: Vector2 = layout.polygon[(segment + 1) % layout.polygon.size()]
				var length: float = first.distance_to(last)
				var samples: int = maxi(1, ceili(length / 0.06))
				total += length
				for sample_id in range(samples):
					var point: Vector2 = first.lerp(last, (float(sample_id) + 0.5) / float(samples))
					for edge in layout.edges:
						if point.distance_to(Geometry2D.get_closest_point_to_segment(point, layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])) < 0.015:
							roaded += length / float(samples)
							break
			var connected: Dictionary = Streets._arterial_reachable_nodes(layout)
			var local_boundary_length := 0.0
			var first_phase_boundary_length := 0.0
			var disconnected_boundary_length := 0.0
			for edge_id in range(layout.edges.size()):
				if layout.classes[edge_id] != Roads.LOCAL:
					continue
				var edge: Vector2 = layout.edges[edge_id]
				var start_id: int = int(edge.x)
				var end_id: int = int(edge.y)
				var start: Vector2 = layout.nodes[start_id]
				var end: Vector2 = layout.nodes[end_id]
				if _outline_distance(start, layout.polygon) > 0.003 or _outline_distance(end, layout.polygon) > 0.003:
					continue
				var length: float = start.distance_to(end)
				local_boundary_length += length
				if layout.phases[edge_id] == 1:
					first_phase_boundary_length += length
				if not connected.has(start_id) or not connected.has(end_id):
					disconnected_boundary_length += length
			if roaded / total < 0.90 or local_boundary_length < 0.5 or first_phase_boundary_length < 0.5 or disconnected_boundary_length > 0.1:
				push_error("Seed %d candidate %s leaves its irregular edge unserved: %.1f%% roaded, %.2f km local edge, %.2f km first phase, %.2f km disconnected." % [seed_value, key, roaded / total * 100.0, local_boundary_length, first_phase_boundary_length, disconnected_boundary_length])
				quit(1)
				return
			if seed_value == 8752568 and not _pointed_tip_serviced(region):
				quit(1)
				return
			checked += 1
			break
		if not found:
			push_error("Missing irregular candidate %s for seed %d." % [key, seed_value])
			quit(1)
			return
	print("%d irregular candidates have roaded edges connected to their street networks." % checked)
	quit(0)


func _outline_distance(point: Vector2, polygon: PackedVector2Array) -> float:
	var distance := INF
	for segment in range(polygon.size()):
		distance = minf(distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[segment], polygon[(segment + 1) % polygon.size()])))
	return distance


func _pointed_tip_serviced(region) -> bool:
	for candidate in region.development_candidates:
		if candidate["key"] != "136:315:422:26:1":
			continue
		var layout = candidate["layout"]
		if layout.polygon.size() != 3:
			break
		var tip := Vector2.ZERO
		var smallest_angle := INF
		for index in range(3):
			var before: Vector2 = layout.polygon[(index + 2) % 3] - layout.polygon[index]
			var after: Vector2 = layout.polygon[(index + 1) % 3] - layout.polygon[index]
			var angle: float = absf(before.angle_to(after))
			if angle < smallest_angle:
				smallest_angle = angle
				tip = layout.polygon[index]
		var disk := PackedVector2Array()
		for index in range(32):
			var angle: float = TAU * float(index) / 32.0
			disk.append(tip + Vector2(cos(angle), sin(angle)) * 0.35)
		var land_area := 0.0
		for piece in Geometry2D.intersect_polygons(layout.polygon, disk):
			land_area += Geography.polygon_area(piece)
		var serviced_area := 0.0
		for block in layout.blocks:
			if block["phase"] != 1:
				continue
			for piece in Geometry2D.intersect_polygons(block["polygon"], disk):
				serviced_area += Geography.polygon_area(piece)
		if land_area <= 0.01 or serviced_area / land_area <= 0.85:
			push_error("Acute triangular tip remains undeveloped in the first serviced phase: %.1f%%." % [serviced_area / maxf(0.001, land_area) * 100.0])
			return false
		var max_gap := 0.0
		var samples := 0
		for grid_x in range(ceili(layout.bounds.size.x / 0.04)):
			for grid_y in range(ceili(layout.bounds.size.y / 0.04)):
				var point: Vector2 = layout.bounds.position + Vector2(grid_x + 0.5, grid_y + 0.5) * 0.04
				if not Geometry2D.is_point_in_polygon(point, layout.polygon) or _outline_distance(point, layout.polygon) < 0.04:
					continue
				var nearest := INF
				for edge_id in range(layout.edges.size()):
					if layout.classes[edge_id] == Roads.ARTERIAL:
						continue
					var edge: Vector2 = layout.edges[edge_id]
					var first: Vector2 = layout.nodes[int(edge.x)]
					var last: Vector2 = layout.nodes[int(edge.y)]
					if _outline_distance((first + last) * 0.5, layout.polygon) < 0.003:
						continue
					nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, first, last)))
				max_gap = maxf(max_gap, nearest)
				samples += 1
		if samples < 40 or max_gap > 0.15:
			push_error("Acute triangular zone still has a roadless cap: %.3f km from an interior street across %d samples." % [max_gap, samples])
			return false
		return true
	push_error("Missing triangular candidate for pointed-tip regression check.")
	return false
