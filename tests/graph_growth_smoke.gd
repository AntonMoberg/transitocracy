extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = Setup.build(42, 32, 0.1)
	var region = result["region"]
	if not result["errors"].is_empty():
		push_error("Initial graph invalid: %s" % result["errors"])
		quit(1)
		return
	if region.urban_sector_claims.is_empty() or region.urban_plan_edges.is_empty():
		push_error("Starting cities did not use the shared graph")
		quit(1)
		return
	var choice := -1
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and candidate.has("urban_sector"):
			choice = int(candidate["id"])
			break
	if choice < 0:
		push_error("No graph growth proposal")
		quit(1)
		return
	var candidate: Dictionary = region.development_candidates[choice]
	var first_key: String = candidate["key"]
	var first_sector: Vector2i = candidate["urban_sector"]
	var base_blocks: int = candidate["layout"].blocks.size()
	var base_spacing: float = candidate["layout"].grid_row_spacing_km
	if not Planner.set_candidate_design(region, choice, 1):
		push_error("Second graph design failed")
		quit(1)
		return
	var design: Dictionary = region.development_candidates[choice]
	if design["layout"].grid_row_spacing_km != base_spacing or design["layout"].blocks.size() >= base_blocks:
		push_error("Alternative design did not preserve street addresses while changing blocks")
		quit(1)
		return
	region.dev_mode = true
	var approved: Dictionary = Planner.set_approval(region, choice, true)
	if not approved["ok"] or not region.urban_sector_claims.has(UrbanGraph.sector_key(int(design["city_id"]), first_sector)):
		push_error("Graph design could not be approved: %s" % approved)
		quit(1)
		return
	Planner.refresh_candidates(region)
	if not region.development_candidate_keys.has(first_key):
		push_error("Approved sector vanished after refresh")
		quit(1)
		return
	var first_id: int = int(region.development_candidates[int(region.development_candidate_keys[first_key])]["neighborhood_id"])
	var neighbor: Dictionary = {}
	for next_candidate in region.development_candidates:
		if int(next_candidate["neighborhood_id"]) >= 0 or int(next_candidate["city_id"]) != int(design["city_id"]) or not next_candidate.has("urban_sector"):
			continue
		var offset: Vector2i = next_candidate["urban_sector"] - first_sector
		if absi(offset.x) + absi(offset.y) == 1:
			neighbor = next_candidate
			break
	if neighbor.is_empty():
		push_error("Approval did not offer an adjacent next district")
		quit(1)
		return
	var shared_keys: Array[String] = []
	for edge_key in region.neighborhoods[first_id].street_layout.canonical_edges.values():
		if neighbor["layout"].canonical_edges.values().has(edge_key):
			shared_keys.append(edge_key)
	if shared_keys.is_empty():
		push_error("Adjacent districts do not share canonical street edges")
		quit(1)
		return
	var second: Dictionary = Planner.set_approval(region, int(neighbor["id"]), true)
	if not second["ok"]:
		push_error("Adjacent district could not be approved: %s" % second)
		quit(1)
		return
	var second_id: int = region.neighborhoods.size() - 1
	StreetNetwork.open_phase(region, region.neighborhoods[first_id], 3)
	UrbanGraph.mark_built(region, region.neighborhoods[first_id].street_layout, 3)
	StreetNetwork.open_phase(region, region.neighborhoods[second_id], 3)
	UrbanGraph.mark_built(region, region.neighborhoods[second_id].street_layout, 3)
	var shared_built := false
	for edge_key in shared_keys:
		var record: Dictionary = region.urban_plan_edges[edge_key]
		if record["status"] == "built" and record["owners"].has(first_id) and record["owners"].has(second_id):
			shared_built = true
			break
	if not shared_built:
		push_error("Adjacent approvals did not reuse a built street edge")
		quit(1)
		return
	var first_layout = region.neighborhoods[first_id].street_layout
	var second_layout = region.neighborhoods[second_id].street_layout
	var first_plan = region.neighborhoods[first_id].development_plan
	var second_plan = region.neighborhoods[second_id].development_plan
	var shared_node := false
	for first_local in first_plan.core_node_ids:
		if not first_layout.canonical_nodes.has(first_local):
			continue
		for second_local in second_plan.core_node_ids:
			if first_layout.canonical_nodes[first_local] == second_layout.canonical_nodes.get(second_local, "") and first_plan.core_node_ids[first_local] == second_plan.core_node_ids[second_local]:
				shared_node = true
	if not shared_node:
		push_error("Approved collectors did not meet at the same physical junction")
		quit(1)
		return
	print("Graph growth: stable designs, adjacent approvals, and shared built street edges passed.")
	quit()
