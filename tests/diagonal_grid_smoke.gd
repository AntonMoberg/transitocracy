extends SceneTree

const Region = preload("res://scripts/simulation/region_data.gd")
const CityPlan = preload("res://scripts/simulation/city_street_plan.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Layout = preload("res://scripts/simulation/street_layout.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const Neighborhood = preload("res://scripts/simulation/neighborhood_data.gd")
const Jurisdiction = preload("res://scripts/simulation/jurisdiction_data.gd")
const RoadNode = preload("res://scripts/simulation/road_node_data.gd")
const UrbanGraph = preload("res://scripts/simulation/urban_street_graph.gd")
const GridFamily = preload("res://scripts/simulation/grid_family_layout.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var region = Region.new()
	region.generation_seed = 8752568
	var plan := {"axis": Vector2.RIGHT, "origin": Vector2.ZERO, "column_spacing": 0.16, "row_spacing": 0.09}
	region.cities.append({"id": 0, "center_km": Vector2(-0.8, 0.6), "street_axis": Vector2.RIGHT, "street_plan": plan})
	var road = Roads.new()
	road.id = 0
	road.from_node_id = 0
	road.to_node_id = 1
	road.road_class = Roads.ARTERIAL
	road.points = PackedVector2Array([Vector2(-1.0, -1.0), Vector2(1.0, 1.0)])
	region.road_links.append(road)
	for index in range(2):
		var node = RoadNode.new()
		node.id = index
		node.position_km = road.points[index]
		region.road_nodes.append(node)
	for kind in [Jurisdiction.STATE, Jurisdiction.CITY]:
		var area = Jurisdiction.new()
		area.id = region.jurisdictions.size()
		area.kind = kind
		area.bounds_km = Rect2(Vector2(-3, -3), Vector2(6, 6))
		area.polygon_km = PackedVector2Array([Vector2(-3, -3), Vector2(3, -3), Vector2(3, 3), Vector2(-3, 3)])
		region.jurisdictions.append(area)
	region.city_jurisdiction_ids.append(1)
	var first: Vector2 = CityPlan.junction(region, 0, Vector2i(2, -3), plan)
	var second: Vector2 = CityPlan.junction(region, 0, Vector2i(4, -3), plan)
	var city_first: Vector2 = CityPlan.junction(region, 0, Vector2i(2, 3), plan)
	var city_second: Vector2 = CityPlan.junction(region, 0, Vector2i(4, 3), plan)
	if first != CityPlan.base_junction(plan, Vector2i(2, -3)) or second != CityPlan.base_junction(plan, Vector2i(4, -3)) or city_first != CityPlan.base_junction(plan, Vector2i(2, 3)) or city_second != CityPlan.base_junction(plan, Vector2i(4, 3)):
		push_error("An arterial bent the established city grid.")
		quit(1)
		return
	var chart: Dictionary = GridFamily.separating_chart(region, 0, UrbanGraph.sector_outline(plan, Vector2i(0, 0)), plan)
	if chart.is_empty() or absf(chart["axis"].dot(Vector2(1, 1).normalized())) < 0.999:
		push_error("A long diagonal arterial did not establish a straight perpendicular grid across it.")
		quit(1)
		return
	road.corridor_id = 77
	road.points = PackedVector2Array([Vector2(-1.0, -1.0), Vector2.ZERO])
	var split = Roads.new()
	split.id = 1
	split.road_class = Roads.ARTERIAL
	split.corridor_id = 77
	split.corridor_start_km = sqrt(2.0)
	split.points = PackedVector2Array([Vector2.ZERO, Vector2(1.0, 1.0)])
	region.road_links.append(split)
	if GridFamily.separating_chart(region, 0, UrbanGraph.sector_outline(plan, Vector2i(0, 0)), plan).is_empty():
		push_error("Splitting an arterial at a junction lost its rotated street family.")
		quit(1)
		return
	region.road_links.remove_at(1)
	road.points = PackedVector2Array([Vector2(-1.0, -1.0), Vector2(1.0, 1.0)])
	road.corridor_id = -1
	region.urban_locked_junctions["0:2:-3"] = first
	region.road_geometry_revision += 1
	if CityPlan.junction(region, 0, Vector2i(2, -3), plan) != first:
		push_error("A built junction moved after a road geometry refresh.")
		quit(1)
		return
	var generated: Dictionary = UrbanGraph.make_layout(region, 0, Vector2i(0, 0))
	var district = generated["layout"]
	if generated["frontage_id"] < 0 or district.polygon.size() < 5 or district.blocks.is_empty() or district.grid_families.is_empty():
		push_error("An arterial-influenced irregular district was not buildable.")
		quit(1)
		return
	if district.copy().grid_families.size() != district.grid_families.size():
		push_error("A copied district lost its shared street family.")
		quit(1)
		return
	for block in district.blocks:
		if Geometry2D.triangulate_polygon(block["polygon"]).is_empty():
			push_error("The diagonal street field folded a block.")
			quit(1)
			return
	var farther = UrbanGraph.make_layout(region, 0, Vector2i(0, 1))["layout"]
	if farther.grid_families.is_empty() or farther.blocks.is_empty() or farther.grid_families[-1]["key"] != district.grid_families[-1]["key"]:
		push_error("The far-side grid changed at a district without arterial frontage.")
		quit(1)
		return
	var shared_nodes := 0
	for key in district.canonical_nodes.values():
		if farther.canonical_nodes.values().has(key):
			shared_nodes += 1
	if shared_nodes < 2:
		push_error("Neighboring districts did not share straight-grid junctions.")
		quit(1)
		return
	if not _straight_continuation(district, farther):
		push_error("A street changed heading at a district boundary without a road boundary.")
		quit(1)
		return
	var approved_farther = Neighborhood.new()
	approved_farther.street_layout = farther
	region.neighborhoods.append(approved_farther)
	region.urban_sector_claims["0:0:1"] = 0
	var next_outline: PackedVector2Array = UrbanGraph.sector_outline(plan, Vector2i(0, 2))
	var continuation: Dictionary = GridFamily.separating_chart(region, 0, next_outline, plan)
	if continuation.is_empty() or continuation["key"] != chart["key"]:
		push_error("A farther district failed to keep the road's grid without arterial frontage.")
		quit(1)
		return
	if GridFamily.continue_chart(region, 0, Vector2i(0, 2), next_outline, continuation)["key"] != chart["key"]:
		push_error("Approving an adjacent district changed the planned grid family.")
		quit(1)
		return
	approved_farther.initially_developed = true
	if GridFamily.continue_chart(region, 0, Vector2i(0, 2), next_outline, continuation)["far_side"] != continuation["far_side"]:
		push_error("A district lost the grid angle established by its developed neighbor.")
		quit(1)
		return
	region.urban_sector_claims.erase("0:0:1")
	road.points = PackedVector2Array([Vector2(-1.0, -2.6), Vector2(2.0, 0.4)])
	region.road_nodes[0].position_km = road.points[0]
	region.road_nodes[1].position_km = road.points[1]
	region.street_spatial_cache.clear()
	region.road_geometry_revision += 1
	var shifted: Dictionary = UrbanGraph.make_layout(region, 0, Vector2i(0, 0))
	var shifted_chart: Dictionary = GridFamily.separating_chart(region, 0, shifted["layout"].polygon, plan)
	if shifted_chart.is_empty():
		push_error("The shifted diagonal arterial did not divide a developable district.")
		quit(1)
		return
	var established_base = Neighborhood.new()
	established_base.street_layout = UrbanGraph.make_layout(region, 0, Vector2i(0, 1))["layout"]
	established_base.street_layout.grid_families.clear()
	region.neighborhoods.append(established_base)
	region.urban_sector_claims["0:0:1"] = 1
	var south_chart: Dictionary = GridFamily.continue_chart(region, 0, Vector2i(0, 0), shifted["layout"].polygon, shifted_chart)
	if int(south_chart["far_side"]) != -1 or not south_chart.has("base_chart") or not south_chart.has("far_chart"):
		push_error("The built base grid did not keep the city-facing side of the diagonal arterial.")
		quit(1)
		return
	var portal_chart: Dictionary = south_chart["far_chart"]
	var portals: PackedFloat32Array = portal_chart.get("column_coordinates", PackedFloat32Array())
	var portal_count := 0
	for coordinate in portals:
		var crossing: Vector2 = portal_chart["origin"] + portal_chart["axis"] * coordinate * float(portal_chart["column_spacing"])
		var address: Vector2 = crossing - plan["origin"]
		var column: float = address.dot(plan["axis"]) / float(plan["column_spacing"])
		var row: float = address.dot(plan["axis"].orthogonal()) / float(plan["row_spacing"])
		if absf(column - roundf(column)) > 0.001 and absf(row - roundf(row)) > 0.001:
			push_error("A projected arterial junction missed both established street families.")
			quit(1)
			return
		if crossing.x >= -1.0 and crossing.x <= 1.0:
			portal_count += 1
	if portal_count < 5:
		push_error("The new side of the arterial has too few street junctions.")
		quit(1)
		return
	var inherited = UrbanGraph.make_layout(region, 0, Vector2i(0, 0))["layout"]
	if inherited.grid_families.size() != 2 or inherited.grid_families[0]["axis"] != plan["axis"] or absf(inherited.grid_families[1]["axis"].dot(chart["axis"])) < 0.999:
		push_error("The built-side grid rotated or the undeveloped-side grid stayed unrotated.")
		quit(1)
		return
	var arterial_connections := {-1: 0, 1: 0}
	var approaches: Dictionary = {-1: [], 1: []}
	var arterial_axis: Vector2 = shifted_chart["axis"]
	for edge in inherited.edges:
		for end_id in [int(edge.x), int(edge.y)]:
			var point: Vector2 = inherited.nodes[end_id]
			var other: Vector2 = inherited.nodes[int(edge.y) if end_id == int(edge.x) else int(edge.x)]
			if absf(arterial_axis.cross(point - road.points[0])) > 0.002 or point.distance_to(Geometry2D.get_closest_point_to_segment(point, road.points[0], road.points[-1])) > 0.002:
				continue
			var other_side: float = arterial_axis.cross(other - road.points[0])
			if absf(other_side) <= 0.01:
				continue
			var side: int = 1 if other_side > 0.0 else -1
			arterial_connections[side] += 1
			approaches[side].append(point)
	var rotated_side: int = int(shifted_chart["far_side"])
	if arterial_connections[rotated_side] < 4:
		push_error("The new grid has too few local street connections to the diagonal arterial: %s" % arterial_connections)
		quit(1)
		return
	var through_junctions := 0
	for new_point in approaches[rotated_side]:
		for old_point in approaches[-rotated_side]:
			if new_point.distance_to(old_point) < 0.002:
				through_junctions += 1
				break
	if through_junctions < 3:
		push_error("Projected roads did not continue through the arterial: %d shared junctions." % through_junctions)
		quit(1)
		return
	var saved_center: Vector2 = region.cities[0]["center_km"]
	region.cities[0]["center_km"] = Vector2(5.0, 5.0)
	var crossed_locally: Dictionary = GridFamily.separating_chart(region, 0, inherited.polygon, plan)
	if crossed_locally.is_empty():
		push_error("A diagonal arterial through a district needed the city center to lie on its opposite side.")
		quit(1)
		return
	var stable_side: int = int(crossed_locally["far_side"])
	for trial in range(32):
		road.corridor_id = trial
		var trial_chart: Dictionary = GridFamily.separating_chart(region, 0, inherited.polygon, plan)
		if not trial_chart.is_empty() and int(trial_chart["far_side"]) != stable_side:
			push_error("Changing a corridor id randomly reversed the grid's arterial side.")
			quit(1)
			return
	road.corridor_id = -1
	region.cities[0]["center_km"] = saved_center
	for checked_layout in [district, farther, inherited]:
		var covered := 0.0
		for block in checked_layout.blocks:
			covered += Geography.polygon_area(block["polygon"])
		var area: float = Geography.polygon_area(checked_layout.polygon)
		if absf(covered - area) > area * 0.001:
			push_error("Clipped grids left %.3f square kilometers uncovered in a district." % (area - covered))
			quit(1)
			return
	for degrees in [25.0, 35.0, 55.0, 65.0]:
		var direction := Vector2.from_angle(deg_to_rad(degrees))
		road.points = PackedVector2Array([-direction * 1.4, direction * 1.4])
		region.road_nodes[0].position_km = road.points[0]
		region.road_nodes[1].position_km = road.points[1]
		region.street_spatial_cache.clear()
		region.road_geometry_revision += 1
		var checked := 0
		for sector in [Vector2i(0, 0), Vector2i(0, -1), Vector2i(1, 0)]:
			var changed: Dictionary = UrbanGraph.make_layout(region, 0, sector)
			if changed["frontage_id"] < 0:
				continue
			checked += 1
			var changed_layout = changed["layout"]
			if Geometry2D.triangulate_polygon(changed_layout.polygon).is_empty():
				push_error("A diagonal road at %.0f degrees produced an invalid district." % degrees)
				quit(1)
				return
			for block in changed_layout.blocks:
				if Geometry2D.triangulate_polygon(block["polygon"]).is_empty():
					push_error("A diagonal road at %.0f degrees folded a block." % degrees)
					quit(1)
					return
		if checked == 0:
			push_error("No district reached the diagonal road at %.0f degrees." % degrees)
			quit(1)
			return
	road.points = PackedVector2Array([Vector2(-1.4, 0.0), Vector2(0.0, 0.36), Vector2(1.4, 0.0)])
	region.road_nodes[0].position_km = road.points[0]
	region.road_nodes[1].position_km = road.points[-1]
	region.street_spatial_cache.clear()
	region.road_geometry_revision += 1
	var curved_district = UrbanGraph.make_layout(region, 0, Vector2i(0, 0))["layout"]
	if Geometry2D.triangulate_polygon(curved_district.polygon).is_empty():
		push_error("A curved arterial folded a nearby district boundary.")
		quit(1)
		return
	for block in curved_district.blocks:
		if Geometry2D.triangulate_polygon(block["polygon"]).is_empty():
			push_error("A curved arterial folded a block near its bend.")
			quit(1)
			return
	var layout = Layout.new()
	layout.nodes = PackedVector2Array([
		Vector2(-0.45, -0.4), Vector2(0.45, 0.4),
		Vector2(-0.3, -0.4), Vector2(0.6, 0.4),
		Vector2(-0.15, -0.4), Vector2(0.75, 0.4),
		Vector2(0.0, -0.4), Vector2(0.9, 0.4),
	])
	layout.edges = PackedVector2Array([Vector2(0, 1), Vector2(2, 3), Vector2(4, 5), Vector2(6, 7)])
	layout.classes = PackedStringArray(["Local", "Local", "Local", "Local"])
	layout.phases = PackedInt32Array([2, 2, 2, 2])
	layout.lengths = PackedFloat32Array([1.2, 1.2, 1.2, 1.2])
	layout.polygon = PackedVector2Array([Vector2(-0.5, -0.5), Vector2(1.0, -0.5), Vector2(1.0, 0.5), Vector2(-0.5, 0.5)])
	var masks: Array[PackedVector2Array] = RoadLand.clearance_corridor(PackedVector2Array([Vector2(0, -0.5), Vector2(0, 0.5)]), "Arterial")
	var crossings: PackedInt32Array = RoadLand._arterial_through_edges(layout, PackedVector2Array([Vector2(0, -0.5), Vector2(0, 0.5)]), masks)
	if crossings.size() != 2:
		push_error("The arterial should keep spaced, straight local crossings rather than every crossing: %s" % crossings)
		quit(1)
		return
	var neighborhood = Neighborhood.new()
	neighborhood.street_layout = layout
	RoadLand._demolish_blocks(neighborhood, PackedInt32Array(), masks, PackedInt32Array(), crossings)
	for edge_id in range(4):
		if neighborhood.street_layout.closed_edges.has(edge_id) == crossings.has(edge_id):
			push_error("A preserved crossing was closed or a rejected crossing stayed open.")
			quit(1)
			return
	var trimmed: Vector2 = RoadLand._trimmed_street_end(layout.nodes[2], layout.nodes[3], masks)
	var original_axis: Vector2 = (layout.nodes[3] - layout.nodes[2]).normalized()
	if absf(original_axis.cross((trimmed - layout.nodes[2]).normalized())) > 0.001 or RoadLand._point_inside_masks(trimmed, masks):
		push_error("A severed local street bent toward the arterial instead of retaining its heading.")
		quit(1)
		return
	print("Diagonal grids remain straight; built junctions stay fixed and arterial local crossings remain straight and spaced.")
	quit(0)


func _straight_continuation(first_layout, second_layout) -> bool:
	var outward: Vector2 = (second_layout.bounds.get_center() - first_layout.bounds.get_center()).normalized()
	for first_id in first_layout.canonical_nodes:
		var key: String = first_layout.canonical_nodes[first_id]
		for second_id in second_layout.canonical_nodes:
			if second_layout.canonical_nodes[second_id] != key:
				continue
			for first_edge in first_layout.edges:
				var first_other := -1
				if int(first_edge.x) == first_id:
					first_other = int(first_edge.y)
				elif int(first_edge.y) == first_id:
					first_other = int(first_edge.x)
				if first_other < 0:
					continue
				var first_direction: Vector2 = (first_layout.nodes[first_other] - first_layout.nodes[first_id]).normalized()
				if absf(first_direction.dot(outward)) < 0.25:
					continue
				for second_edge in second_layout.edges:
					var second_other := -1
					if int(second_edge.x) == second_id:
						second_other = int(second_edge.y)
					elif int(second_edge.y) == second_id:
						second_other = int(second_edge.x)
					if second_other < 0:
						continue
					var second_direction: Vector2 = (second_layout.nodes[second_other] - second_layout.nodes[second_id]).normalized()
					if first_direction.dot(second_direction) < -0.999 and absf(first_direction.cross(second_direction)) < 0.02:
						return true
	return false
