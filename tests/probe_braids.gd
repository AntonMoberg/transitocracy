extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_region(1729)
	RoadNetworkGenerator.generate(region)
	var highway_cloud := _cloud(region, func(link): return link.road_class == RoadLinkData.HIGHWAY)
	var rural_highway_km := 0.0
	var worst := 0.0
	var highway_count := 0
	for link in region.road_links:
		if link.road_class == RoadLinkData.HIGHWAY:
			highway_count += 1
		if link.road_class != RoadLinkData.COLLECTOR or link.managed_neighborhood_id >= 0:
			continue
		var overlap := _overlap_with_cloud(_samples(link), highway_cloud)
		rural_highway_km += overlap
		if overlap > worst:
			worst = overlap
			print("  worst link %d: class %s, from %d (%.1f, %.1f) to %d (%.1f, %.1f), overlap %.1f" % [link.id, link.road_class, link.from_node_id, region.road_nodes[link.from_node_id].position_km.x, region.road_nodes[link.from_node_id].position_km.y, link.to_node_id, region.road_nodes[link.to_node_id].position_km.x, region.road_nodes[link.to_node_id].position_km.y, overlap])
	print("rural-vs-highway overlap: total %.1f km, worst link %.1f km over %d highways" % [rural_highway_km, worst, highway_count])
	var rural_links: Array[Dictionary] = []
	for link in region.road_links:
		if link.road_class == RoadLinkData.COLLECTOR and link.managed_neighborhood_id < 0:
			rural_links.append({"link": link, "samples": _samples(link)})
	var braids := 0
	var braid_km := 0.0
	for index in range(rural_links.size()):
		for other in range(index + 1, rural_links.size()):
			var cloud := _cloud_from(_sample_points(rural_links[other]["samples"]))
			var shared := _overlap_with_cloud(rural_links[index]["samples"], cloud)
			if shared > 10.0:
				braids += 1
				braid_km += shared
				print("  braid %.1f km: link %d vs link %d" % [shared, rural_links[index]["link"].id, rural_links[other]["link"].id])
	print("rural-rural braids >10km: %d pairs, %.1f km" % [braids, braid_km])
	quit(0)


static func _samples(link) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var spacing := 2.0
	for index in range(1, link.points.size()):
		var segment: float = link.points[index - 1].distance_to(link.points[index])
		var steps: int = maxi(1, roundi(segment / spacing))
		for step in range(steps):
			result.append({"point": link.points[index - 1].lerp(link.points[index], float(step) / float(steps)), "spacing": segment / float(steps)})
	return result


static func _cloud(region, filter) -> Dictionary:
	var points: Array[Vector2] = []
	for link in region.road_links:
		if not filter.call(link):
			continue
		for sample in _samples(link):
			points.append(sample["point"])
	return _cloud_from(points)


static func _sample_points(samples: Array[Dictionary]) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for sample in samples:
		points.append(sample["point"])
	return points


static func _cloud_from(points) -> Dictionary:
	var cloud := {}
	for point in points:
		var key := Vector2i(floori(point.x / 2.0), floori(point.y / 2.0))
		if not cloud.has(key):
			cloud[key] = []
		cloud[key].append(point)
	return cloud


static func _overlap_with_cloud(samples: Array[Dictionary], cloud: Dictionary) -> float:
	var shared := 0.0
	for sample in samples:
		var point: Vector2 = sample["point"]
		var base := Vector2i(floori(point.x / 2.0), floori(point.y / 2.0))
		var near := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for other in cloud.get(Vector2i(base.x + dx, base.y + dy), []):
					if point.distance_to(other) < 1.0:
						near = true
						break
				if near:
					break
			if near:
				break
		if near:
			shared += float(sample["spacing"])
	return shared
