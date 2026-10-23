extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for seed_value in [8752568, 7113721]:
		var region = RegionGenerator.generate_region(seed_value)
		RoadNetworkGenerator.generate(region)
		DevelopmentPlanner.refresh_candidates(region)
		for candidate in region.development_candidates:
			var layout = candidate["layout"]
			if layout.blocks.is_empty():
				continue
			var covered := 0.0
			for block in layout.blocks:
				covered += Geography.polygon_area(block["polygon"])
			var reserved_road := 0.0
			for seam in layout.border_seams:
				var anchor: int = int(seam["anchor"])
				if anchor < 0:
					continue
				var middle: Vector2 = (seam["from"] + seam["to"]) * 0.5
				for corridor in Geometry2D.offset_polyline(PackedVector2Array([layout.nodes[anchor], middle]), 0.014, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND):
					for piece in Geometry2D.intersect_polygons(corridor, layout.polygon):
						reserved_road += Geography.polygon_area(piece)
			var missing: float = Geography.polygon_area(layout.polygon) - covered
			if missing > reserved_road + 0.0005:
				push_error("Seed %d candidate %s leaves %.4f km² without blocks." % [seed_value, candidate["key"], missing])
				quit(1)
				return
	print("Candidate blocks cover district polygons on both regression seeds.")
	quit(0)
