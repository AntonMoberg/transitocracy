extends SceneTree

const Region = preload("res://scripts/simulation/region_data.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const GridFamily = preload("res://scripts/simulation/grid_family_layout.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _around_arterial_bend():
		return
	var region = _region()
	var square := PackedVector2Array([Vector2.ZERO,Vector2.RIGHT,Vector2.ONE,Vector2.DOWN])
	if not GridFamily._physical_frontage(Vector2(-1,0),Vector2(2,0),square):
		_fail("A road following the district boundary lost its real frontage.")
		return
	var original_road: PackedVector2Array = region.road_links[0].points
	region.road_links[0].points = PackedVector2Array([Vector2(-1,-1),Vector2.ZERO])
	region.road_geometry_revision += 1
	if not GridFamily.separating_chart(region,0,square,region.cities[0].street_plan).is_empty():
		_fail("A road ending at one corner seeded a grid along its imaginary extension.")
		return
	region.road_links[0].points = original_road
	region.road_geometry_revision += 1
	# The road cuts a small city-facing corner off a narrow district. The
	# 106 m corner is genuine frontage, even though it is under 270 m deep.
	var narrow := PackedVector2Array([Vector2(0,-1),Vector2(.3,-1),Vector2(.3,-.65),Vector2(0,-.65)])
	var neighboring := PackedVector2Array([Vector2(.3,-1),Vector2(1.28,-1),Vector2(1.28,0),Vector2(.3,0)])
	var narrow_chart := GridFamily.separating_chart(region,0,narrow,region.cities[0].street_plan)
	var neighbor_chart := GridFamily.separating_chart(region,0,neighboring,region.cities[0].street_plan)
	if narrow_chart.is_empty() or neighbor_chart.is_empty() or narrow_chart.key != neighbor_chart.key or narrow_chart.uniform_far:
		_fail("A real road crossing at a shallow corner lost the neighboring district's rotated grid.")
		return
	var narrow_layout = Layout.new()
	narrow_layout.city_id = 0
	narrow_layout.polygon = narrow
	narrow_layout.bounds = Geography._bounds(narrow)
	GridFamily.fill(narrow_layout, region.cities[0].street_plan, narrow_chart, 0, {}, region.generation_seed)
	var near_axis: Vector2 = GridFamily._chart_at(narrow_layout, Vector2(.02,-.68), region.cities[0].street_plan).axis
	var far_axis: Vector2 = GridFamily._chart_at(narrow_layout, Vector2(.25,-.9), region.cities[0].street_plan).axis
	if narrow_layout.grid_families.size() != 2 or absf(near_axis.dot(Vector2.RIGHT)) < .999 or absf(far_axis.dot(neighbor_chart.axis)) < .999:
		_fail("A shallow crossing did not keep the city-facing corner regular and the far side aligned with its neighbor.")
		return
	var middle = UrbanGraph.make_layout(region, 0, Vector2i.ZERO)["layout"]
	var right_before = UrbanGraph.make_layout(region, 0, Vector2i.RIGHT)["layout"]
	if middle.grid_families.size() != 2 or not right_before.grid_families.is_empty():
		_fail("Only the district with real arterial frontage should establish a new rotated chart.")
		return
	var domain_key: String = middle.grid_families[1]["key"]
	_attach(region, middle, Vector2i.ZERO)
	var right = UrbanGraph.make_layout(region, 0, Vector2i.RIGHT)["layout"]
	var left = UrbanGraph.make_layout(region, 0, Vector2i.LEFT)["layout"]
	if right.grid_families.size() != 1 or right.grid_families[0]["key"] != domain_key:
		_fail("A differently aligned district below overrode the middle district's rotated side.")
		return
	if left.grid_families.size()==1 and left.grid_families[0].get("key", "") == domain_key:
		_fail("A district on the city-facing side rotated without a visible boundary.")
		return
	if _shared_nodes(middle, right) < 2:
		_fail("The middle and right districts did not share continuing street junctions.")
		return
	var far = UrbanGraph.make_layout(region, 0, Vector2i(8, 0))["layout"]
	if not far.grid_families.is_empty():
		_fail("A distant district rotated without physical road frontage or contiguous approved fabric.")
		return
	for layout in [narrow_layout, middle, right, far]:
		var covered := 0.0
		for block in layout.blocks:
			covered += Geography.polygon_area(block["polygon"])
		var area: float = Geography.polygon_area(layout.polygon)
		if area <= 0.0 or absf(covered - area) > area * 0.001:
			_fail("The inherited chart left undeveloped gaps at a district edge.")
			return
	var highway = Roads.new()
	highway.id = 1
	highway.road_class = Roads.HIGHWAY
	highway.points = PackedVector2Array([Vector2(3.0, -16.0), Vector2(3.0, 16.0)])
	region.road_links.append(highway)
	var beyond_highway = UrbanGraph.make_layout(region, 0, Vector2i(8, 0))["layout"]
	if not beyond_highway.grid_families.is_empty():
		_fail("The arterial-side chart crossed a highway boundary.")
		return
	region.road_links.pop_back()
	_attach(region, right, Vector2i.RIGHT)
	_attach(region, left, Vector2i.LEFT)
	var reverse = _region()
	var right_first = UrbanGraph.make_layout(reverse, 0, Vector2i.RIGHT)["layout"]
	_attach(reverse, right_first, Vector2i.RIGHT)
	var middle_second = UrbanGraph.make_layout(reverse, 0, Vector2i.ZERO)["layout"]
	if not right_first.grid_families.is_empty() or middle_second.grid_families.size()!=2:
		_fail("An unanchored district rotated, or a later anchored district lost its arterial boundary.")
		return
	var adjacent = _region()
	var approved_middle = UrbanGraph.make_layout(adjacent, 0, Vector2i.ZERO)["layout"]
	_attach(adjacent, approved_middle, Vector2i.ZERO)
	var approved_right = UrbanGraph.make_layout(adjacent, 0, Vector2i.RIGHT)["layout"]
	_attach(adjacent, approved_right, Vector2i.RIGHT)
	var farther_sector := Vector2i(2, 0)
	var established_below = Layout.new()
	established_below.polygon = UrbanGraph.sector_outline(adjacent.cities[0]["street_plan"], Vector2i(2, -1), adjacent, 0)
	established_below.bounds = Geography._bounds(established_below.polygon)
	_attach(adjacent, established_below, Vector2i(2, -1))
	var farther_outline: PackedVector2Array = UrbanGraph.sector_outline(adjacent.cities[0]["street_plan"], farther_sector, adjacent, 0)
	# A ray to the arterial passes through an intervening barrier, but the
	# candidate still shares an open edge with an approved angled district.
	var intervening = Roads.new()
	intervening.id = 2
	intervening.road_class = Roads.HIGHWAY
	intervening.points = PackedVector2Array([Vector2(2.0, -3.0), Vector2(2.0, 3.0)])
	adjacent.road_links.append(intervening)
	if GridFamily._corridor_reaches_outline(adjacent, 0, 0, Vector2(-1.0, -1.8), Vector2(1.5, .7), farther_outline, -1.0):
		_fail("The regression did not block the arbitrary arterial reach ray.")
		return
	var inherited = UrbanGraph.make_layout(adjacent, 0, farther_sector)["layout"]
	if inherited.grid_families.size() != 1 or inherited.grid_families[0]["key"] != approved_right.grid_families[0]["key"] or _shared_nodes(approved_right, inherited) < 2:
		_fail("An approved angled neighbor did not carry its grid across their open shared edge.")
		return
	# A major road on that shared edge is a genuine boundary and stops the
	# chart even though the districts remain geometrically adjacent.
	var boundary = Roads.new()
	boundary.id = 3
	boundary.road_class = Roads.HIGHWAY
	boundary.points = PackedVector2Array([Vector2(2.56, -1.0), Vector2(2.56, 2.0)])
	adjacent.road_links.append(boundary)
	var isolated = UrbanGraph.make_layout(adjacent, 0, farther_sector)["layout"]
	if not isolated.grid_families.is_empty():
		_fail("An angled grid crossed a highway on the shared district edge.")
		return
	adjacent.road_links.pop_back()
	adjacent.rail_reservations.append({"city_id": 0, "points": boundary.points})
	isolated = UrbanGraph.make_layout(adjacent, 0, farther_sector)["layout"]
	if not isolated.grid_families.is_empty():
		_fail("An angled grid crossed rail on the shared district edge.")
		return
	# A claimed legacy district with the same chart ID, separated by empty
	# land, must not become a new source of diagonal grids.
	var floating = approved_right.copy()
	floating.polygon = UrbanGraph.sector_outline(adjacent.cities[0].street_plan,Vector2i(8,0),adjacent,0)
	floating.bounds = Geography._bounds(floating.polygon)
	_attach(adjacent,floating,Vector2i(8,0))
	var beyond_floating = UrbanGraph.make_layout(adjacent,0,Vector2i(9,0)).layout
	if not beyond_floating.grid_families.is_empty():
		_fail("An unanchored legacy grid propagated across more empty land.")
		return
	adjacent.road_links.clear()
	adjacent.rail_reservations.clear()
	adjacent.road_geometry_revision += 1
	if not UrbanGraph.make_layout(adjacent,0,farther_sector).layout.grid_families.is_empty():
		_fail("Removing the source arterial left its old chart able to seed new districts.")
		return
	print("Rotated grids require physical arterial frontage or contiguous road-anchored neighbors.")
	quit(0)


func _around_arterial_bend() -> bool:
	var region = _region()
	region.urban_sector_claims.erase("0:1:-1")
	# The diagonal approaches the next district, then turns north just west
	# of it. Its imaginary diagonal extension cuts that district, but the
	# actual road leaves an open shared edge with the approved rotated grid.
	region.road_links[0].points = PackedVector2Array([Vector2(-1,-1.8),Vector2(1.2,.4),Vector2(1.2,2.5)])
	region.road_geometry_revision += 1
	var root = UrbanGraph.make_layout(region,0,Vector2i.ZERO).layout
	_attach(region,root,Vector2i.ZERO)
	var neighbor = UrbanGraph.make_layout(region,0,Vector2i.RIGHT).layout
	_attach(region,neighbor,Vector2i.RIGHT)
	var continued = UrbanGraph.make_layout(region,0,Vector2i(1,-1)).layout
	if neighbor.grid_families.size()!=1 or continued.grid_families.size()!=1 or continued.grid_families[0].key!=neighbor.grid_families[0].key or _shared_nodes(neighbor,continued)<2:
		_fail("A rotated grid reverted across an open approved frontage beyond the arterial's bend.")
		return false
	var covered := 0.0
	for block in continued.blocks:
		covered += Geography.polygon_area(block.polygon)
	if absf(covered-Geography.polygon_area(continued.polygon)) > Geography.polygon_area(continued.polygon)*.001:
		_fail("Continuing the grid around the bend left gaps in the district.")
		return false
	# Unlike that imaginary extension, a real crossing remains a barrier.
	# Short curve samples must count just as much as one long road segment.
	var boundary_points := PackedVector2Array()
	for index in range(71):
		boundary_points.append(Vector2(1.9,-.1+float(index)*.02))
	for kind in [Roads.HIGHWAY,Roads.ARTERIAL,"rail"]:
		if kind=="rail":
			region.rail_reservations.append({"city_id":0,"points":boundary_points})
		else:
			var boundary = Roads.new()
			boundary.id = region.road_links.size()
			boundary.road_class = kind
			boundary.points = boundary_points
			region.road_links.append(boundary)
		region.road_geometry_revision += 1
		if not GridFamily.continue_chart(region,0,Vector2i(1,-1),continued.polygon,{}).is_empty():
			_fail("A continuing grid crossed a physical %s inside the next district." % kind)
			return false
		if kind=="rail":
			region.rail_reservations.pop_back()
		else:
			region.road_links.pop_back()
		region.road_geometry_revision += 1
	return true


func _region():
	var region = Region.new()
	region.generation_seed = 8752568
	var plan := {"axis": Vector2.RIGHT, "origin": Vector2.ZERO, "column_spacing": 0.16, "row_spacing": 0.09}
	region.cities.append({"id": 0, "center_km": Vector2(-0.8, 0.6), "street_axis": Vector2.RIGHT, "street_plan": plan})
	for kind in [Jurisdiction.STATE, Jurisdiction.CITY]:
		var area = Jurisdiction.new()
		area.id = region.jurisdictions.size()
		area.kind = kind
		area.bounds_km = Rect2(Vector2(-16, -16), Vector2(32, 32))
		area.polygon_km = PackedVector2Array([Vector2(-16, -16), Vector2(16, -16), Vector2(16, 16), Vector2(-16, 16)])
		region.jurisdictions.append(area)
	region.city_jurisdiction_ids.append(1)
	var base_below = UrbanGraph.make_layout(region, 0, Vector2i(1, -1))["layout"]
	_attach(region, base_below, Vector2i(1, -1))
	var road = Roads.new()
	road.id = 0
	road.from_node_id = 0
	road.to_node_id = 1
	road.road_class = Roads.ARTERIAL
	road.points = PackedVector2Array([Vector2(-1.0, -1.8), Vector2(1.5, .7)])
	region.road_links.append(road)
	for index in range(2):
		var node = RoadNode.new()
		node.id = index
		node.position_km = road.points[index]
		region.road_nodes.append(node)
	return region


func _attach(region, layout, sector: Vector2i) -> void:
	var neighborhood = Neighborhood.new()
	neighborhood.id = region.neighborhoods.size()
	neighborhood.city_id = 0
	neighborhood.street_layout = layout
	region.neighborhoods.append(neighborhood)
	region.urban_sector_claims[UrbanGraph.sector_key(0, sector)] = neighborhood.id


func _shared_nodes(first, second) -> int:
	var shared := 0
	for key in first.canonical_nodes.values():
		if second.canonical_nodes.values().has(key):
			shared += 1
	return shared


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
