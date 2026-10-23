extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const DevelopmentBudget = preload("res://scripts/simulation/development_budget.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Accessibility = preload("res://scripts/simulation/accessibility_calculator.gd")
const Dynamics = preload("res://scripts/simulation/neighborhood_dynamics.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_large_region(7113721, 256)
	RoadNetworkGenerator.generate(region)
	DevelopmentPlanner.refresh_candidates(region)
	var first_id: int = int(region.development_candidate_keys.get("graph:141:0:1", -1))
	if first_id < 0:
		_fail("Brookhaven's border district was not proposed.")
		return
	var first: Dictionary = region.development_candidates[first_id]
	var adopted_cells := 0
	var joined_fragment_cells := 0
	for cell in first["layout"].border_cells:
		var group := Vector2i(cell.x - posmod(cell.x, 2), cell.y - posmod(cell.y, 2))
		if UrbanGraph._district_owner(region, 141, group) == Vector2i(0, 2):
			adopted_cells += 1
		elif UrbanGraph._district_owner(region, 141, group) == Vector2i(1, 2):
			joined_fragment_cells += 1
	if adopted_cells == 0 or joined_fragment_cells == 0:
		_fail("Connected small border sectors were split between future districts.")
		return
	if _uncovered_residual_area(region, 141, Vector2i(0, 2), first["polygon"]) > 0.002 or _uncovered_residual_area(region, 141, Vector2i(1, 2), first["polygon"]) > 0.002:
		_fail("An adopted border fragment still leaves a buildable gap outside its parent district.")
		return
	if first["layout"].border_seams.is_empty():
		_fail("Brookhaven's district has no shared border frontage.")
		return
	if not _frontage_covered(region, first):
		_fail("Brookhaven's border road extends beyond its developed land.")
		return
	region.dev_mode = true
	if not DevelopmentPlanner.set_approval(region, first_id, true).get("ok", false):
		_fail("Brookhaven's border district could not be approved.")
		return
	var first_neighborhood_id: int = region.development_candidates[first_id]["neighborhood_id"]
	if not StreetNetwork.open_phase(region, region.neighborhoods[first_neighborhood_id], 1):
		_fail("Brookhaven's border street did not open.")
		return
	DevelopmentPlanner.refresh_candidates(region, [141, 142])
	var next_id := -1
	for candidate in region.development_candidates:
		if int(candidate["city_id"]) != 142 or int(candidate["neighborhood_id"]) >= 0:
			continue
		for seam in candidate["layout"].border_seams:
			if int(seam["anchor"]) >= 0 and region.city_border_seams.has(seam["key"]):
				next_id = int(candidate["id"])
				break
	if next_id < 0 or not DevelopmentPlanner.set_approval(region, next_id, true).get("ok", false):
		_fail("The neighboring city did not propose development at the existing crossing.")
		return
	if not _frontage_covered(region, region.development_candidates[next_id]):
		_fail("Clearwater's border road extends beyond its developed land.")
		return
	var next_neighborhood_id: int = region.development_candidates[next_id]["neighborhood_id"]
	DevelopmentBudget.advance_day(region, 1)
	DevelopmentBudget.advance_day(region, 3)
	if region.neighborhoods[next_neighborhood_id].development_plan.completed_phase < 1:
		_fail("The neighboring city's approved street phase did not open on schedule: %s" % region.neighborhoods[next_neighborhood_id].development_plan.status)
		return
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	var direct_crossing := false
	for node in region.road_nodes:
		var second_approach := false
		var shared_collector := false
		for link in region.road_links:
			if link.from_node_id != node.id and link.to_node_id != node.id:
				continue
			if link.border_city_ids == Vector2i(141, 142):
				shared_collector = true
			if link.managed_neighborhood_id < 0:
				continue
			var owner_city: int = region.neighborhoods[link.managed_neighborhood_id].city_id
			second_approach = second_approach or owner_city == 142
		if shared_collector and second_approach and rooted[node.id] != 0:
			direct_crossing = true
			break
	if not direct_crossing:
		_fail("The neighboring city's streets did not meet the rooted border collector.")
		return
	if rooted[region.city_hub_node_ids[142]] != 0:
		_fail("The spillover regression unexpectedly connects Clearwater's original hub.")
		return
	Accessibility.recalculate(region)
	var next = region.neighborhoods[next_neighborhood_id]
	if region.neighborhood_development_connected[next_neighborhood_id] == 0 or region.neighborhood_accessible[next_neighborhood_id] == 0 or region.accessibility[next_neighborhood_id] <= 0.0:
		_fail("The neighboring city's approved district has no reachable jobs through the border.")
		return
	var initial_households: int = next.households
	var initial_jobs: int = next.jobs
	for day in range(1, 8):
		region.current_day_key = day
		Dynamics.advance_day(region)
	if next.households <= initial_households or next.jobs <= initial_jobs:
		_fail("The neighboring city's approved district did not grow after its streets opened.")
		return
	DevelopmentPlanner.refresh_candidates(region, [142])
	var further_growth := false
	for candidate in region.development_candidates:
		if int(candidate["city_id"]) == 142 and int(candidate["neighborhood_id"]) < 0:
			further_growth = true
			break
	if not further_growth:
		_fail("The neighboring city has no follow-up district proposal after opening its streets.")
		return
	for error in region.validation_errors():
		# This test opens streets directly, without running the travel-time rebuild.
		if error == "Travel-time or accessibility data is incomplete.":
			continue
		_fail("The completed cross-city street network is invalid: %s" % error)
		return
	print("Seed 7113721 fills residual border land and grows through the shared collector.")
	quit(0)


func _frontage_covered(region, candidate: Dictionary) -> bool:
	var city = region.jurisdictions[region.city_jurisdiction_ids[int(candidate["city_id"])]]
	for seam in candidate["layout"].border_seams:
		var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
		var inward: Vector2 = (seam["to"] - seam["from"]).normalized().orthogonal() * 0.05
		if not city.contains_point(middle + inward):
			inward = -inward
		for fraction in [0.25, 0.5, 0.75]:
			if not Geometry2D.is_point_in_polygon(seam["from"].lerp(seam["to"], fraction) + inward, candidate["polygon"]):
				return false
	return true


func _uncovered_residual_area(region, city_id: int, sector: Vector2i, district: PackedVector2Array) -> float:
	var plan: Dictionary = CityPlan.guide(region, city_id, Vector2.ZERO)
	var city = region.jurisdictions[region.city_jurisdiction_ids[city_id]]
	var outline: PackedVector2Array = UrbanGraph.sector_outline(plan, sector, region, city_id)
	var low := Vector2i(2147483647, 2147483647)
	var high := Vector2i(-2147483647, -2147483647)
	for point in outline:
		var address: Vector2i = CityPlan.address(point, plan)
		low = Vector2i(mini(low.x, address.x), mini(low.y, address.y))
		high = Vector2i(maxi(high.x, address.x), maxi(high.y, address.y))
	var missing := 0.0
	for y in range(low.y - 6, high.y + 6):
		for x in range(low.x - 6, high.x + 6):
			var group := Vector2i(x - posmod(x, 2), y - posmod(y, 2))
			if UrbanGraph._district_owner(region, city_id, group) != sector:
				continue
			var cell := Vector2i(x, y)
			var quad := PackedVector2Array([CityPlan.base_junction(plan, cell), CityPlan.base_junction(plan, cell + Vector2i.RIGHT), CityPlan.base_junction(plan, cell + Vector2i.ONE), CityPlan.base_junction(plan, cell + Vector2i.DOWN)])
			for land in Geometry2D.intersect_polygons(quad, city.polygon_km):
				for gap in Geometry2D.clip_polygons(land, district):
					missing += Geography.polygon_area(gap)
	return missing


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
