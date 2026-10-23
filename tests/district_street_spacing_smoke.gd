extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const StreetLayoutOps = preload("res://scripts/simulation/street_layout_ops.gd")
const Field = preload("res://scripts/simulation/street_direction_field.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")


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
				if layout.classes[edge_id] != Roads.LOCAL:
					continue
				var edge: Vector2 = layout.edges[edge_id]
				if StreetLayoutOps._near_field_arterial(layout.nodes[int(edge.x)], layout.nodes[int(edge.y)], context, 0.075):
					push_error("Seed %d district %s puts local street %d alongside an arterial." % [seed_value, candidate["key"], edge_id])
					quit(1)
					return
			for x in range(ceili(layout.bounds.size.x / 0.08)):
				for y in range(ceili(layout.bounds.size.y / 0.08)):
					var point: Vector2 = layout.bounds.position + Vector2(x + 0.5, y + 0.5) * 0.08
					if not Geometry2D.is_point_in_polygon(point, layout.polygon):
						continue
					if region.terrain != null and not region.terrain.buildable_at(point):
						continue
					var nearest := INF
					for edge in layout.edges:
						nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, layout.nodes[int(edge.x)], layout.nodes[int(edge.y)])))
					if nearest > 0.12:
						# Perimeter streets may be omitted when a built arterial
						# already serves the same strip of the district.
						var nearby: Dictionary = Spatial.cache(region)["arterials"]
						var grid := Vector2i(floori(point.x), floori(point.y))
						var seen: Dictionary = {}
						for offset_y in range(-1, 2):
							for offset_x in range(-1, 2):
								for link_index in nearby.get(grid + Vector2i(offset_x, offset_y), []):
									if seen.has(link_index):
										continue
									seen[link_index] = true
									var link = region.road_links[link_index]
									for segment in range(1, link.points.size()):
										nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, link.points[segment - 1], link.points[segment])))
					widest_gap = maxf(widest_gap, nearest)
					if nearest > 0.12:
						push_error("Seed %d district %s has a %.3f km roadless gap at %s." % [seed_value, candidate["key"], nearest, point])
						quit(1)
						return
			checked += 1
	if checked < 60:
		push_error("Expected a broad sample of new districts, got %d." % checked)
		quit(1)
		return
	print("%d districts keep local streets clear of arterials and sampled road gaps at or below %.3f km." % [checked, widest_gap])
	quit(0)
