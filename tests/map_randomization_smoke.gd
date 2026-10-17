extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var precision_polygon := PackedVector2Array([Vector2(672.9856, 208.7315), Vector2(642.3858, 208.7315), Vector2(642.3858, 179.7756), Vector2(672.9856, 179.7756)])
	_check(JurisdictionData.polygon_contains_point(Vector2(663.4664, 197.5774), precision_polygon), "large world coordinates must not make an interior point unselectable")
	_check(JurisdictionData.polygon_contains_point(precision_polygon[0], precision_polygon), "points on district borders must remain selectable")
	_check(not JurisdictionData.polygon_contains_point(Vector2(700, 200), precision_polygon), "point selection must still reject positions outside a district")
	var coastline_sizes: Dictionary = {}
	for seed_value in range(24):
		var region = RegionGenerator.generate_region(seed_value)
		var state = region.jurisdictions[0]
		coastline_sizes[state.polygon_km.size()] = true
		_check(absf(StateGeography._area(state.polygon_km) - StateGeography.STATE_LAND_AREA_KM2) < 1.0, "all seeds must preserve California-scale land area")
		_check(state.bounds_km.size.x >= 1200.0 and state.bounds_km.size.x <= 1600.0, "physical state length must remain California-scale")
		_check(not Geometry2D.triangulate_polygon(state.polygon_km).is_empty(), "random coastlines must remain simple polygons")
		for area in region.jurisdictions:
			if area.kind == "Neighborhood":
				continue
			_check(area.contains_point(area.center_km), "district centers must stay on land for every random seed")
			if not area.child_ids.is_empty() and area.kind != "City":
				var child_area := 0.0
				for child_id in area.child_ids:
					child_area += StateGeography._area(region.jurisdictions[child_id].polygon_km)
				var perimeter := 0.0
				for vertex in range(area.polygon_km.size()):
					perimeter += area.polygon_km[vertex].distance_to(area.polygon_km[(vertex + 1) % area.polygon_km.size()])
				var tolerance: float = maxf(0.0001, perimeter * JurisdictionData.BOUNDARY_TOLERANCE_KM)
				_check(absf(child_area - StateGeography._area(area.polygon_km)) < tolerance, "random administrative divisions must cover their parent within clipping precision")
		for neighborhood in region.neighborhoods:
			_check(state.contains_point(neighborhood.position_km), "random settlements must remain on land")
			var city = region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]]
			_check(city.contains_point(neighborhood.position_km), "small neighborhoods must remain inside their city")
	_check(coastline_sizes.size() >= 4, "different seeds must change coastline structure rather than perturb a fixed outline")
	var small = RegionGenerator.generate_region(1729)
	for city_count in [256, 768]:
		var region = RegionGenerator.generate_large_region(1729, city_count)
		_check(region.jurisdictions[0].polygon_km == small.jurisdictions[0].polygon_km, "detail settings must retain the same seeded coastline and physical state size")
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while main.generation_thread != null:
		await process_frame
	main.playing = false
	var original_seed: int = main.region.generation_seed
	_check(int(main.seed_input.value) == original_seed, "startup must display the randomly generated map seed")
	main._on_generate_pressed()
	_check(main.generate_button.disabled and main.seed_generate_button.disabled, "map generation controls must be disabled while the worker runs")
	while main.generation_thread != null:
		await process_frame
	main.playing = false
	var random_seed: int = main.region.generation_seed
	var coastline: PackedVector2Array = main.region.jurisdictions[0].polygon_km
	var position: Vector2 = main.region.neighborhoods[0].position_km
	_check(random_seed != original_seed and int(main.seed_input.value) == random_seed, "New map must select and display a fresh seed")
	main.seed_generate_button.pressed.emit()
	while main.generation_thread != null:
		await process_frame
	main.playing = false
	_check(main.region.generation_seed == random_seed and main.region.jurisdictions[0].polygon_km == coastline and main.region.neighborhoods[0].position_km == position, "From seed must reproduce the displayed map")
	if failures == 0:
		print("Procedural coastlines, California scale, city ownership, random startup, and seed replay passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
