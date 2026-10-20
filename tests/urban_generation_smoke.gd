extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const LayoutGenerator = preload("res://scripts/simulation/street_layout_generator.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const Generator = preload("res://scripts/simulation/region_generator.gd")
const RoadGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")
const Planner = preload("res://scripts/simulation/road_planner.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var starter_highway_counts: Dictionary = {}
	for city_count in [32, 256, 768]:
		for seed_value in ([1, 2, 7, 42, 291, 1729, 3819, 6061, 8363444, 918273] if city_count == 32 else [42, 6061]):
			var setup: Dictionary = Setup.build(seed_value, city_count, 0.1)
			var region = setup["region"]
			_check(setup["errors"].is_empty(), "seed %d at %d cities must validate: %s" % [seed_value, city_count, setup["errors"]])
			var streeted := 0
			var rectangular := 0
			var irregular := 0
			var triangles := 0
			var quadrilaterals := 0
			var elongated_blocks := 0
			var corridors: Dictionary = {}
			var arterial_neighbors: Dictionary = {}
			for link in region.road_links:
				if link.road_class != Roads.ARTERIAL:
					continue
				if not corridors.has(link.corridor_id):
					corridors[link.corridor_id] = {"origin": link.points[0], "axis": (link.points[-1] - link.points[0]).normalized(), "length": 0.0, "links": 0, "deviation": 0.0}
				var corridor: Dictionary = corridors[link.corridor_id]
				corridor["length"] += link.length_km
				corridor["links"] += 1
				for point in link.points:
					corridor["deviation"] = maxf(float(corridor["deviation"]), absf((point - corridor["origin"]).cross(corridor["axis"])))
				for node_id in [link.from_node_id, link.to_node_id]:
					if not arterial_neighbors.has(node_id):
						arterial_neighbors[node_id] = []
				arterial_neighbors[link.from_node_id].append(link.to_node_id)
				arterial_neighbors[link.to_node_id].append(link.from_node_id)
			var long_corridors := 0
			for corridor in corridors.values():
				if int(corridor["links"]) > 1:
					_check(float(corridor["deviation"]) < 0.30, "arterial spines must bend smoothly without wandering across neighborhood blocks")
				long_corridors += 1 if corridor["length"] >= 3.0 else 0
			_check(long_corridors >= 16, "most arterial spines must continue for several kilometers without turning")
			var visited: Dictionary = {}
			for node_id in arterial_neighbors:
				if visited.has(node_id):
					continue
				var pending: Array = [Vector2i(node_id, -1)]
				while not pending.is_empty():
					var current: Vector2i = pending.pop_back()
					_check(not visited.has(current.x), "arterials must not trace closed rings around starter neighborhoods")
					if visited.has(current.x):
						continue
					visited[current.x] = true
					for neighbor_id in arterial_neighbors[current.x]:
						if neighbor_id != current.y:
							pending.append(Vector2i(neighbor_id, current.x))
			var all_starter_polygons: Array[PackedVector2Array] = []
			var highway_corridors: Dictionary = {}
			for city_id in region.starting_city_ids:
				var hub = region.road_nodes[region.city_hub_node_ids[city_id]]
				var access = region.road_nodes[region.city_highway_access_node_ids[city_id]]
				_check(not hub.is_interchange and access.is_interchange and hub.id != access.id and hub.managed_neighborhood_id < 0, "city centers and peripheral highway exits must be distinct")
				_check(hub.position_km.distance_to(access.position_km) <= 45.0, "starting cities need a nearby highway exit instead of a long cross-state arterial")
				var polygons: Array = []
				for neighborhood_id in region.cities[city_id]["neighborhood_ids"]:
					var neighborhood = region.neighborhoods[neighborhood_id]
					var layout = neighborhood.street_layout
					if layout == null:
						continue
					_check(layout.interior_style == "Grid", "starting neighbourhoods must use regular interior streets")
					streeted += 1
					if _rectangular(layout.polygon):
						rectangular += 1
					else:
						irregular += 1
					var block_area := 0.0
					for block in layout.blocks:
						if block.get("demolished", false):
							continue
						triangles += 1 if block["polygon"].size() == 3 else 0
						quadrilaterals += 1 if block["polygon"].size() == 4 else 0
						if block["polygon"].size() == 4 and not block.get("fringe", false):
							var first_side: float = block["polygon"][0].distance_to(block["polygon"][1])
							var second_side: float = block["polygon"][1].distance_to(block["polygon"][2])
							if maxf(first_side, second_side) / maxf(0.001, minf(first_side, second_side)) > 1.4:
								elongated_blocks += 1
						var area: float = Geography.polygon_area(block["polygon"])
						block_area += area
						_check(not LayoutGenerator.triangulate(block["polygon"]).is_empty(), "varied street blocks must remain simple polygons")
					_check(block_area <= Geography.polygon_area(layout.polygon) * 1.002, "block subdivisions must not overlap or exceed their neighborhood")
					_check(not layout.arterial_nodes.is_empty() and neighborhood.access_node_ids.size() >= 2 and region.neighborhood_development_connected[neighborhood_id] != 0, "every occupied district needs arterial frontage and multiple connected streets: seed %d, %d cities, district %d" % [seed_value, city_count, neighborhood_id])
					var arterial_length := 0.0
					var boundary_length := 0.0
					for edge_id in range(layout.edges.size()):
						if layout.classes[edge_id] == Roads.ARTERIAL:
							arterial_length += layout.lengths[edge_id]
							boundary_length += layout.lengths[edge_id]
						elif layout.classes[edge_id] == Roads.COLLECTOR:
							var edge: Vector2 = layout.edges[edge_id]
							var midpoint: Vector2 = (layout.nodes[int(edge.x)] + layout.nodes[int(edge.y)]) * 0.5
							for segment in range(layout.polygon.size()):
								if midpoint.distance_to(Geometry2D.get_closest_point_to_segment(midpoint, layout.polygon[segment], layout.polygon[(segment + 1) % layout.polygon.size()])) < 0.001:
									boundary_length += layout.lengths[edge_id]
									break
					_check(arterial_length < boundary_length * 0.8, "neighborhood boundaries must not all become arterial roads")
					for previous in polygons:
						var overlap := 0.0
						for piece in Geometry2D.intersect_polygons(layout.polygon, previous):
							overlap += Geography.polygon_area(piece)
						_check(overlap < 0.001, "starter neighborhoods must not overlap")
					polygons.append(layout.polygon)
					all_starter_polygons.append(layout.polygon)
			for link in region.road_links:
				if link.road_class != Roads.HIGHWAY:
					continue
				var corridor_bounds: Rect2 = highway_corridors.get(link.corridor_id, Rect2(link.points[0], Vector2.ZERO))
				for point in link.points:
					corridor_bounds = corridor_bounds.expand(point)
				highway_corridors[link.corridor_id] = corridor_bounds
				for mask in RoadLand.clearance_corridor(link.points, Roads.HIGHWAY):
					var mask_bounds: Rect2 = Geography._bounds(mask)
					for polygon in all_starter_polygons:
						if not mask_bounds.intersects(Geography._bounds(polygon)):
							continue
						for overlap in Geometry2D.intersect_polygons(mask, polygon):
							_check(Geography.polygon_area(overlap) < 0.00001, "regional highway %d crosses a starter neighbourhood at seed %d / %d cities (%.5f km²)" % [link.id, seed_value, city_count, Geography.polygon_area(overlap)])
			if city_count == 32:
				var trunks := 0
				for bounds in highway_corridors.values():
					if bounds.size.x > 250.0 and bounds.size.x > bounds.size.y * 2.0:
						trunks += 1
				_check(trunks >= 1 and trunks <= 3 and highway_corridors.size() == trunks * 2 - 1, "starter highway corridors must form one connected network of one to three trunks")
				starter_highway_counts[trunks] = true
				if seed_value == 42:
					var repeated = Generator.generate_region(seed_value)
					RoadGenerator.generate(repeated)
					_check(repeated.road_links.size() == region.road_links.size(), "the same seed must reproduce the regional road graph")
					if repeated.road_links.size() == region.road_links.size():
						for link_index in range(region.road_links.size()):
							_check(repeated.road_links[link_index].points == region.road_links[link_index].points, "the same seed must reproduce each road route")
					_check(repeated.neighborhoods[0].street_layout.nodes == region.neighborhoods[0].street_layout.nodes, "the same seed must reproduce the district street field")
			_check(streeted == 40, "seed %d at %d cities must have all forty starting street layouts" % [seed_value, city_count])
			_check(rectangular == 0 and irregular == streeted, "all starter neighborhoods with open arterial spines need irregular boundaries: %d rectangular, %d irregular" % [rectangular, irregular])
			_check(quadrilaterals > triangles * 4 and elongated_blocks > quadrilaterals * 0.55, "regular interiors must favour rectangular blocks: %d / %d elongated" % [elongated_blocks, quadrilaterals])
			var first_layout = region.neighborhoods[0].street_layout
			var filled := 0.0
			for block in first_layout.blocks:
				if block.get("demolished", false):
					continue
				filled += Geography.polygon_area(block["polygon"])
			_check(filled >= Geography.polygon_area(first_layout.polygon) * 0.90, "street blocks must follow and fill an irregular starter neighborhood")
			print("Seed %d (%d cities): %d rectangular / %d irregular districts, %d triangular blocks" % [seed_value, city_count, rectangular, irregular, triangles])
	_check_shared_collectors()
	_check(starter_highway_counts.size() >= 2, "seeded starter maps should vary their number of main highways")
	if failures == 0:
		print("Fourteen seeded states retain varied neighborhoods and blocks around long, coherent arterial spines without arterial perimeter rings.")
	quit(1 if failures > 0 else 0)


func _check_shared_collectors() -> void:
	for seed_value in [1729, 6061, 42]:
		var region = Generator.generate_large_region(seed_value, 32)
		var city: Dictionary = region.cities[0]
		var source = region.neighborhoods[city["neighborhood_ids"][0]]
		var polygon: PackedVector2Array = region.jurisdictions[source.jurisdiction_id].polygon_km
		while city["neighborhood_ids"].size() < 20:
			var neighborhood = Generator.append_neighborhood(region, 0, polygon, Vector2i(10000 + city["neighborhood_ids"].size(), 10000))
			neighborhood.initially_developed = true
		RoadGenerator.generate(region)
		for neighborhood_id in city["neighborhood_ids"]:
			_check(region.neighborhoods[neighborhood_id].street_layout != null, "a larger city must retain all twenty street districts")
		for link_index in range(region.road_links.size()):
			var link = region.road_links[link_index]
			if link.road_class != Roads.COLLECTOR or region.road_nodes[link.from_node_id].city_id != 0:
				continue
			for segment in range(1, link.points.size()):
				var midpoint: Vector2 = (link.points[segment - 1] + link.points[segment]) * 0.5
				for other_index in Spatial.near_links(region, midpoint):
					if other_index <= link_index:
						continue
					var other = region.road_links[other_index]
					if other.road_class == Roads.COLLECTOR:
						_check(midpoint.distance_to(Planner.closest_point(other.points, midpoint)) >= 0.0005, "shared collector borders must be one connected road, not duplicate overlapping links")


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)


func _rectangular(polygon: PackedVector2Array) -> bool:
	if polygon.size() != 4:
		return false
	for index in range(4):
		var incoming: Vector2 = (polygon[index] - polygon[posmod(index - 1, 4)]).normalized()
		var outgoing: Vector2 = (polygon[(index + 1) % 4] - polygon[index]).normalized()
		if absf(incoming.dot(outgoing)) > 0.025:
			return false
	return true
