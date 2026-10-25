extends RefCounted

class FixtureMain:
	extends "res://scripts/main.gd"
	var fixture_size := 0
	func _ready() -> void:
		get_window().min_size = Vector2i(1024, 700)
		generation_rng.seed = 1729
		_build_interface()
		map_size_selector.select(fixture_size)
		_generate_region(1729)

static func attach_small(tree: SceneTree):
	return await attach(tree, 0)

static func attach(tree: SceneTree, size_index: int):
	var main = FixtureMain.new()
	main.fixture_size = size_index
	tree.root.add_child(main)
	while main.generation_thread != null:
		await tree.process_frame
	return main

static func settle_map(tree: SceneTree, map, timeout_ms: int = 15000) -> bool:
	await tree.process_frame
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not map.chunk_renderer.is_settled() and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.005).timeout
	await tree.process_frame
	return map.chunk_renderer.is_settled()
