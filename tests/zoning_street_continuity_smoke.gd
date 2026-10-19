extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(1729, 256, 0.1)["region"]
	var seams := 0
	var approaches := 0
	var matched := 0
	var through_approaches := 0
	var through_matched := 0
	for first in region.development_candidates:
		if int(first["neighborhood_id"]) >= 0 or (not first["layout_input"].get("edge_frontage", false) and not String(first["key"]).contains(":through")):
			continue
		for second in region.development_candidates:
			if int(second["id"]) <= int(first["id"]) or int(second["neighborhood_id"]) >= 0 or int(first["city_id"]) != int(second["city_id"]) or (not second["layout_input"].get("edge_frontage", false) and not String(second["key"]).contains(":through")):
				continue
			var through: bool = String(first["key"]).contains(":through") or String(second["key"]).contains(":through")
			if absf(first["layout"].grid_axis.dot(second["layout"].grid_axis)) < 0.98:
				continue
			if Planner._shared_edge_length(first["polygon"], second["polygon"]) < 0.5 or Planner._shared_boundary_on_arterial(region, first["polygon"], second["polygon"]):
				continue
			var result: Vector2i = _street_approaches(first["layout"], second["layout"])
			if result.x < 2:
				continue
			if through:
				through_approaches += result.x
				through_matched += result.y
				continue
			seams += 1
			approaches += result.x
			matched += result.y
	if seams < 5 or approaches < 35 or float(matched) / float(approaches) < 0.85 or through_approaches < 4 or float(through_matched) / float(through_approaches) < 0.7:
		push_error("New zone grids leave too many streets ending at shared boundaries: %d/%d regular and %d/%d through-road approaches matched across %d seams." % [matched, approaches, through_matched, through_approaches, seams])
		quit(1)
		return
	print("New zone grids align %d/%d local and collector approaches across %d shared seams; through-road seams %d/%d." % [matched, approaches, seams, through_matched, through_approaches])
	quit(0)


func _street_approaches(layout, other) -> Vector2i:
	var seen: Dictionary = {}
	var total := 0
	var matched := 0
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] == Roads.ARTERIAL:
			continue
		var pair: Vector2 = layout.edges[edge_id]
		for node_id in [int(pair.x), int(pair.y)]:
			if seen.has(node_id):
				continue
			seen[node_id] = true
			var point: Vector2 = layout.nodes[node_id]
			if _outline_distance(point, other.polygon) > 0.005 or _outline_distance(point, layout.polygon) > 0.005:
				continue
			total += 1
			for other_edge_id in range(other.edges.size()):
				if other.classes[other_edge_id] == Roads.ARTERIAL:
					continue
				var other_pair: Vector2 = other.edges[other_edge_id]
				if point.distance_to(other.nodes[int(other_pair.x)]) < 0.015 or point.distance_to(other.nodes[int(other_pair.y)]) < 0.015:
					matched += 1
					break
	return Vector2i(total, matched)


func _outline_distance(point: Vector2, polygon: PackedVector2Array) -> float:
	var closest := INF
	for index in range(polygon.size()):
		closest = minf(closest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])))
	return closest
