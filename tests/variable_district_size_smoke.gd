extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var compact := 0
	var narrow := 0
	var long := 0
	var proposals := 0
	var shortest := INF
	var longest := 0.0
	for seed_value in [8752568, 5424046, 42]:
		var generated: Dictionary = Setup.build(seed_value, 32, 0.1)
		if not generated["errors"].is_empty():
			_fail("Could not generate city for variable district test: %s" % [generated["errors"]])
			return
		var region = generated["region"]
		for candidate in region.development_candidates:
			if int(candidate["neighborhood_id"]) >= 0 or not candidate.has("urban_sector"):
				continue
			proposals += 1
			var city_id: int = candidate["city_id"]
			if region.urban_sector_claims.has(UrbanGraph.sector_key(city_id, candidate["urban_sector"])):
				_fail("A variable-size proposal overlaps a built district.")
				return
			var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
			var axis: Vector2 = plan["axis"]
			var across: Vector2 = axis.orthogonal()
			var low := Vector2(INF, INF)
			var high := Vector2(-INF, -INF)
			for point in candidate["polygon"]:
				var local := Vector2(point.dot(axis), point.dot(across))
				low = low.min(local)
				high = high.max(local)
			var size: Vector2 = high - low
			var short_side: float = minf(size.x, size.y)
			var long_side: float = maxf(size.x, size.y)
			shortest = minf(shortest, long_side)
			longest = maxf(longest, long_side)
			if long_side <= 0.65:
				compact += 1
			if short_side <= 0.55:
				narrow += 1
			if long_side >= 2.0:
				long += 1
	if proposals < 70 or compact < 1 or narrow < 5 or long < 1:
		_fail("Growth districts lack a useful range of sizes: %d proposed, %d compact, %d narrow, %d long." % [proposals, compact, narrow, long])
		return
	print("Growth districts vary from %.2f to %.2f km along their long side (%d compact, %d narrow, %d long among %d proposals)." % [shortest, longest, compact, narrow, long, proposals])
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
