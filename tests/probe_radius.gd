extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")


func _initialize() -> void:
	var cities := 32
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("cities="):
			cities = int(argument.split("=")[1])
	var region = RegionSetup.build(3819, cities, 0.10)["region"]
	for link in region.road_links:
		if link.road_class != "Highway":
			continue
		var minimum := INF
		var worst := -1
		for index in range(1, link.points.size() - 1):
			var before: Vector2 = link.points[index] - link.points[index - 1]
			var after: Vector2 = link.points[index + 1] - link.points[index]
			if before.length() < 0.005 or after.length() < 0.005:
				continue
			var cross: float = absf(before.cross(after))
			if cross < 0.00000001:
				continue
			var radius: float = before.length() * after.length() * (before + after).length() / (2.0 * cross)
			if radius < minimum:
				minimum = radius
				worst = index
		var tunnel := ""
		for span in link.terrain_spans:
			if span.kind == "Tunnel":
				tunnel += " [tunnel %.1fkm]" % span.length_km
		if minimum < 2.1:
			var turn: float = rad_to_deg((link.points[worst] - link.points[worst - 1]).angle_to(link.points[worst + 1] - link.points[worst]))
			print("link %d radius %.3f at %s (turn %.1f deg) len %.1f%s" % [link.id, minimum, link.points[worst], absf(turn), link.length_km, tunnel])
			for offset in range(-3, 4):
				var index := worst + offset
				if index < 0 or index >= link.points.size():
					continue
				var note := ""
				if index > 0:
					note += " <-%.4f" % link.points[index].distance_to(link.points[index - 1])
				if index < link.points.size() - 1:
					note += " %.4f->" % link.points[index].distance_to(link.points[index + 1])
				print("   %d: %s%s" % [index, link.points[index], note])
	print("done")
	quit(0)
