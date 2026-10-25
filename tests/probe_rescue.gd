extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")


func _initialize() -> void:
	var seed_value := 291
	var cities := 32
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("cities="):
			cities = int(argument.split("=")[1])
		elif argument.begins_with("seed="):
			seed_value = int(argument.split("=")[1])
	var region = RegionSetup.build(seed_value, cities, 0.10)["region"]
	var sites: Array[Dictionary] = RoadNetworkGenerator._sites(region)
	var reachable := RoadNetworkGenerator._nodes_reachable(region, region.city_hub_node_ids[region.starting_city_ids[0]])
	var planner = Planner.new(region)
	for city_id in region.starting_city_ids:
		if reachable[region.city_hub_node_ids[city_id]] != 0:
			continue
		var cluster_site := -1
		var gate_distance := INF
		for index in range(sites.size()):
			if int(sites[index]["city"]) != city_id:
				continue
			var trial: float = region.cities[city_id]["center_km"].distance_to(sites[index]["point"])
			if trial < gate_distance:
				gate_distance = trial
				cluster_site = index
		if cluster_site < 0:
			print("city %d has no countryside gate site" % city_id)
			continue
		var origin: Vector2 = sites[cluster_site]["point"]
		var tangent: Vector2 = sites[cluster_site]["tangent"]
		var center: Vector2 = region.cities[city_id]["center_km"]
		print("city %d center %s:" % [city_id, center])
		for index in range(sites.size()):
			if int(sites[index]["city"]) == city_id:
				var site_node = region.road_nodes[sites[index]["node"]]
				print("  site %d at %s (%.1f km from center, kind %s)" % [index, sites[index]["point"], center.distance_to(sites[index]["point"]), site_node.kind])
				for link in region.road_links:
					if link.from_node_id != site_node.id and link.to_node_id != site_node.id:
						continue
					var other_id: int = link.to_node_id if link.from_node_id == site_node.id else link.from_node_id
					var other = region.road_nodes[other_id]
					print("    %s link %d to node %d at %s (city %d, %.1f km long)" % [link.road_class, link.id, other_id, other.position_km, other.city_id, link.length_km])
		var probe_point: Vector2 = sites[cluster_site]["point"]
		print("  city_id_at_point(gate): %d ; city 16 jurisdiction bounds: %s" % [region.city_id_at_point(probe_point), region.jurisdictions[region.city_jurisdiction_ids[city_id]].bounds_km])
		for other_city in region.cities:
			if other_city["id"] != city_id:
				var distance: float = probe_point.distance_to(other_city["center_km"])
				if distance < 45.0:
					print("    near city %d at %s (%.1f km from gate)" % [other_city["id"], other_city["center_km"], distance])
		print("city %d gate %s (tangent %s):" % [city_id, origin, tangent])
		var target: Vector2
		var best := INF
		for index in range(sites.size()):
			if index == cluster_site or reachable[sites[index]["node"]] == 0:
				continue
			var distance: float = origin.distance_to(sites[index]["point"])
			if distance < best:
				best = distance
				target = sites[index]["point"]
		print("  nearest reachable site %s at %.1f km" % [target, best])
		var water_run := 0
		var longest_run := 0.0
		var run_start := 0
		for sample in range(0, 401):
			var point: Vector2 = origin.lerp(target, float(sample) / 400.0)
			if region.terrain.water_at(point):
				if run_start < 0:
					run_start = sample
			else:
				if run_start >= 0:
					var span: float = origin.distance_to(target) * float(sample - run_start) / 400.0
					longest_run = maxf(longest_run, span)
					water_run += 1
				run_start = -1
		print("  water crossings %d, longest %.1f km" % [water_run, longest_run])
		var t0 := Time.get_ticks_msec()
		var direct_search: Dictionary = planner._search(origin, target, "Rural", Vector2.ZERO, true)
		print("  direct _search(long): %s in %d ms" % ["OK" if not direct_search.is_empty() else "FAILED", Time.get_ticks_msec() - t0])
		t0 = Time.get_ticks_msec()
		var plain_search: Dictionary = planner._search(origin, target, "Rural", Vector2.ZERO, false)
		print("  direct _search(plain): %s in %d ms" % ["OK" if not plain_search.is_empty() else "FAILED", Time.get_ticks_msec() - t0])
		var variants: Array[Dictionary] = [
			{"name": "tangent + fine", "tangent": tangent, "fine": true, "long": false},
			{"name": "no tangent + fine", "tangent": Vector2.ZERO, "fine": true, "long": false},
			{"name": "no tangent + long-range", "tangent": Vector2.ZERO, "fine": false, "long": true},
			{"name": "tangent + long-range", "tangent": tangent, "fine": false, "long": true},
		]
		for variant in variants:
			var started: int = Time.get_ticks_msec()
			var trial: Dictionary = planner.route(origin, target, "Rural", variant["tangent"], Vector2.ZERO, variant["fine"], variant["long"])
			var elapsed: int = Time.get_ticks_msec() - started
			var note := "OK" if not trial.is_empty() else "FAILED"
			if not trial.is_empty():
				note += " len %.1f km" % float(trial["length_km"])
			print("  %s: %s (%d ms)" % [variant["name"], note, elapsed])
	print("done")
	quit(0)
