extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const RoadNodeData = preload("res://scripts/simulation/road_node_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionData.new()
	var state = JurisdictionData.new()
	state.id = 0
	state.kind = "State"
	state.bounds_km = Rect2(0.0, 0.0, 10.0, 10.0)
	state.polygon_km = PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	state.treasury = 100000000.0
	region.jurisdictions.append(state)
	var district = JurisdictionData.new()
	district.id = 1
	district.kind = "Neighborhood"
	district.parent_id = 0
	district.bounds_km = Rect2(2.0, 2.0, 2.0, 2.0)
	district.polygon_km = PackedVector2Array([Vector2(2, 2), Vector2(4, 2), Vector2(4, 4), Vector2(2, 4)])
	region.jurisdictions.append(district)
	var homes = NeighborhoodData.new()
	homes.id = 0
	homes.jurisdiction_id = 1
	homes.developable_area_ha = 300.0
	homes.housing_capacity = 160
	homes.job_capacity = 80
	homes.base_housing_capacity = 160
	homes.base_job_capacity = 80
	homes.households = 100
	homes.population = 220
	homes.people_per_household = 2.2
	homes.jobs = 60
	homes.jobs_by_skill = {"Entry": 20, "Skilled": 30, "Professional": 10}
	homes.assessed_home_value = 180000.0
	region.neighborhoods.append(homes)
	for position in [Vector2(1, 3), Vector2(9, 3), Vector2(7, 1), Vector2(7, 9)]:
		var node = RoadNodeData.new()
		node.id = region.road_nodes.size()
		node.position_km = position
		region.road_nodes.append(node)
	var highway = RoadLinkData.new()
	highway.id = 0
	highway.from_node_id = 2
	highway.to_node_id = 3
	highway.road_class = RoadLinkData.HIGHWAY
	highway.points = PackedVector2Array([Vector2(7, 1), Vector2(7, 9)])
	highway.recalculate_length()
	highway.owner_jurisdiction_id = 0
	region.road_links.append(highway)
	region.next_road_link_id = 1
	RoadLand.initialize(region)

	var straight: Dictionary = RoadPlanner.link_preview(region, 0, 1, RoadLinkData.ARTERIAL, PackedVector2Array(), 0, RoadRouteBuilder.STRAIGHT)
	_check(straight.get("ok", false), "straight arterial should preview")
	if straight.get("ok", false):
		_check(straight["points"].size() == 2, "straight mode should keep one segment")
		_check(straight["crossings"].size() == 1, "highway intersection should create one grade crossing")
		_check(straight["land_impact"]["home_cost"] > 0 and straight["land_impact"]["land_cost"] > 0, "developed land and acquired land should be charged")
		var choices: Dictionary = {}
		choices[straight["crossings"][0]["key"]] = false
		var below: Dictionary = RoadPlanner.link_preview(region, 0, 1, RoadLinkData.ARTERIAL, PackedVector2Array(), 0, RoadRouteBuilder.STRAIGHT, Vector2.ZERO, choices)
		_check(below.get("ok", false) and not below["crossings"][0]["above"] and below["structure_cost"] > straight["structure_cost"], "Below should persist and charge for a tunnel")
		var before_homes: int = homes.households
		var result: Dictionary = RoadPlanner.commit(region, below, 0)
		_check(result.get("ok", false), "the fully priced road should fund")
		if result.get("ok", false):
			_check(homes.households < before_homes and homes.housing_capacity < 160 and RoadLand.contains_reserved(region, Vector2(3, 3)), "funding should clear occupied land and reserve the corridor")
			var snapshot = DayCycleCalculator.copy_region(region)
			_check(snapshot.road_reservations.size() == region.road_reservations.size() and snapshot.road_projects[0].crossings.size() == 1, "worker snapshot should retain corridor and crossing choices")
			RoadPlanner.advance_day(region, result["project"].open_day_key)
			_check(region.road_links[-1].crossings.size() == 1 and not region.road_links[-1].crossings[0]["above"], "completed road should retain its grade choice")
			_check(RoadGraph.adjacency(region)[0].size() == 1 and RoadGraph.adjacency(region)[2].size() == 1, "grade crossing must not connect road nodes")
			var reduced_area: float = homes.developable_area_ha
			var removal: Dictionary = RoadPlanner.demolish(region, region.road_links[-1].id)
			_check(removal.get("ok", false) and homes.developable_area_ha > reduced_area and not RoadLand.contains_reserved(region, Vector2(3, 3)), "removing the road should release its land")
	var free_end: Dictionary = RoadPlanner.link_preview(region, 0, -1, RoadLinkData.ARTERIAL, PackedVector2Array(), 0, RoadRouteBuilder.STRAIGHT, Vector2(5, 5))
	_check(free_end.get("ok", false), "an arterial should preview a new endpoint on empty land")
	if free_end.get("ok", false):
		var node_count: int = region.road_nodes.size()
		var free_result: Dictionary = RoadPlanner.commit(region, free_end, 0)
		_check(free_result.get("ok", false) and region.road_nodes.size() == node_count + 1 and free_result["project"].to_node_id == node_count, "funding an arterial should create its free endpoint")

	var approach = RoadNodeData.new()
	approach.id = region.road_nodes.size()
	approach.position_km = Vector2(0.5, 3)
	region.road_nodes.append(approach)
	var existing = RoadLinkData.new()
	existing.id = region.next_road_link_id
	region.next_road_link_id += 1
	existing.from_node_id = approach.id
	existing.to_node_id = 0
	existing.road_class = RoadLinkData.ARTERIAL
	existing.points = PackedVector2Array([approach.position_km, Vector2(1, 3)])
	existing.recalculate_length()
	region.road_links.append(existing)
	var curved: PackedVector2Array = RoadPlanner.player_route(region, 0, Vector2(9, 3), RoadLinkData.ARTERIAL, PackedVector2Array([Vector2(4, 4)]), RoadRouteBuilder.CURVED)
	_check(curved.size() > 3 and not curved.has(Vector2(4, 4)), "curved mode should use its guide without passing through it")
	_check(curved.size() > 3 and absf((curved[1] - curved[0]).angle()) < 0.001, "a curved extension should leave the existing arterial at zero degrees")
	for index in range(1, curved.size() - 1):
		_check(absf(rad_to_deg((curved[index] - curved[index - 1]).angle_to(curved[index + 1] - curved[index]))) <= 3.0, "curved roads must not contain visible corners")
	var north = RoadNodeData.new()
	north.id = region.road_nodes.size()
	north.position_km = Vector2(1, 2)
	region.road_nodes.append(north)
	var branch = RoadLinkData.new()
	branch.id = region.next_road_link_id
	region.next_road_link_id += 1
	branch.from_node_id = north.id
	branch.to_node_id = 0
	branch.road_class = RoadLinkData.ARTERIAL
	branch.points = PackedVector2Array([north.position_km, Vector2(1, 3)])
	region.road_links.append(branch)
	_check(RoadPlanner.arterial_continuation(region, 0, Vector2(1, 5)).dot(Vector2.DOWN) > 0.999, "a busy junction should continue the branch nearest the guide")
	var first_curve: PackedVector2Array = RoadPlanner.player_route(region, 0, Vector2(4, 4), RoadLinkData.ARTERIAL, PackedVector2Array([Vector2(3, 4)]), RoadRouteBuilder.MULTIPOINT)
	var multipoint_anchors := PackedVector2Array([Vector2(3, 4), Vector2(4, 4), Vector2(6, 5)])
	var multipoint: PackedVector2Array = RoadPlanner.player_route(region, 0, Vector2(9, 3), RoadLinkData.ARTERIAL, multipoint_anchors, RoadRouteBuilder.MULTIPOINT)
	_check(first_curve.size() > 3 and multipoint.size() > first_curve.size() and not multipoint.has(Vector2(3, 4)) and not multipoint.has(Vector2(6, 5)), "multi-point mode should shape each curve from its guide")
	if multipoint.size() >= first_curve.size():
		for index in range(first_curve.size()):
			_check(multipoint[index].distance_to(first_curve[index]) < 0.000001, "adding another curve must leave the frozen curve unchanged")
	var frozen_curve: PackedVector2Array = RoadPlanner.frozen_multi_curve(region, 0, PackedVector2Array([Vector2(3, 4), Vector2(4, 4)]), RoadLinkData.ARTERIAL)
	_check(frozen_curve == first_curve, "a completed multi-point curve should remain visible while placing the next guide")
	var active_curve: PackedVector2Array = RoadPlanner.multi_curve_preview(region, 0, multipoint_anchors, Vector2(9, 3), RoadLinkData.ARTERIAL, frozen_curve)
	_check(active_curve == multipoint, "the live curve should extend the frozen route without rebuilding earlier curves")
	if multipoint.size() > first_curve.size() and first_curve.size() >= 2:
		var join_index: int = first_curve.size() - 1
		_check(absf(rad_to_deg((multipoint[join_index] - multipoint[join_index - 1]).angle_to(multipoint[join_index + 1] - multipoint[join_index]))) <= 3.0, "successive curves should meet smoothly")
	var third_anchors := PackedVector2Array([Vector2(3, 4), Vector2(4, 4), Vector2(6, 5), Vector2(9, 3), Vector2(9.2, 4)])
	var third_curve: PackedVector2Array = RoadPlanner.player_route(region, 0, Vector2(9.5, 5), RoadLinkData.ARTERIAL, third_anchors, RoadRouteBuilder.MULTIPOINT)
	_check(third_curve.size() > multipoint.size(), "the multi-curve tool should allow another curve after the second")
	if third_curve.size() >= multipoint.size():
		for index in range(multipoint.size()):
			_check(third_curve[index].distance_to(multipoint[index]) < 0.000001, "a third curve must leave the first two curves unchanged")
	var next_guide: Dictionary = RoadPlanner.snap_guidance(region, 0, PackedVector2Array([Vector2(3, 4), Vector2(4, 4)]), Vector2(6, 4), RoadLinkData.ARTERIAL, RoadRouteBuilder.MULTIPOINT)
	_check(next_guide["has_reference"] and next_guide["label"] == "0°", "the next multi-point guide should show angle from the previous curve's tangent")
	var first_end: Dictionary = RoadPlanner.snap_guidance(region, 0, PackedVector2Array([Vector2(3, 4)]), Vector2(4, 4), RoadLinkData.ARTERIAL, RoadRouteBuilder.MULTIPOINT)
	_check(first_end["has_reference"] and not String(first_end["label"]).begins_with("Bearing"), "the first multi-point curve end should use the existing road as its angle reference")
	var next_end: Dictionary = RoadPlanner.snap_guidance(region, 0, multipoint_anchors, Vector2(9, 3), RoadLinkData.ARTERIAL, RoadRouteBuilder.MULTIPOINT)
	_check(next_end["has_reference"] and next_end["label"] == "-35°", "the next multi-point curve end should show its turn from the previous curve")
	var offshore_guide: Dictionary = RoadPlanner.link_preview(region, 0, 1, RoadLinkData.ARTERIAL, PackedVector2Array([Vector2(4, -1)]), 0, RoadRouteBuilder.CURVED)
	_check(offshore_guide.get("ok", false), "a curve guide may sit outside land when the actual road remains on land")
	_check(RoadRouteBuilder.build_player(region, Vector2(1, 3), Vector2(11, 3), RoadLinkData.ARTERIAL, PackedVector2Array(), RoadRouteBuilder.STRAIGHT).is_empty(), "player route should not leave the land polygon")
	var snapped: Vector2 = RoadPlanner.snap_position(region, 0, PackedVector2Array(), Vector2(4, 3.8), RoadLinkData.ARTERIAL)
	var reference: Vector2 = RoadPlanner.snap_reference(region, 0, PackedVector2Array(), Vector2(4, 3.8), RoadLinkData.ARTERIAL)
	var steps: float = rad_to_deg(reference.angle_to(snapped - Vector2(1, 3))) / 5.0
	_check(absf(steps - roundf(steps)) < 0.0001, "snap should use five degree increments")
	_check(absf(rad_to_deg(reference.angle_to(Vector2.RIGHT))) < 0.001, "the angle display must read zero along the arterial continuation")
	var arterial_guide: Dictionary = RoadPlanner.snap_guidance(region, 0, PackedVector2Array(), Vector2(4, 3), RoadLinkData.ARTERIAL)
	_check(arterial_guide["has_reference"] and arterial_guide["label"] == "0°", "straight arterial extension should display zero degrees from the existing road")
	var multi_start_guide: Dictionary = RoadPlanner.snap_guidance(region, 0, PackedVector2Array(), Vector2(4, 3), RoadLinkData.ARTERIAL, RoadRouteBuilder.MULTIPOINT)
	_check(multi_start_guide["has_reference"] and multi_start_guide["label"] == "0°", "multi-curve guide placement should show the turn from the existing arterial")
	var highway_guide: Dictionary = RoadPlanner.snap_guidance(region, 2, PackedVector2Array(), Vector2(7, 0), RoadLinkData.HIGHWAY)
	_check(highway_guide["has_reference"] and highway_guide["label"] == "0°", "straight highway extension should show the angle from the existing highway")
	var multi_highway_guide: Dictionary = RoadPlanner.snap_guidance(region, 2, PackedVector2Array(), Vector2(7, 0), RoadLinkData.HIGHWAY, RoadRouteBuilder.MULTIPOINT)
	_check(multi_highway_guide["has_reference"] and multi_highway_guide["label"] == "0°", "multi-curve guide placement should show the turn from the existing highway")
	var highway_turn: Dictionary = RoadPlanner.snap_guidance(region, 2, PackedVector2Array(), Vector2(8, 1), RoadLinkData.HIGHWAY)
	_check(highway_turn["label"] == "+90°", "a right angle turn from a highway should show the turn angle")
	var cross_class_guide: Dictionary = RoadPlanner.snap_guidance(region, 2, PackedVector2Array(), Vector2(7, 0), RoadLinkData.ARTERIAL)
	_check(cross_class_guide["has_reference"] and cross_class_guide["label"] == "0°", "a new arterial should use the connected highway when no arterial exists")
	branch.road_class = RoadLinkData.COLLECTOR
	var collector_guide: Dictionary = RoadPlanner.snap_guidance(region, north.id, PackedVector2Array(), Vector2(1, 1), RoadLinkData.ARTERIAL)
	_check(collector_guide["has_reference"] and collector_guide["label"] == "0°", "a new arterial should use the connected collector when no arterial exists")
	print("Road geometry and land smoke: %d failures" % failures)
	quit(1 if failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
