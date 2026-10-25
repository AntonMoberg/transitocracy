extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = RegionSetup.build(1729, 256, 0.1)
	var region = result["region"]
	var accessibility_before: float = region.accessibility[0]
	var flow_before = TripFlowCalculator.build(region)
	var origin_before: float = flow_before.compact_origin_daily["Work"][0]
	# The settlement's whole urban web — hub, collector grid, arterial spokes and
	# the promoted spur out to its interchange — is one component. Cutting
	# every unmanaged link that touches it must drop its neighborhoods off the
	# region; only the protected neighborhood street grids stay behind.
	var hub_id: int = region.city_hub_node_ids[region.neighborhoods[0].city_id]
	var web_nodes := {hub_id: true}
	var queue: Array[int] = [hub_id]
	var cursor := 0
	while cursor < queue.size():
		var node_id: int = queue[cursor]
		cursor += 1
		for link in region.road_links:
			if link.road_class != "Collector" and link.road_class != "Arterial":
				continue
			var other: int = -1
			if link.from_node_id == node_id:
				other = link.to_node_id
			elif link.to_node_id == node_id:
				other = link.from_node_id
			if other >= 0 and not web_nodes.has(other):
				web_nodes[other] = true
				queue.append(other)
	var cut_ids: Array[int] = []
	for link in region.road_links:
		if web_nodes.has(link.from_node_id) or web_nodes.has(link.to_node_id):
			cut_ids.append(link.id)
	var started: int = Time.get_ticks_usec()
	var removed := 0
	for link_id in cut_ids:
		if RoadPlanner.demolish(region, link_id).get("ok", false):
			removed += 1
	var demolition_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	AccessibilityCalculator.recalculate(region)
	region.city_od_candidates.clear()
	var flow = TripFlowCalculator.build(region)
	var fragment := {}
	for neighborhood_id in range(region.neighborhoods.size()):
		if web_nodes.has(region.neighborhood_gateway_node_ids[neighborhood_id]):
			fragment[neighborhood_id] = true
	var errors := PackedStringArray()
	if removed == 0:
		errors.append("Road demolition did not cut the city's web.")
	if region.accessibility[0] >= accessibility_before:
		errors.append("Cut settlement retained its regional job access.")
	for neighborhood_id in range(region.neighborhoods.size()):
		if fragment.has(neighborhood_id):
			continue
		if region.travel_time_between(0, neighborhood_id) < 1000000.0:
			errors.append("Cut settlement retained a route to neighborhood %d." % neighborhood_id)
			break
	if flow.compact_origin_daily["Work"][0] >= origin_before:
		errors.append("Cut settlement retained its regional commute demand.")
	print("Large road demolition: %.1f ms; %d of %d web links removed; %d neighborhoods in the protected fragment" % [demolition_ms, removed, cut_ids.size(), fragment.size()])
	if not errors.is_empty():
		push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
