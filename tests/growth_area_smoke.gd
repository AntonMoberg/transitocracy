extends SceneTree

const Region = preload("res://scripts/simulation/region_data.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const Link = preload("res://scripts/simulation/road_link_data.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const GrowthAreas = preload("res://scripts/simulation/growth_area_planner.gd")
const Day = preload("res://scripts/simulation/day_cycle_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Region.new()
	region.generation_seed = 8752568
	var state = Jurisdiction.new()
	state.id = 0
	state.kind = "State"
	state.polygon_km = PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(10, 8), Vector2(0, 8)])
	Geography.update_bounds(state)
	region.jurisdictions.append(state)
	var city = Jurisdiction.new()
	city.id = 1
	city.kind = "City"
	city.parent_id = 0
	city.polygon_km = state.polygon_km
	Geography.update_bounds(city)
	region.jurisdictions.append(city)
	region.city_jurisdiction_ids.append(1)
	region.cities.append({"id": 0, "jurisdiction_id": 1, "neighborhood_ids": [], "density": 1, "center_km": Vector2(5, 4)})
	region.starting_city_ids.append(0)
	region.city_hub_node_ids.append(0)
	for point in [Vector2(1, 3), Vector2(9, 3)]:
		var node = RoadNode.new()
		node.id = region.road_nodes.size()
		node.city_id = 0
		node.position_km = point
		region.road_nodes.append(node)
	var road = Link.new()
	road.id = 0
	road.from_node_id = 0
	road.to_node_id = 1
	road.road_class = Link.ARTERIAL
	road.points = PackedVector2Array([Vector2(1, 3), Vector2(9, 3)])
	road.recalculate_length()
	region.road_links.append(road)
	Planner.refresh_candidates(region)
	var result: Dictionary = Planner.paint_growth_area(region, PackedVector2Array([Vector2(3.0, 3.55), Vector2(4.2, 3.55)]))
	if not result["ok"]:
		_fail("Painted growth was rejected: %s" % result["reason"])
		return
	var key: String = result["key"]
	if not region.development_candidate_keys.has(key):
		_fail("Painted preview was not registered.")
		return
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(3.7, 3.55)]))
	if not result["ok"] or result["key"] != key or region.growth_area_drafts.size() != 1:
		_fail("An overlapping brush stroke created a duplicate district.")
		return
	var candidate: Dictionary = region.development_candidates[region.development_candidate_keys[key]]
	if candidate["layout"].blocks.is_empty() or candidate["layout"].edges.is_empty() or candidate["layout"].total_cost() <= 0:
		_fail("Painted preview has no streets, lots, or cost.")
		return
	if not Planner.set_candidate_style(region, int(candidate["id"]), "Organic"):
		_fail("Painted preview could not change street style.")
		return
	Planner.refresh_candidates(region)
	if region.development_candidates[region.development_candidate_keys[key]]["layout"].interior_style != "Organic":
		_fail("Painted street style was lost on planner refresh.")
		return
	var snapshot = Day.copy_region(region)
	if snapshot.growth_area_drafts.size() != 1 or not snapshot.development_candidate_keys.has(key):
		_fail("Worker snapshot lost a growth draft.")
		return
	var draft_id: int = candidate["growth_draft_id"]
	var outline: PackedVector2Array = region.growth_area_drafts[0]["polygon"]
	if not Planner.move_growth_vertex(region, draft_id, 0, outline[0] + Vector2(0.02, 0.02)):
		_fail("Moving a snapped outline vertex failed.")
		return
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(3.0, 3.55), Vector2(4.2, 3.55)]), true)
	if not result["ok"] or not region.growth_area_drafts.is_empty():
		_fail("Erasing the painted growth area failed.")
		return
	# A brush centered on the access road used to fail the 90% frontage
	# check even though the painted land is connected to that road.
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(6.0, 3.0)]))
	if not result["ok"] or not region.development_candidate_keys.has(result["key"]):
		_fail("Painting across an arterial was rejected: %s" % result.get("reason", "preview missing"))
		return
	var cross_layout = region.development_candidates[region.development_candidate_keys[result["key"]]]["layout"]
	var block_area := 0.0
	for block in cross_layout.blocks:
		block_area += Geography.polygon_area(block["polygon"])
	if block_area / Geography.polygon_area(cross_layout.polygon) < 0.85:
		_fail("Painting across an arterial left half the district without blocks.")
		return
	if not Planner.set_candidate_style(region, int(region.development_candidate_keys[result["key"]]), "Organic"):
		_fail("A cross-road district could not change style.")
		return
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(6.0, 3.0)]), true)
	if not result["ok"]:
		_fail("Erasing the cross-road growth area failed.")
		return
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(5.7, 2.5), Vector2(6.3, 3.5)]))
	if not result["ok"]:
		_fail("A wider painted area across the arterial was rejected: %s" % result.get("reason", ""))
		return
	var wide_layout = region.development_candidates[region.development_candidate_keys[result["key"]]]["layout"]
	block_area = 0.0
	for block in wide_layout.blocks:
		block_area += Geography.polygon_area(block["polygon"])
	if block_area / Geography.polygon_area(wide_layout.polygon) < 0.85:
		_fail("A wider cross-road district has a blank fringe.")
		return
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(5.7, 2.5), Vector2(6.3, 3.5)]), true)
	if not result["ok"]:
		_fail("Erasing the wider cross-road district failed.")
		return
	road.points = PackedVector2Array([Vector2(1, 3), Vector2(2.5, 3.2), Vector2(4, 3.45), Vector2(5.5, 3.2), Vector2(9, 3)])
	road.recalculate_length()
	Planner.refresh_candidates(region)
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(3.0, 3.8), Vector2(4.2, 3.9)]))
	if not result["ok"] or region.development_candidates[region.development_candidate_keys[result["key"]]]["layout"].blocks.is_empty():
		_fail("Painting beside a curved arterial did not produce a valid street grid.")
		return
	var drawn_outline := PackedVector2Array([Vector2(6, 3), Vector2(7, 3), Vector2(7, 4), Vector2(6, 4)])
	result = Planner.create_growth_area(region, drawn_outline)
	if not result["ok"] or not region.development_candidate_keys.has(result.get("key", "")):
		_fail("An exact four-corner district beside an arterial was rejected: %s" % result.get("reason", ""))
		return
	var exact: PackedVector2Array = region.development_candidates[region.development_candidate_keys[result["key"]]]["polygon"]
	if absf(Geography.polygon_area(exact) - 1.0) > 0.01:
		_fail("The polygon tool changed the drawn boundary.")
		return
	var exact_draft_id: int = region.development_candidates[region.development_candidate_keys[result["key"]]]["growth_draft_id"]
	if not Planner.move_growth_vertex(region, exact_draft_id, 2, Vector2(7.1, 4.1)):
		_fail("Editing a drawn polygon did not preserve a valid exact outline.")
		return
	var exact_key: String = result["key"]
	result = Planner.paint_growth_area(region, PackedVector2Array([Vector2(6.5, 3.5)]), true)
	if not result["ok"] or region.development_candidate_keys.has(exact_key):
		_fail("Erasing a drawn polygon did not delete its draft.")
		return
	var first: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(2.5, 3.22), 0.1)
	var last: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(5.5, 3.22), 0.1)
	var followed: PackedVector2Array = GrowthAreas.path_between(region, first, last)
	if first.get("kind", "") != "road" or last.get("kind", "") != "road" or not followed.has(Vector2(4, 3.45)):
		_fail("A snapped arterial edge did not follow its curved waypoints.")
		return
	var anchors: Array[Dictionary] = [first, last, {"point": Vector2(5.5, 4.3)}, {"point": Vector2(2.5, 4.3)}]
	if not GrowthAreas.outline_from_anchors(region, anchors).has(Vector2(4, 3.45)):
		_fail("Closing a district lost the arterial curve in its outline.")
		return
	region.growth_area_drafts.append({"id": 999, "city_id": 0, "polygon": PackedVector2Array([Vector2(6, 5), Vector2(6.5, 5.3), Vector2(7, 5), Vector2(7, 6), Vector2(6, 6)]), "shape_mode": "polygon"})
	first = GrowthAreas.snap_anchor(region, 0, Vector2(6.05, 5.03), 0.1)
	last = GrowthAreas.snap_anchor(region, 0, Vector2(6.95, 5.03), 0.1)
	if first.get("kind", "") != "draft" or last.get("kind", "") != "draft" or not GrowthAreas.path_between(region, first, last).has(Vector2(6.5, 5.3)):
		_fail("A new district did not follow an existing curved district edge.")
		return
	var highway = Link.new()
	highway.id = 1
	highway.road_class = Link.HIGHWAY
	highway.points = PackedVector2Array([Vector2(2, 6.5), Vector2(4, 6.8), Vector2(6, 6.5)])
	region.road_links.append(highway)
	first = GrowthAreas.snap_anchor(region, 0, Vector2(2.5, 6.58), 0.1)
	last = GrowthAreas.snap_anchor(region, 0, Vector2(5.5, 6.58), 0.1)
	if first.get("kind", "") != "road" or last.get("kind", "") != "road" or not GrowthAreas.path_between(region, first, last).has(Vector2(4, 6.8)):
		_fail("A district edge did not follow the highway curve.")
		return
	var east_west = Link.new()
	east_west.id = 2
	east_west.road_class = Link.ARTERIAL
	east_west.points = PackedVector2Array([Vector2(4, 1), Vector2(6, 1)])
	region.road_links.append(east_west)
	var north_south = Link.new()
	north_south.id = 3
	north_south.road_class = Link.ARTERIAL
	north_south.points = PackedVector2Array([Vector2(5, 0.5), Vector2(5, 1.5)])
	region.road_links.append(north_south)
	var approach: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(4.5, 1.01), 0.1)
	var junction: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(5.06, 1.04), 0.1, -1, [], false, approach)
	if not junction.get("intersection", false) or junction["point"].distance_to(Vector2(5, 1)) > 0.0001 or junction.get("index", -1) != 2:
		_fail("The polygon tool did not snap to the road intersection while retaining the approached arterial.")
		return
	north_south.points = PackedVector2Array([Vector2(5, 1), Vector2(5, 1.5)])
	junction = GrowthAreas.snap_anchor(region, 0, Vector2(5.06, 1.04), 0.1, -1, [], false, approach)
	if not junction.get("intersection", false) or junction["point"].distance_to(Vector2(5, 1)) > 0.0001:
		_fail("The polygon tool did not recognize a T intersection as a snap point.")
		return
	var boundary_cross = Link.new()
	boundary_cross.id = 4
	boundary_cross.road_class = Link.ARTERIAL
	boundary_cross.points = PackedVector2Array([Vector2(0.5, 2), Vector2(2, 2)])
	region.road_links.append(boundary_cross)
	var neighbor = preload("res://scripts/simulation/neighborhood_data.gd").new()
	neighbor.city_id = 0
	neighbor.street_layout = preload("res://scripts/simulation/street_layout.gd").new()
	neighbor.street_layout.polygon = PackedVector2Array([Vector2(1, 1.5), Vector2(3, 1.5), Vector2(3, 2.5), Vector2(1, 2.5)])
	neighbor.street_layout.bounds = Rect2(Vector2(1, 1.5), Vector2(2, 1))
	neighbor.street_layout.nodes = PackedVector2Array([Vector2(1.6, 1.8), Vector2(1.006, 1.8), Vector2(1.7, 2.2), Vector2(1, 2.2), Vector2(1.6, 2), Vector2(1.8, 2)])
	neighbor.street_layout.edges = PackedVector2Array([Vector2(0, 1), Vector2(2, 3), Vector2(4, 5)])
	neighbor.street_layout.classes = PackedStringArray([Link.LOCAL, Link.COLLECTOR, Link.LOCAL])
	region.neighborhoods.append(neighbor)
	var road_boundary: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(1.06, 2.03), 0.1)
	if not road_boundary.get("intersection", false) or road_boundary["point"].distance_to(Vector2(1, 2)) > 0.0001:
		_fail("The polygon tool did not snap to an arterial crossing a neighbourhood boundary.")
		return
	var local_connection: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(1.06, 1.84), 0.1)
	if local_connection.get("street_class", "") != Link.LOCAL or local_connection.get("kind", "") != "neighborhood" or local_connection["point"].distance_to(Vector2(1, 1.8)) > 0.0001:
		_fail("The polygon tool did not snap to a local street at the neighbouring boundary.")
		return
	var collector_connection: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(1.07, 2.17), 0.1)
	if collector_connection.get("street_class", "") != Link.COLLECTOR or collector_connection["point"].distance_to(Vector2(1, 2.2)) > 0.0001:
		_fail("The polygon tool did not snap to a collector at the neighbouring boundary.")
		return
	var interior_street: Dictionary = GrowthAreas.snap_anchor(region, 0, Vector2(1.7, 2), 0.08)
	if interior_street.has("street_class"):
		_fail("An interior local street became a zoning snap target.")
		return
	neighbor.street_layout.closed_edges[0] = true
	if GrowthAreas.snap_anchor(region, 0, Vector2(1.06, 1.84), 0.1).has("street_class"):
		_fail("A demolished local street remained a zoning snap target.")
		return
	var angle_anchors: Array[Dictionary] = [{"point": Vector2(2, 2)}, {"point": Vector2(3, 2)}]
	var angle_snapped: Dictionary = GrowthAreas.angle_snap_anchor(region, angle_anchors, Vector2(4, 2.176))
	if angle_snapped.get("angle_label", "") != "+10°" or absf(rad_to_deg((angle_snapped["point"] - Vector2(3, 2)).angle()) - 10.0) > 0.01:
		_fail("A free zoning edge did not snap its turn to a 5° increment from the previous edge.")
		return
	var curved_anchors: Array[Dictionary] = [first, last]
	var curve_tail: Vector2 = (last["point"] - Vector2(4, 6.8)).normalized()
	var curve_turn: Dictionary = GrowthAreas.angle_snap_anchor(region, curved_anchors, last["point"] + curve_tail * 0.4)
	if curve_turn.get("angle_label", "") != "0°":
		_fail("The zoning angle snap used a curved boundary's chord instead of its tangent.")
		return
	var road_angle: Dictionary = GrowthAreas.angle_snap_anchor(region, [approach], Vector2(4.49, 2))
	if road_angle.get("angle_label", "") != "+90°" or road_angle["point"].distance_to(Vector2(4.5, 2.00005)) > 0.01:
		_fail("The first zoning edge did not measure its angle from the snapped arterial.")
		return
	print("Growth previews, exact polygons, boundary and angle snapping, outline editing, and erasure passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
