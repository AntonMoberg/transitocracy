extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const RegionData = preload("res://scripts/simulation/region_data.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const RoadLink = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for seed_value in [5424046, 8752568, 42]:
		var region = RegionGenerator.generate_region(seed_value)
		RoadNetworkGenerator.generate(region)
		var shaped := 0
		for key in region.urban_district_cells:
			var cells: Array[Vector2i] = region.urban_district_cells[key]
			if _has_wide_jog(cells):
				shaped += 1
			var selected: Dictionary = {}
			for cell in cells:
				selected[cell] = true
			var visited: Dictionary = {}
			var components := 0
			for cell in cells:
				if visited.has(cell):
					continue
				components += 1
				var queue: Array[Vector2i] = [cell]
				visited[cell] = true
				var cursor := 0
				while cursor < queue.size():
					var current: Vector2i = queue[cursor]
					cursor += 1
					for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
						var neighbor: Vector2i = current + step
						if selected.has(neighbor) and not visited.has(neighbor):
							visited[neighbor] = true
							queue.append(neighbor)
			if components > 1:
				push_error("Seed %d district %s has %d disconnected pieces." % [seed_value, key, components])
				_dump_cells(cells)
				quit(1)
				return
		if shaped < 3:
			push_error("Seed %d has too few districts with broad jogs or appendages (%d)." % [seed_value, shaped])
			quit(1)
			return
		print("Seed %d: %d districts have broad jogs or appendages." % [seed_value, shaped])
	if not _curved_arterial_preserves_grid():
		push_error("A curved arterial bent regular grid junctions.")
		quit(1)
		return
	print("District footprints stay connected and curved arterials do not bend regular streets.")
	quit(0)


func _has_wide_jog(cells: Array[Vector2i]) -> bool:
	var rows: Dictionary = {}
	for cell in cells:
		if posmod(cell.x, 2) != 0 or posmod(cell.y, 2) != 0:
			continue
		var row: Dictionary = rows.get(cell.y, {})
		row[cell.x] = true
		rows[cell.y] = row
	var narrow := 9999
	var wide := 0
	for row in rows.values():
		narrow = mini(narrow, row.size())
		wide = maxi(wide, row.size())
	return wide - narrow >= 2 and narrow >= 2


func _curved_arterial_preserves_grid() -> bool:
	var region = RegionData.new()
	region.generation_seed = 12345
	var plan := {"axis": Vector2.RIGHT, "origin": Vector2.ZERO, "column_spacing": 0.16, "row_spacing": 0.09}
	region.cities.append({"id": 0, "center_km": Vector2(0.0, -1.0), "street_axis": Vector2.RIGHT, "street_plan": plan})
	var road = RoadLink.new()
	road.id = 0
	road.road_class = RoadLink.ARTERIAL
	road.points = PackedVector2Array([Vector2(-1.5, 0.0), Vector2(0.0, 0.4), Vector2(1.5, 0.0)])
	region.road_links.append(road)
	var curved: Vector2 = CityPlan.junction(region, 0, Vector2i(0, 6), plan)
	road.points = PackedVector2Array([Vector2(-1.5, 0.0), Vector2(1.5, 0.0)])
	region.street_spatial_cache.clear()
	region.road_geometry_revision += 1
	var straight: Vector2 = CityPlan.junction(region, 0, Vector2i(0, 6), plan)
	return curved == straight and curved == CityPlan.base_junction(plan, Vector2i(0, 6))


func _dump_cells(cells: Array[Vector2i]) -> void:
	var selected: Dictionary = {}
	var minimum := Vector2i(9999, 9999)
	var maximum := Vector2i(-9999, -9999)
	for cell in cells:
		selected[cell] = true
		minimum.x = mini(minimum.x, cell.x)
		minimum.y = mini(minimum.y, cell.y)
		maximum.x = maxi(maximum.x, cell.x)
		maximum.y = maxi(maximum.y, cell.y)
	for y in range(minimum.y, maximum.y + 1):
		var row := ""
		for x in range(minimum.x, maximum.x + 1):
			row += "#" if selected.has(Vector2i(x, y)) else "."
		print(row)
