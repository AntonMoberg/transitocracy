extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(8752568, 256, 0.1)["region"]
	var city_id := 136
	if region.cities[city_id]["name"] != "Port Union 9":
		_fail("Seed 8752568 no longer places Port Union 9 at city 136.")
		return
	var wrapping_key := "136:314:423:27:1"
	var northeast_key := "136:310:424:27:1"
	var thin_tail_key := "136:310:424:27:-1"
	for key in [wrapping_key, northeast_key, thin_tail_key]:
		if not region.development_candidate_keys.has(key):
			_fail("Port Union 9 lost candidate %s." % key)
			return
	var wrapping: Dictionary = region.development_candidates[region.development_candidate_keys[wrapping_key]]
	var northeast: Dictionary = region.development_candidates[region.development_candidate_keys[northeast_key]]
	var thin_tail: Dictionary = region.development_candidates[region.development_candidate_keys[thin_tail_key]]
	if Geography._bounds(wrapping["polygon"]).size.y > 0.9 or Geography.polygon_area(wrapping["polygon"]) < 0.35:
		_fail("The western zone still wraps around the starter neighborhood or lost its usable core.")
		return
	if Geography._bounds(northeast["polygon"]).size.x > 1.0 or Geography.polygon_area(northeast["polygon"]) < 0.5:
		_fail("The northeastern zone still has a thin western extension or lost its usable core.")
		return
	if Geography._bounds(thin_tail["polygon"]).size.x > 0.8 or Geography.polygon_area(thin_tail["polygon"]) < 0.18:
		_fail("The eastern candidate still contains its long, narrow tail or lost its viable core.")
		return
	for candidate in region.development_candidates:
		if candidate["city_id"] != city_id or candidate["neighborhood_id"] >= 0:
			continue
		if not _streets_reach_frontage(candidate["layout"]):
			_fail("Candidate %s has street segments disconnected from its arterial frontage." % candidate["key"])
			return
	region.jurisdictions[region.city_jurisdiction_ids[city_id]].treasury = 1000000000.0
	var result: Dictionary = Planner.set_approval(region, wrapping["id"], true)
	if not result.get("ok", false):
		_fail("The repaired Port Union candidate cannot be approved: %s" % result)
		return
	var neighborhood_id: int = region.development_candidates[wrapping["id"]]["neighborhood_id"]
	if neighborhood_id < 0 or not _streets_reach_frontage(region.neighborhoods[neighborhood_id].street_layout):
		_fail("Approving the repaired candidate left disconnected streets.")
		return
	print("Port Union 9 candidates keep usable cores, remove thin tails, and connect all street segments to frontage.")
	quit(0)


func _streets_reach_frontage(layout) -> bool:
	var links: Array = []
	links.resize(layout.nodes.size())
	for node_id in range(layout.nodes.size()):
		links[node_id] = []
	for edge in layout.edges:
		links[int(edge.x)].append(int(edge.y))
		links[int(edge.y)].append(int(edge.x))
	var reached: Dictionary = {}
	var queue: Array[int] = []
	for node_id in layout.arterial_nodes:
		reached[node_id] = true
		queue.append(node_id)
	var cursor := 0
	while cursor < queue.size():
		for neighbor in links[queue[cursor]]:
			if not reached.has(neighbor):
				reached[neighbor] = true
				queue.append(neighbor)
		cursor += 1
	for node_id in range(layout.nodes.size()):
		if not links[node_id].is_empty() and not reached.has(node_id):
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
