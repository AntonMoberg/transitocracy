extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = null
	var first_id := -1
	for seed_value in [1729, 7113721, 8752568, 5424046, 42, 925731]:
		region = RegionGenerator.generate_large_region(seed_value, 256)
		RoadNetworkGenerator.generate(region)
		DevelopmentPlanner.refresh_candidates(region)
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) < 0 and not candidate["layout"].border_seams.is_empty():
				first_id = int(candidate["id"])
				break
		if first_id >= 0:
			break
	if first_id < 0:
		_fail("The generated map has no proposed district on a city border.")
		return
	var first: Dictionary = region.development_candidates[first_id]
	if not _frontage_covered(region, first):
		_fail("The proposed district leaves a gap behind its border collector.")
		return
	var seam: Dictionary = {}
	for option in first["layout"].border_seams:
		if int(option["anchor"]) >= 0:
			seam = option
			break
	if seam.is_empty():
		_fail("The proposed border collector has no street approach.")
		return
	var seam_key: String = seam["key"]
	region.dev_mode = true
	if not DevelopmentPlanner.set_approval(region, first_id, true).get("ok", false):
		_fail("The first border district could not be approved.")
		return
	var first_neighborhood_id: int = region.development_candidates[first_id]["neighborhood_id"]
	if not StreetNetwork.open_phase(region, region.neighborhoods[first_neighborhood_id], 1):
		_fail("The first border district's street phase did not open.")
		return
	if not region.city_border_seams.has(seam_key):
		_fail("The first border district did not install its shared collector.")
		return
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var seam_link_index: int = RoadGraph.link_index(region, int(region.city_border_seams[seam_key]))
	if seam_link_index < 0:
		_fail("The installed border collector has no road link.")
		return
	var seam_link = region.road_links[seam_link_index]
	if seam_link.border_city_ids != seam["cities"] or rooted[seam_link.from_node_id] == 0 or rooted[seam_link.to_node_id] == 0:
		_fail("The generated border collector did not join the rooted street network.")
		return
	print("Generated border district covers its frontage and opens a rooted shared collector.")
	quit(0)


func _frontage_covered(region, candidate: Dictionary) -> bool:
	var city = region.jurisdictions[region.city_jurisdiction_ids[int(candidate["city_id"])]]
	for seam in candidate["layout"].border_seams:
		var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
		var inward: Vector2 = (seam["to"] - seam["from"]).normalized().orthogonal() * 0.05
		if not city.contains_point(middle + inward):
			inward = -inward
		var covered := 0
		for fraction in [0.25, 0.5, 0.75]:
			var sample: Vector2 = seam["from"].lerp(seam["to"], fraction) + inward
			covered += 1 if Geometry2D.is_point_in_polygon(sample, candidate["polygon"]) else 0
		if covered < 2:
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
