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
		for neighborhood in region.neighborhoods:
			if neighborhood.initially_developed:
				started += 1
				if neighborhood.street_layout == null or neighborhood.street_layout.canonical_edges.is_empty():
					_fail("A starting district has no shared street addresses")
					return
		if started != 40 or region.urban_sector_claims.size() != 40 or region.urban_plan_edges.is_empty():
			_fail("Starting cities did not populate the persistent street graph")
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
