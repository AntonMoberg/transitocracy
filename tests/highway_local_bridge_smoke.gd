extends SceneTree

const Layout = preload("res://scripts/simulation/street_layout.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var layout = Layout.new()
	layout.nodes = PackedVector2Array([Vector2(-0.2, 0), Vector2(0.2, 0), Vector2(-0.2, 0.1), Vector2(0.2, 0.1)])
	layout.edges = PackedVector2Array([Vector2(0, 1)])
	layout.classes = PackedStringArray(["Local"])
	layout.phases = PackedInt32Array([1])
	layout.lengths = PackedFloat32Array([0.4])
	var highway := PackedVector2Array([Vector2(0, -0.3), Vector2(0, 0.3)])
	var masks: Array[PackedVector2Array] = RoadLand.clearance_corridor(highway, "Highway")
	var bridges: PackedInt32Array = RoadLand._bridge_edges(layout, highway, masks)
	if bridges != PackedInt32Array([0]):
		push_error("A local street crossing a highway needs a priced grade-separated continuation.")
		quit(1)
		return
	var neighborhood = Neighborhood.new()
	neighborhood.street_layout = layout
	RoadLand._demolish_blocks(neighborhood, PackedInt32Array(), masks, bridges)
	if neighborhood.street_layout.closed_edges.has(0) or neighborhood.street_layout.grade_separated_edges.get(0, "") != "above":
		push_error("The local bridge was severed during highway demolition.")
		quit(1)
		return
	layout.edges.append(Vector2(2, 3))
	layout.classes.append("Collector")
	layout.phases.append(1)
	layout.lengths.append(0.4)
	if not RoadLand._bridge_edges(layout, highway, masks).is_empty():
		push_error("A nearby collector overpass should avoid a redundant local bridge.")
		quit(1)
		return
	print("Highway keeps a spaced, grade-separated local crossing when needed.")
	quit(0)
