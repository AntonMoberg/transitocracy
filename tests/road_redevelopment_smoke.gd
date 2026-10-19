extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const Project = preload("res://scripts/simulation/road_project_data.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Snapshot = preload("res://scripts/simulation/day_cycle_calculator.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = Setup.build(42, 32, 0.1)["region"]
	var errors := PackedStringArray()
	for neighborhood in region.neighborhoods:
		var layout = neighborhood.street_layout
		if layout == null:
			continue
		var masks: Array[PackedVector2Array] = []
		for reservation in region.road_reservations:
			if reservation["road_class"] == "Highway" and reservation["bounds"].intersects(layout.bounds):
				masks.append_array(reservation["clearance_masks"])
		for block_id in range(layout.blocks.size()):
			var block: Dictionary = layout.blocks[block_id]
			if block.get("demolished", false):
				continue
			if RoadLand.polygon_intersects_masks(block["polygon"], masks):
				var overlap := 0.0
				for mask in masks:
					for piece in Geometry2D.intersect_polygons(block["polygon"], mask):
						overlap += RoadLand._area(piece)
				if overlap > 0.00001:
					errors.append("Generated neighbourhood %d block %d overlaps highway clearance by %.5f ha." % [neighborhood.id, block_id, overlap * 100.0])
					break
			if block_id < neighborhood.block_zoning.size() and neighborhood.block_zoning[block_id] > 0:
				var code: int = neighborhood.block_zoning[block_id] - 1
				var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][code / 3]
				for footprint in LayoutGenerator.buildings(block, zone, code % 3, neighborhood.character_profile):
					if RoadLand.polygon_intersects_masks(footprint, masks):
						errors.append("Generated building footprint lies beneath a highway.")
						break
	var target = region.neighborhoods[0]
	var original = target.street_layout
	var center: Vector2 = original.blocks[original.blocks.size() / 2]["polygon"][0]
	var points := PackedVector2Array([center + Vector2(-0.6, 0.0), center + Vector2(0.6, 0.0)])
	var impact: Dictionary = RoadLand.preview(region, points, "Arterial")
	var highway_impact: Dictionary = RoadLand.preview(region, points, "Highway")
	if int(highway_impact["land_cost"]) <= int(impact["land_cost"]) or int(highway_impact["cost"]) <= 0:
		errors.append("A new highway must acquire and clear a wider corridor than an arterial.")
	var item: Dictionary = {}
	for affected in impact["neighborhoods"]:
		if int(affected["id"]) == target.id:
			item = affected
			break
	if item.is_empty() or item["block_ids"].is_empty() or int(impact["land_cost"]) <= 0 or int(impact["site_cost"]) <= 0:
		errors.append("An arterial through occupied blocks must identify parcels and price acquisition and reconstruction.")
	else:
		var unaffected := -1
		for block_id in range(original.blocks.size()):
			if not item["block_ids"].has(block_id) and not original.blocks[block_id].get("demolished", false):
				unaffected = block_id
				break
		var untouched_polygon: PackedVector2Array = original.blocks[unaffected]["polygon"].duplicate() if unaffected >= 0 else PackedVector2Array()
		var old_count: int = original.blocks.size()
		RoadLand.apply(region, points, "Arterial", 77, impact)
		for block_id in item["block_ids"]:
			if not target.street_layout.blocks[block_id].get("demolished", false):
				errors.append("Funding must clear each affected old block.")
				break
		var project = Project.new()
		project.points = points
		project.road_class = "Arterial"
		project.open_day_key = region.current_day_key + 20
		project.redevelopment_impact = impact["neighborhoods"]
		region.road_projects.append(project)
		var worker_region = Snapshot.copy_region(region)
		RoadLand.rebuild_project(region, project)
		if worker_region.neighborhoods[target.id].street_layout == target.street_layout or worker_region.road_projects[0].redevelopment_impact.is_empty():
			errors.append("Redevelopment must leave the worker snapshot's street layout and project impact intact.")
		if target.street_layout.blocks.size() <= old_count:
			errors.append("Opening must create replacement parcels beside the road.")
		if unaffected >= 0 and target.street_layout.blocks[unaffected]["polygon"] != untouched_polygon:
			errors.append("Road work must preserve parcels away from its corridor.")
		var clearance: Array[PackedVector2Array] = RoadLand.clearance_corridor(points, "Arterial")
		for block_id in range(old_count, target.street_layout.blocks.size()):
			if RoadLand.polygon_intersects_masks(target.street_layout.blocks[block_id]["polygon"], clearance):
				errors.append("Replacement parcels must clear the new arterial.")
				break
			if int(target.street_layout.blocks[block_id].get("redevelopment_day", -1)) != project.open_day_key:
				errors.append("Replacement parcels must begin redevelopment when the road opens.")
				break
	if errors.is_empty():
		print("Generated highway clearance and local road redevelopment passed.")
	else:
		push_error("; ".join(errors))
	quit(0 if errors.is_empty() else 1)
