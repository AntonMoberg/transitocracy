extends SceneTree

const RegionSetup = preload("res://scripts/simulation/region_setup.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")


func _initialize() -> void:
	var region = RegionSetup.build(1729, 32, 0.10)["region"]
	var preview: Dictionary = {}
	for first_city in region.starting_city_ids:
		for second_city in region.starting_city_ids:
			if first_city >= second_city or region.city_highway_access_node_ids[first_city] < 0 or region.city_highway_access_node_ids[second_city] < 0:
				continue
			var candidate: Dictionary = RoadPlanner.link_preview(region, region.city_highway_access_node_ids[first_city], region.city_highway_access_node_ids[second_city], "Highway", PackedVector2Array(), region.current_day_key)
			if candidate.get("ok", false) and candidate["length_km"] > 15.0 and region.jurisdictions[candidate["owner_id"]].kind == "Region":
				preview = candidate
				break
		if not preview.is_empty():
			break
	if preview.is_empty():
		print("no preview available")
		quit(1)
		return
	region.jurisdictions[preview["owner_id"]].treasury = maxf(region.jurisdictions[preview["owner_id"]].treasury, float(preview["cost"]) + 1000000.0)
	var result: Dictionary = RoadPlanner.commit(region, preview, region.current_day_key)
	print("commit: ", result.get("ok"), " reason=", result.get("reason", "-"))
	if not result.get("ok", false):
		quit(1)
		return
	RoadPlanner.advance_day(region, int(result["project"].open_day_key))
	var link = null
	for candidate in region.road_links:
		if candidate.road_class == "Highway" and candidate.points == preview["points"]:
			link = candidate
			break
	if link == null:
		print("player highway not found after completion")
		quit(1)
		return
	print("player highway link %d len %.1f km from %s to %s" % [link.id, link.length_km, region.road_nodes[link.from_node_id].position_km, region.road_nodes[link.to_node_id].position_km])
	var exit_point: Vector2 = link.points[link.points.size() / 2]
	if exit_point.distance_to(region.road_nodes[link.from_node_id].position_km) < 0.2 or exit_point.distance_to(region.road_nodes[link.to_node_id].position_km) < 0.2:
		exit_point = link.points[link.points.size() / 4]
	var exit_preview: Dictionary = RoadPlanner.interchange_preview(region, -1, link.id, exit_point, region.current_day_key)
	print("exit preview: ", exit_preview.get("ok"), " reason=", exit_preview.get("reason", "-"), " owner=", exit_preview.get("owner_id", -1))
	if not exit_preview.get("ok", false):
		quit(1)
		return
	region.jurisdictions[exit_preview["owner_id"]].treasury += float(exit_preview["cost"])
	var exit_result: Dictionary = RoadPlanner.commit(region, exit_preview, region.current_day_key)
	print("exit commit: ", exit_result.get("ok"), " reason=", exit_result.get("reason", "-"))
	quit(0)
