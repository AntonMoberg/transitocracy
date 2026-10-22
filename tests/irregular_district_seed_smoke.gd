extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for seed_value in [5424046, 8752568]:
		var region = RegionGenerator.generate_region(seed_value)
		RoadNetworkGenerator.generate(region)
		var started := 0
		var irregular := 0
		var claimed: Dictionary = {}
		for neighborhood in region.neighborhoods:
			if not neighborhood.initially_developed:
				continue
			started += 1
			if neighborhood.street_layout == null or Geometry2D.triangulate_polygon(neighborhood.street_layout.polygon).is_empty():
				_fail("Seed %d has an invalid starting district." % seed_value)
				return
			if _corner_count(neighborhood.street_layout.polygon) > 4:
				irregular += 1
		for key in region.urban_sector_claims:
			var parts: PackedStringArray = String(key).split(":")
			var city_id: int = int(parts[0])
			for cell in UrbanGraph.district_cells(region, city_id, Vector2i(int(parts[1]), int(parts[2]))):
				var block_key: String = UrbanGraph.block_key(city_id, cell)
				if claimed.has(block_key) or not region.urban_block_claims.has(block_key):
					_fail("Seed %d assigned a block twice or left a claimed district gap." % seed_value)
					return
				claimed[block_key] = true
		if started != 40 or irregular < 15 or claimed.size() != region.urban_block_claims.size():
			_fail("Seed %d did not build varied, complete starting districts (%d/%d)." % [seed_value, irregular, started])
			return
	print("Reported city seeds have varied, connected district footprints without overlapping claims.")
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
