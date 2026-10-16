extends RefCounted


static func attach_small(tree: SceneTree):
	var main = load("res://scenes/main.tscn").instantiate()
	tree.root.add_child(main)
	while main.generation_thread != null:
		await tree.process_frame
	main.map_size_selector.select(0)
	main._generate_region(1729)
	while main.generation_thread != null:
		await tree.process_frame
	return main
