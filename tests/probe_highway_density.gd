extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var seed := 3819
	var cities := 256
	for arg in args:
		if arg.begins_with("seed="):
			seed = int(arg.substr(5))
		elif arg.begins_with("cities="):
			cities = int(arg.substr(7))
	var region = RegionSetup.build(seed, cities, 0.10)["region"]
	var highway_lengths: Array[float] = []
	for link in region.road_links:
		if link.road_class == "Highway":
			highway_lengths.append(link.length_km)
	highway_lengths.sort()
	print("seed %d cities %d: %d highway links" % [seed, cities, highway_lengths.size()])
	if highway_lengths.size() > 0:
		var tiny := 0
		var short := 0
		for length in highway_lengths:
			if length < 0.05:
				tiny += 1
			elif length < 0.5:
				short += 1
		print("  min %.3f km, p10 %.3f, median %.3f, max %.3f" % [highway_lengths[0], highway_lengths[int(highway_lengths.size() * 0.1)], highway_lengths[highway_lengths.size() / 2], highway_lengths[-1]])
		print("  fragments <50m: %d, <500m: %d" % [tiny, short])
	var interchange_nodes := 0
	var links_at := {}
	for link in region.road_links:
		if link.road_class != "Highway":
			continue
		for node_id in [link.from_node_id, link.to_node_id]:
			if not links_at.has(node_id):
				links_at[node_id] = {}
			links_at[node_id][link.corridor_id] = true
	var spur_junctions := 0
	var pair_junctions := 0
	var pair_points := {}
	for node in region.road_nodes:
		var corridors: Array = links_at.get(node.id, {}).keys()
		if corridors.size() >= 2:
			interchange_nodes += 1
			pair_junctions += 1
			corridors.sort()
			for i in range(corridors.size()):
				for j in range(i + 1, corridors.size()):
					var key := "%d|%d" % [corridors[i], corridors[j]]
					if not pair_points.has(key):
						pair_points[key] = []
					pair_points[key].append(node.position_km)
		elif corridors.size() == 1 and node.is_interchange:
			interchange_nodes += 1
			spur_junctions += 1
	var multi := 0
	var min_gap := INF
	var pair_sizes := {}
	for key in pair_points:
		var points: Array = pair_points[key]
		pair_sizes[key] = points.size()
		if points.size() > 1:
			multi += 1
			for i in range(points.size()):
				for j in range(i + 1, points.size()):
					min_gap = minf(min_gap, points[i].distance_to(points[j]))
	var top_pairs := pair_sizes.values()
	top_pairs.sort()
	top_pairs.reverse()
	print("  pair junction counts (top 10): %s" % str(top_pairs.slice(0, 10)))
	print("  interchange nodes: %d (trunk-pair %d, spur %d), pairs with multiple junctions: %d, closest same-pair: %.3f km" % [interchange_nodes, pair_junctions, spur_junctions, multi, min_gap])
	var corridor_links := {}
	for link in region.road_links:
		if link.road_class != "Highway":
			continue
		corridor_links[link.corridor_id] = corridor_links.get(link.corridor_id, 0) + 1
	var worst := corridor_links.values()
	worst.sort()
	worst.reverse()
	print("  trunk corridors: %d, links per corridor (top 10): %s" % [corridor_links.size(), str(worst.slice(0, 10))])
	quit(0)
