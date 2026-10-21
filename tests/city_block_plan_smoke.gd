extends SceneTree

const CityStreetPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Region = preload("res://scripts/simulation/region_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var plan := {"axis": Vector2.RIGHT, "origin": Vector2.ZERO, "column_spacing": 0.2, "row_spacing": 0.1}
	var west := PackedVector2Array([Vector2(0.02, 0.02), Vector2(0.58, 0.02), Vector2(0.58, 0.28), Vector2(0.02, 0.28)])
	var east := PackedVector2Array([Vector2(0.62, 0.02), Vector2(1.18, 0.02), Vector2(1.18, 0.28), Vector2(0.62, 0.28)])
	var first: PackedVector2Array = CityStreetPlan.block_outline(plan, west)
	var second: PackedVector2Array = CityStreetPlan.block_outline(plan, east)
	if first.size() < 4 or second.size() < 4 or not Geometry2D.intersect_polygons(first, second).is_empty():
		push_error("Adjacent lasso selections must own disjoint blocks.")
		quit(1)
		return
	var first_right := -INF
	var second_left := INF
	for point in first:
		first_right = maxf(first_right, point.x)
	for point in second:
		second_left = minf(second_left, point.x)
	if absf(first_right - second_left) > 0.00001:
		push_error("Adjacent block selections should share the same street edge.")
		quit(1)
		return
	var region = Region.new()
	region.generation_seed = 8752568
	region.cities.append({"id": 0, "center_km": Vector2.ZERO, "street_axis": Vector2.RIGHT, "street_plan": plan})
	var address := Vector2i(7, 5)
	var before: Vector2 = CityStreetPlan.junction(region, 0, address, plan)
	region.road_geometry_revision += 1
	var after: Vector2 = CityStreetPlan.junction(region, 0, address, plan)
	if before.distance_to(after) > 0.000001:
		push_error("Refreshing candidate plans moved an unchanged city junction.")
		quit(1)
		return
	print("City blocks share street edges and junction coordinates survive candidate refreshes.")
	quit(0)
