extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const Region = preload("res://scripts/simulation/region_data.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const NodeData = preload("res://scripts/simulation/road_node_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(1729, 256, 0.1)["region"]
	var checked_frontages := 0
	var square_blocks := 0
	var rectangular_blocks := 0
	var fringe_blocks := 0
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or not candidate["layout_input"].get("edge_frontage", false) or not candidate["layout_input"].get("boundaries", []).is_empty():
			continue
		var layout = candidate["layout"]
		var covered_area := 0.0
		for block in layout.blocks:
			var polygon: PackedVector2Array = block["polygon"]
			covered_area += Geography.polygon_area(polygon)
			fringe_blocks += 1 if block.get("fringe", false) else 0
			if polygon.size() != 4:
				continue
			var width: float = polygon[0].distance_to(polygon[1])
			var depth: float = polygon[1].distance_to(polygon[2])
			var aspect: float = maxf(width, depth) / maxf(0.001, minf(width, depth))
			if aspect < 1.25:
				square_blocks += 1
			elif aspect > 1.45:
				rectangular_blocks += 1
		if covered_area < Geography.polygon_area(layout.polygon) * 0.95:
			push_error("Candidate %s leaves too much boundary land without blocks (%.2f coverage, guide %s)" % [candidate["key"], covered_area / Geography.polygon_area(layout.polygon), candidate["layout_input"].get("grid_guide", {}).get("source_key", "corridor")])
			quit(1)
			return
		var origins := PackedVector2Array()
		for edge_id in range(layout.edges.size()):
			if layout.classes[edge_id] != Roads.COLLECTOR:
				continue
			var edge: Vector2 = layout.edges[edge_id]
			var first: int = int(edge.x)
			var last: int = int(edge.y)
			if layout.arterial_nodes.has(first) != layout.arterial_nodes.has(last):
				origins.append(layout.nodes[first] if layout.arterial_nodes.has(first) else layout.nodes[last])
		if origins.size() < 1 or origins.size() > 2:
			push_error("One-sided plans need one or two collector entrances, got %d for %s" % [origins.size(), candidate["key"]])
			quit(1)
			return
		if origins.size() == 2 and origins[0].distance_to(origins[1]) < 0.36:
			push_error("Collector entrances are nearly parallel at %s" % candidate["key"])
			quit(1)
			return
		checked_frontages += 1
	if checked_frontages < 2:
		push_error("Expected several one-sided candidate layouts")
		quit(1)
		return
	if rectangular_blocks <= square_blocks * 2 or fringe_blocks == 0:
		push_error("One-sided plans should be mostly rectangular: %d square, %d rectangular" % [square_blocks, rectangular_blocks])
		quit(1)
		return
	var best := {}
	var best_score := 0.0
	for first in region.development_candidates:
		if int(first["neighborhood_id"]) >= 0 or not first["layout_input"].get("edge_frontage", false):
			continue
		for second in region.development_candidates:
			if int(second["id"]) <= int(first["id"]) or int(second["neighborhood_id"]) >= 0 or int(second["city_id"]) != int(first["city_id"]) or String(second["key"]).get_slice(":", 4) != String(first["key"]).get_slice(":", 4):
				continue
			var first_layout = first["layout"]
			var second_layout = second["layout"]
			var score: float = Planner._adjacency_score(first_layout.polygon, [second_layout.polygon])
			if score > best_score:
				best_score = score
				best = {"first": first, "second": second}
	if best.is_empty():
		push_error("No adjacent candidate pair")
		quit(1)
		return
	var first: Dictionary = best["first"]
	var second: Dictionary = best["second"]
	for candidate in [first, second]:
		var layout = candidate["layout"]
		for path in layout.core_paths:
			if path.get("road_class", Roads.COLLECTOR) == Roads.ARTERIAL:
				push_error("A one-sided plan proposed a new arterial.")
				quit(1)
				return
	region.jurisdictions[region.city_jurisdiction_ids[first["city_id"]]].treasury = 1000000000.0
	if not Planner.set_approval(region, first["id"], true).get("ok", false):
		push_error("Could not approve first plan")
		quit(1)
		return
	var first_neighborhood = region.neighborhoods[first["neighborhood_id"]]
	for phase in [1, 2, 3]:
		StreetNetwork.open_phase(region, first_neighborhood, phase)
	Planner.refresh_candidates(region)
	var next_candidate := {}
	var next_score := -INF
	for candidate in region.development_candidates:
		if candidate["neighborhood_id"] >= 0 or candidate["city_id"] != first["city_id"] or not candidate["layout_input"].get("edge_frontage", false):
			continue
		var score: float = Planner._adjacency_score(candidate["polygon"], [first_neighborhood.street_layout.polygon]) - candidate["center_km"].distance_to(second["center_km"])
		if score > next_score:
			next_score = score
			next_candidate = candidate
	if next_candidate.is_empty() or next_score <= 0.0 or not Planner.set_approval(region, next_candidate["id"], true).get("ok", false):
		push_error("Could not approve an adjacent second plan")
		quit(1)
		return
	if not Planner._shared_boundary_on_arterial(region, next_candidate["polygon"], first_neighborhood.street_layout.polygon):
		var guide: Dictionary = next_candidate["layout_input"].get("grid_guide", {})
		if guide.is_empty() or absf(next_candidate["layout"].grid_axis.dot(first_neighborhood.street_layout.grid_axis)) < 0.94:
			push_error("An adjacent plan without an arterial boundary should continue its neighbor's grid")
			quit(1)
			return
		if next_candidate["layout"].grid_origin.distance_to(guide["origin"]) > 0.001:
			push_error("A continued grid must retain its neighbor's alignment origin")
			quit(1)
			return
	var second_neighborhood = region.neighborhoods[next_candidate["neighborhood_id"]]
	for phase in [1, 2, 3]:
		StreetNetwork.open_phase(region, second_neighborhood, phase)
	var new_arterials := 0
	var connectors := 0
	var connector_length := 0.0
	for link in region.road_links:
		if link.road_class == Roads.ARTERIAL and link.managed_neighborhood_id in [first_neighborhood.id, second_neighborhood.id]:
			new_arterials += 1
		if link.road_class == Roads.COLLECTOR and link.managed_neighborhood_id == second_neighborhood.id and ((first_neighborhood.access_node_ids.has(link.from_node_id) and second_neighborhood.access_node_ids.has(link.to_node_id)) or (first_neighborhood.access_node_ids.has(link.to_node_id) and second_neighborhood.access_node_ids.has(link.from_node_id))):
			connectors += 1
			connector_length += link.length_km
	if new_arterials != 0 or connectors < 1 or connectors > 2 or connector_length > 0.65:
		push_error("Adjacent development must connect collector networks without long detours or new arterials: %d arterial, %d connectors, %.2f km" % [new_arterials, connectors, connector_length])
		quit(1)
		return
	if not _check_local_fallback():
		quit(1)
		return
	print("Adjacent plans connect by %d collector links (%.2f km total); offset local streets also join." % [connectors, connector_length])
	quit(0)


func _check_local_fallback() -> bool:
	var region = Region.new()
	region.city_jurisdiction_ids.append(1)
	for point in [Vector2(0.7, 0), Vector2(1.3, 0), Vector2(0.7, 0.2), Vector2(1.3, 0.2)]:
		var node = NodeData.new()
		node.id = region.road_nodes.size()
		node.city_id = 0
		node.position_km = point
		region.road_nodes.append(node)
	for pair in [Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 3)]:
		var link = Roads.new()
		link.id = region.road_links.size()
		link.from_node_id = pair.x
		link.to_node_id = pair.y
		link.road_class = Roads.ARTERIAL if pair == Vector2i(0, 1) else Roads.COLLECTOR
		link.points = PackedVector2Array([region.road_nodes[pair.x].position_km, region.road_nodes[pair.y].position_km])
		link.recalculate_length()
		region.road_links.append(link)
	region.next_road_link_id = region.road_links.size()
	for id in range(2):
		var neighborhood = Neighborhood.new()
		neighborhood.id = id
		neighborhood.city_id = 0
		var layout = Layout.new()
		layout.polygon = PackedVector2Array([Vector2(id, 0), Vector2(id + 1, 0), Vector2(id + 1, 1), Vector2(id, 1)])
		layout.bounds = Rect2(Vector2(id, 0), Vector2.ONE)
		layout.nodes = PackedVector2Array([region.road_nodes[id].position_km, region.road_nodes[id + 2].position_km, Vector2(0.92 if id == 0 else 1.08, 0.5)])
		layout.edges = PackedVector2Array([Vector2(0, 1), Vector2(1, 2)])
		layout.classes = PackedStringArray([Roads.COLLECTOR, Roads.LOCAL])
		layout.phases = PackedInt32Array([1, 1])
		layout.lengths = PackedFloat32Array([0.2, layout.nodes[1].distance_to(layout.nodes[2])])
		layout.arterial_nodes = PackedInt32Array([0])
		neighborhood.street_layout = layout
		var plan = Plan.new()
		plan.completed_phase = 1
		plan.installed_multiplier = 1.0
		plan.core_node_ids = {0: id, 1: id + 2}
		neighborhood.development_plan = plan
		neighborhood.access_node_ids.append(id + 2)
		region.neighborhoods.append(neighborhood)
	StreetNetwork._join_adjacent_districts(region, region.neighborhoods[0])
	StreetNetwork._join_adjacent_districts(region, region.neighborhoods[0])
	var local_links := 0
	for link in region.road_links:
		if link.road_class == Roads.LOCAL:
			local_links += 1
	if local_links != 3 or not region.neighborhoods[0].development_plan.core_node_ids.has(2) or not region.neighborhoods[1].development_plan.core_node_ids.has(2):
		push_error("Offset neighborhood streets did not connect through their existing local grids")
		return false
	return true
