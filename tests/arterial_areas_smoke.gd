extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const RoadLink = preload("res://scripts/simulation/road_link_data.gd")
const ArterialAreas = preload("res://scripts/simulation/arterial_areas.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionData.new()
	var state = Jurisdiction.new()
	state.id = 0
	state.kind = "State"
	state.polygon_km = PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(5, 5), Vector2(0, 5)])
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
	region.starting_city_ids.append(0)
	region.city_hub_node_ids.append(0)
	for point in [Vector2(1, 1), Vector2(2.2, 1), Vector2(2.2, 2.2), Vector2(1, 2.2)]:
		var node = RoadNode.new()
		node.id = region.road_nodes.size()
		node.position_km = point
		region.road_nodes.append(node)
	for index in range(4):
		var link = RoadLink.new()
		link.id = region.road_links.size()
		link.from_node_id = index
		link.to_node_id = (index + 1) % 4
		link.road_class = RoadLink.ARTERIAL
		link.points = PackedVector2Array([region.road_nodes[link.from_node_id].position_km, region.road_nodes[link.to_node_id].position_km])
		link.recalculate_length()
		region.road_links.append(link)
	var rooted := PackedByteArray([1, 1, 1, 1])
	var faces: Array[Dictionary] = ArterialAreas.bounded_faces(region, rooted)
	_check(faces.size() == 1, "four arterials should enclose one neighbourhood face")
	if faces.size() == 1:
		_check(absf(Geography.polygon_area(faces[0]["polygon"]) - 1.44) < 0.001, "the face must follow the arterial loop exactly")
		var layout = LayoutGenerator.generate(region, 0, faces[0]["boundaries"][0], "test:face", [], true, faces[0]["boundaries"], PackedByteArray([1, 1, 1, 1]))
		_check(layout.polygon.size() >= 3 and absf(Geography.polygon_area(layout.polygon) - 1.44) < 0.001, "the street layout must retain the road-bound face")
		var covered_area := 0.0
		for block in layout.blocks:
			covered_area += Geography.polygon_area(block["polygon"])
		_check(covered_area >= 1.44 * 0.94 and layout.arterial_nodes.size() >= 2 and not layout.core_paths.is_empty(), "an arterial face needs filled blocks and connected collectors")
		DevelopmentPlanner.refresh_candidates(region)
		var found_face := false
		for candidate in region.development_candidates:
			if candidate["key"].contains("face:"):
				found_face = absf(Geography.polygon_area(candidate["polygon"]) - 1.44) < 0.001
		_check(found_face, "zoning should offer a valid arterial enclosure as an exact neighbourhood candidate")
	var highway = RoadLink.new()
	highway.id = 4
	highway.from_node_id = 0
	highway.to_node_id = 2
	highway.road_class = RoadLink.HIGHWAY
	highway.points = PackedVector2Array([Vector2(1, 1), Vector2(2.2, 2.2)])
	region.road_links.append(highway)
	_check(ArterialAreas.bounded_faces(region, rooted).size() == 1, "a highway crossing must not divide an arterial neighbourhood")
	var removed = region.road_links[1]
	region.road_links.remove_at(1)
	_check(ArterialAreas.bounded_faces(region, rooted).is_empty(), "an open arterial chain cannot bound a neighbourhood")
	region.road_links.insert(1, removed)
	region.road_links[0].points = PackedVector2Array([Vector2(1, 1), Vector2(1.6, 0.9), Vector2(2.2, 1)])
	region.road_links[0].recalculate_length()
	var bent_faces: Array[Dictionary] = ArterialAreas.bounded_faces(region, rooted)
	_check(bent_faces.size() == 1 and bent_faces[0]["polygon"].size() > 4, "a curved arterial side should become the neighbourhood boundary")
	if bent_faces.size() == 1:
		DevelopmentPlanner.refresh_candidates(region)
		var matched := false
		for candidate in region.development_candidates:
			if candidate["key"].contains("face:"):
				matched = candidate["polygon"].size() > 4 and absf(Geography.polygon_area(candidate["polygon"]) - Geography.polygon_area(bent_faces[0]["polygon"])) < 0.01
		_check(matched, "zoning should use the exact bent arterial boundary")
	print("Arterial areas smoke: %d failures" % failures)
	quit(1 if failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
