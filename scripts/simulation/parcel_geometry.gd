extends RefCounted

const Geography = preload("res://scripts/simulation/state_geography.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")


static func buildings(block: Dictionary, zone: String, density: int, character: String = Character.FINE_GRAIN, terrain = null) -> Array:
	var result: Array = []
	for parcel in parcels(block, zone, density, character, terrain):
		result.append_array(parcel["buildings"])
	return result


static func parcels(block: Dictionary, zone: String, density: int, character: String = Character.FINE_GRAIN, terrain = null) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if block["park"]:
		return result
	var polygon: PackedVector2Array = block["polygon"]
	if polygon.size() < 3:
		return result
	var axis: Vector2 = polygon[1] - polygon[0]
	for index in range(1, polygon.size()):
		var side: Vector2 = polygon[(index + 1) % polygon.size()] - polygon[index]
		if side.length_squared() > axis.length_squared():
			axis = side
	axis = axis.normalized()
	var normal: Vector2 = axis.orthogonal()
	var origin: Vector2 = polygon[0]
	var initial: Vector2 = Vector2.ZERO
	var bounds := Rect2(initial, Vector2.ZERO)
	for index in range(polygon.size()):
		var offset: Vector2 = polygon[index] - origin
		var local := Vector2(offset.dot(axis), offset.dot(normal))
		bounds = Rect2(local, Vector2.ZERO) if index == 0 else bounds.expand(local)
	var profile: String = Character.LARGE_PLOT if zone == "Industry" else character
	var columns: int = clampi(roundi(bounds.size.x / Character.frontage_km(profile)), 1, 16)
	var rows: int = 2 if polygon.size() >= 4 and bounds.size.y >= 0.085 and profile != Character.LARGE_PLOT else 1
	var margins: Vector3 = Character.margins_km(profile, density)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(block["seed"])
	for row in range(rows):
		for column in range(columns):
			var x0: float = bounds.position.x + bounds.size.x * float(column) / float(columns)
			var x1: float = bounds.position.x + bounds.size.x * float(column + 1) / float(columns)
			var y0: float = bounds.position.y + bounds.size.y * float(row) / float(rows)
			var y1: float = bounds.position.y + bounds.size.y * float(row + 1) / float(rows)
			var strip := PackedVector2Array([
				origin + axis * x0 + normal * y0,
				origin + axis * x1 + normal * y0,
				origin + axis * x1 + normal * y1,
				origin + axis * x0 + normal * y1,
			])
			var pieces: Array = Geometry2D.intersect_polygons(polygon, strip)
			var lot := PackedVector2Array()
			var best_area := 0.0
			for piece in pieces:
				var area: float = Geography.polygon_area(piece)
				if area > best_area:
					lot = piece
					best_area = area
			if best_area < 0.00005:
				continue
			var front: float = margins.x if row == 0 else margins.z
			var rear: float = margins.z if row == 0 else margins.x
			var side: float = margins.y
			var variation: float = rng.randf_range(0.0, minf(0.003, (x1 - x0) * 0.08))
			var build_x0: float = x0 + side
			var build_x1: float = x1 - side - variation
			var build_y0: float = y0 + front
			var build_y1: float = y1 - rear
			var footprints: Array[PackedVector2Array] = []
			if build_x1 - build_x0 >= 0.004 and build_y1 - build_y0 >= 0.005:
				var envelopes: Array[Rect2] = [Rect2(Vector2(build_x0, build_y0), Vector2(build_x1 - build_x0, build_y1 - build_y0))]
				if profile == Character.COURTYARD and build_x1 - build_x0 >= 0.023 and build_y1 - build_y0 >= 0.030:
					var court_width: float = (build_x1 - build_x0) * 0.34
					var court_height: float = (build_y1 - build_y0) * 0.38
					var court_x0: float = (build_x0 + build_x1 - court_width) * 0.5
					var court_x1: float = court_x0 + court_width
					var court_y0: float = (build_y0 + build_y1 - court_height) * 0.5
					var court_y1: float = court_y0 + court_height
					envelopes = [
						Rect2(Vector2(build_x0, build_y0), Vector2(build_x1 - build_x0, court_y0 - build_y0)),
						Rect2(Vector2(build_x0, court_y1), Vector2(build_x1 - build_x0, build_y1 - court_y1)),
						Rect2(Vector2(build_x0, court_y0), Vector2(court_x0 - build_x0, court_y1 - court_y0)),
						Rect2(Vector2(court_x1, court_y0), Vector2(build_x1 - court_x1, court_y1 - court_y0)),
					]
				for rect in envelopes:
					var envelope := PackedVector2Array([
						origin + axis * rect.position.x + normal * rect.position.y,
						origin + axis * rect.end.x + normal * rect.position.y,
						origin + axis * rect.end.x + normal * rect.end.y,
						origin + axis * rect.position.x + normal * rect.end.y,
					])
					for footprint in Geometry2D.intersect_polygons(lot, envelope):
						if footprint.size() >= 3 and Geography.polygon_area(footprint) >= 0.000012 and (terrain == null or terrain.footprint_buildable(footprint)):
							footprints.append(footprint)
			result.append({"polygon": lot, "buildings": footprints})
	return result


static func update_buildings(neighborhood) -> void:
	if neighborhood.street_layout == null or not neighborhood.development_approved:
		return
	var plan = neighborhood.development_plan
	var demand: float = maxf(plan.design_demand, float(plan.target_housing) * 2.0 + plan.target_jobs)
	neighborhood.built_fraction = maxf(neighborhood.built_fraction, minf(1.0, (float(neighborhood.households) * 2.0 + neighborhood.jobs) / maxf(1.0, demand)))
	var blocks: Array = neighborhood.street_layout.blocks
	neighborhood.block_zoning.resize(blocks.size())
	for block_id in range(blocks.size()):
		var block: Dictionary = blocks[block_id]
		if block["phase"] > plan.completed_phase or block.get("demolished", false) or neighborhood.block_zoning[block_id] != 0 or float(posmod(block["seed"], 1000)) / 1000.0 > neighborhood.built_fraction:
			continue
		var chosen: int = posmod(block["seed"], 100)
		var zone_id := 0
		for zone in ["Residential", "Commercial", "Office", "Mixed", "Industry"]:
			chosen -= int(neighborhood.zone_shares[zone])
			if chosen < 0:
				neighborhood.block_zoning[block_id] = zone_id * 3 + int(neighborhood.zone_density[zone]) + 1
				break
			zone_id += 1
