extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Streets = preload("res://scripts/simulation/street_layout_generator.gd")
const Field = preload("res://scripts/simulation/street_direction_field.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var checked := 0
	var widest_gap := 0.0
	for seed_value in [1729, 8752568]:
		var region = Setup.build(seed_value, 256, 0.1)["region"]
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) >= 0:
				continue
			var layout = candidate["layout"]
			if Geography.polygon_area(layout.polygon) < 0.45:
				continue
			var context: Dictionary = Field.city_context(region, int(candidate["city_id"]), layout.bounds)
			for edge_id in range(layout.edges.size()):
				if layout.classes[edge_id] == Roads.ARTERIAL:
					continue
				var edge: Vector2 = layout.edges[edge_id]
				if Streets._near_field_arterial(layout.nodes[int(edge.x)], layout.nodes[int(edge.y)], context, 0.075):
					push_error("Seed %d district %s puts local street %d alongside an arterial." % [seed_value, candidate["key"], edge_id])
					quit(1)
					return
			for x in range(ceili(layout.bounds.size.x / 0.08)):
				for y in range(ceili(layout.bounds.size.y / 0.08)):
					var point: Vector2 = layout.bounds.position + Vector2(x + 0.5, y + 0.5) * 0.08
					if not Geometry2D.is_point_in_polygon(point, layout.polygon):
						continue
					var nearest := INF
					for edge in layout.edges:
						nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])))
					widest_gap = maxf(widest_gap, nearest)
					if nearest > 0.12:
						push_error("Seed %d district %s has a %.3f km roadless gap at %s." % [seed_value, candidate["key"], nearest, point])
						quit(1)
						return
			checked += 1
	if checked < 150:
		push_error("Expected a broad sample of new districts, got %d." % checked)
		quit(1)
		return
	print("%d districts keep local streets clear of arterials and sampled road gaps at or below %.3f km." % [checked, widest_gap])
	quit(0)
