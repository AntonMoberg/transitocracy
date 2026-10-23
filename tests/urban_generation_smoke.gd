extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for city_count in [32, 256]:
		var generated: Dictionary = Setup.build(42, city_count, 0.1)
		var region = generated["region"]
		if not generated["errors"].is_empty():
			_fail("Generated %d city state is invalid: %s" % [city_count, generated["errors"]])
			return
		var started := 0
		var irregular := 0
		var starting_sizes: Dictionary = {}
		var local_arterial_portals := 0
		for city_id in region.starting_city_ids:
			var core_size: int = int(region.cities[city_id].get("initial_neighborhood_count", 0))
			starting_sizes[core_size] = int(starting_sizes.get(core_size, 0)) + 1
		for neighborhood in region.neighborhoods:
			if neighborhood.initially_developed:
				started += 1
				if neighborhood.street_layout == null or neighborhood.street_layout.canonical_edges.is_empty():
					_fail("A starting district has no shared street addresses")
					return
				if _corner_count(neighborhood.street_layout.polygon) > 4:
					irregular += 1
				for edge_id in range(neighborhood.street_layout.edges.size()):
					if neighborhood.street_layout.classes[edge_id] != Roads.LOCAL:
						continue
					var edge: Vector2 = neighborhood.street_layout.edges[edge_id]
					for local_id in [int(edge.x), int(edge.y)]:
						if neighborhood.street_layout.arterial_nodes.has(local_id) and neighborhood.development_plan.core_node_ids.has(local_id):
							local_arterial_portals += 1
		if started != 40 or region.urban_sector_claims.size() != 40 or region.urban_plan_edges.is_empty():
			_fail("Starting cities did not populate the persistent street graph")
			return
		if irregular < 20 or region.urban_block_claims.size() < 40 * 24:
			_fail("%d-city start did not claim varied, connected blocks (%d irregular, %d claimed)" % [city_count, irregular, region.urban_block_claims.size()])
			return
		if starting_sizes != {2: 2, 3: 2, 4: 2, 5: 2, 6: 2} or local_arterial_portals < 10:
			_fail("Starting city sizes or direct local-to-arterial access lack variety (%s, %d portals)." % [starting_sizes, local_arterial_portals])
			return
		var highways := 0
		for link in region.road_links:
			if link.road_class == Roads.HIGHWAY:
				highways += 1
		if highways == 0:
			_fail("The starting state has no regional highway network")
			return
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) >= 0 or not candidate.has("urban_sector"):
				continue
			if region.urban_sector_claims.has(UrbanGraph.sector_key(int(candidate["city_id"]), candidate["urban_sector"])):
				_fail("A suggested phase overlaps built graph blocks")
				return
			for cell in candidate["urban_cells"]:
				if region.urban_block_claims.has(UrbanGraph.block_key(int(candidate["city_id"]), cell)):
					_fail("A suggested district overlaps already claimed street blocks")
					return
		if city_count == 32:
			var repeated: Dictionary = Setup.build(42, city_count, 0.1)
			var replica = repeated["region"]
			if replica.urban_sector_claims != region.urban_sector_claims or replica.neighborhoods[0].street_layout.nodes != region.neighborhoods[0].street_layout.nodes:
				_fail("The same seed changed street addresses")
				return
			if replica.road_links.size() != region.road_links.size():
				_fail("The same seed changed the regional road network")
				return
			for index in range(region.road_links.size()):
				if replica.road_links[index].points != region.road_links[index].points:
					_fail("The same seed changed a road route")
					return
	print("Starting street graph, highway network, and deterministic city growth passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _corner_count(polygon: PackedVector2Array) -> int:
	var count := 0
	for index in range(polygon.size()):
		var incoming: Vector2 = (polygon[index] - polygon[(index + polygon.size() - 1) % polygon.size()]).normalized()
		var outgoing: Vector2 = (polygon[(index + 1) % polygon.size()] - polygon[index]).normalized()
		if absf(incoming.cross(outgoing)) > 0.2:
			count += 1
	return count
