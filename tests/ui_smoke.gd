extends SceneTree

var failures: int = 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	root.add_child(main)
	await process_frame
	_check(main.map_view.size.x > 0 and main.map_view.size.y > 0, "map must have visible layout size")
	_check(main.region.neighborhoods.size() == 12, "main scene must generate twelve neighborhoods")
	for neighborhood in main.region.neighborhoods:
		main.map_view.neighborhood_selected.emit(neighborhood.id)
		_check(main.inspector.text.contains(neighborhood.name), "selection must update the inspector for %s" % neighborhood.name)
	main.seed_input.value = 1730
	main._on_generate_pressed()
	_check(main.region.generation_seed == 1730, "Generate must use the entered seed")
	_check(main.map_view.selected_id == 0, "regeneration must select the first neighborhood")
	if failures == 0:
		print("UI smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
