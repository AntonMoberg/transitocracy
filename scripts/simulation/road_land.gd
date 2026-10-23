extends RefCounted

const ARTERIAL_WIDTH_KM = 0.024
const HIGHWAY_WIDTH_KM = 0.050
const LAND_COST_PER_HA = 150000.0
const SITE_COST_PER_HA = 25000.0
const JOB_COMPENSATION = 50000.0
const CLEARANCE_KM = 0.005
const PARCEL_BUFFER_KM = 0.007
const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const NeighborhoodSpatialIndex = preload("res://scripts/simulation/neighborhood_spatial_index.gd")
const RoadTerrain = preload("res://scripts/simulation/road_terrain.gd")


static func width_for(road_class: String) -> float:
	return HIGHWAY_WIDTH_KM if road_class == "Highway" else ARTERIAL_WIDTH_KM


static func corridor(points: PackedVector2Array, road_class: String) -> Array[PackedVector2Array]:
	return Geometry2D.offset_polyline(points, width_for(road_class) * 0.5, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)


static func clearance_corridor(points: PackedVector2Array, road_class: String) -> Array[PackedVector2Array]:
	return Geometry2D.offset_polyline(points, width_for(road_class) * 0.5 + CLEARANCE_KM, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)


static func parcel_corridor(points: PackedVector2Array, road_class: String) -> Array[PackedVector2Array]:
	return Geometry2D.offset_polyline(points, width_for(road_class) * 0.5 + PARCEL_BUFFER_KM, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)


static func _masks_for_paths(paths: Array[PackedVector2Array], road_class: String, kind: int) -> Array[PackedVector2Array]:
	var masks: Array[PackedVector2Array] = []
	for path in paths:
		if path.size() < 2:
			continue
		match kind:
			0: masks.append_array(corridor(path, road_class))
			1: masks.append_array(clearance_corridor(path, road_class))
			2: masks.append_array(parcel_corridor(path, road_class))
	return masks


static func initialize(region) -> void:
	region.road_reservations.clear()
	for link in region.road_links:
		if link.road_class in ["Arterial", "Highway"]:
			var surface_paths: Array[PackedVector2Array] = []
			if region.terrain != null and not link.terrain_spans.is_empty():
				surface_paths = RoadTerrain.surface_paths(region, link.points, link.road_class)
			region.road_reservations.append(_reservation(link.points, link.road_class, link.id, -1, surface_paths))
	for neighborhood in region.neighborhoods:
		if neighborhood.street_layout == null:
			continue
		var highway_masks: Array[PackedVector2Array] = []
		for reservation in region.road_reservations:
			if reservation["road_class"] == "Highway" and reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				highway_masks.append_array(reservation["clearance_masks"])
		var affected: PackedInt32Array = _affected_blocks(neighborhood.street_layout, highway_masks)
		if not affected.is_empty():
			_demolish_blocks(neighborhood, affected, highway_masks)
			var parcel_masks: Array[PackedVector2Array] = []
			for reservation in region.road_reservations:
				if reservation["road_class"] == "Highway" and reservation["bounds"].intersects(neighborhood.street_layout.bounds):
					parcel_masks.append_array(reservation["parcel_masks"])
			_rebuild_blocks(neighborhood, affected, parcel_masks, -1)
			for reservation in region.road_reservations:
				if reservation["road_class"] == "Highway" and reservation["bounds"].intersects(neighborhood.street_layout.bounds):
					_rebuild_streets(neighborhood, reservation["points"], reservation["road_class"], reservation["clearance_masks"])
	for neighborhood in region.neighborhoods:
		neighborhood.baseline_developable_area_ha = neighborhood.developable_area_ha
		_recalculate_neighborhood(region, neighborhood)


static func preview(region, points: PackedVector2Array, road_class: String, surface_paths: Array[PackedVector2Array] = []) -> Dictionary:
	var paths: Array[PackedVector2Array] = surface_paths.duplicate()
	if paths.is_empty():
		paths.append(points)
	var masks: Array[PackedVector2Array] = []
	var clearance_masks: Array[PackedVector2Array] = _masks_for_paths(paths, road_class, 1)
	var land_ha := 0.0
	for path in paths:
		if path.size() < 2:
			continue
		var dry_fraction: float = _dry_length_fraction(region, path)
		for mask in corridor(path, road_class):
			masks.append(mask)
			land_ha += _unclaimed_area(region, region.jurisdictions[0].polygon_km, mask) * 100.0 * dry_fraction
	var affected: Array[Dictionary] = []
	var home_cost := 0.0
	var job_cost := 0.0
	var developed_ha := 0.0
	var redevelopment_ha := 0.0
	var street_cost := 0.0
	var local_bridge_cost := 0.0
	var mask_bounds: Array[Rect2] = []
	var corridor_bounds := Rect2()
	for mask in masks:
		var bounds: Rect2 = _bounds(mask)
		corridor_bounds = bounds if mask_bounds.is_empty() else corridor_bounds.merge(bounds)
		mask_bounds.append(bounds)
	var nearby_ids: Array[int] = NeighborhoodSpatialIndex.in_bounds(region, corridor_bounds) if not mask_bounds.is_empty() else []
	for neighborhood_id in nearby_ids:
		var neighborhood = region.neighborhoods[neighborhood_id]
		var polygon: PackedVector2Array = region.jurisdictions[neighborhood.jurisdiction_id].polygon_km
		var polygon_bounds: Rect2 = region.jurisdictions[neighborhood.jurisdiction_id].bounds_km
		var area := 0.0
		for mask_id in range(masks.size()):
			if not polygon_bounds.intersects(mask_bounds[mask_id]):
				continue
			area += _unclaimed_area(region, polygon, masks[mask_id])
		if area <= 0.000001:
			continue
		var hectares: float = area * 100.0
		var block_ids := PackedInt32Array()
		var bridge_edges := PackedInt32Array()
		var through_edges := PackedInt32Array()
		if neighborhood.street_layout != null:
			for surface_path in paths:
				for block_id in _redevelopment_blocks(neighborhood.street_layout, surface_path, road_class, clearance_masks):
					if not block_ids.has(block_id):
						block_ids.append(block_id)
				if road_class == "Highway":
					for edge_id in _bridge_edges(neighborhood.street_layout, surface_path, clearance_masks):
						if not bridge_edges.has(edge_id):
							bridge_edges.append(edge_id)
				elif road_class == "Arterial":
					for edge_id in _arterial_through_edges(neighborhood.street_layout, surface_path, clearance_masks):
						if not through_edges.has(edge_id):
							through_edges.append(edge_id)
		local_bridge_cost += float(bridge_edges.size()) * 3000000.0
		for block_id in block_ids:
			redevelopment_ha += float(neighborhood.street_layout.blocks[block_id].get("area_ha", 0.0))
		if neighborhood.street_layout != null:
			for edge_id in _affected_local_edges(neighborhood.street_layout, clearance_masks):
				if through_edges.has(edge_id):
					continue
				street_cost += neighborhood.street_layout.lengths[edge_id] * 120000.0
		var building_impact: Dictionary = _building_displacement(region, neighborhood, clearance_masks, block_ids)
		var area_fraction: float = clampf(hectares / maxf(0.000001, neighborhood.developable_area_ha), 0.0, 1.0)
		var home_fraction: float = float(building_impact.get("home_fraction", area_fraction))
		var job_fraction: float = float(building_impact.get("job_fraction", area_fraction))
		var displaced_homes: int = mini(neighborhood.households, maxi(1 if int(building_impact.get("homes_hit", 0)) > 0 else 0, roundi(float(neighborhood.households) * home_fraction)))
		var displaced_jobs: int = mini(neighborhood.jobs, maxi(1 if int(building_impact.get("jobs_hit", 0)) > 0 else 0, roundi(float(neighborhood.jobs) * job_fraction)))
		var baseline_area: float = maxf(0.000001, neighborhood.baseline_developable_area_ha)
		var next_housing: int = maxi(0, neighborhood.housing_capacity - roundi(float(neighborhood.base_housing_capacity) * hectares / baseline_area))
		var next_jobs: int = maxi(0, neighborhood.job_capacity - roundi(float(neighborhood.base_job_capacity) * hectares / baseline_area))
		displaced_homes = maxi(displaced_homes, neighborhood.households - next_housing)
		displaced_jobs = maxi(displaced_jobs, neighborhood.jobs - next_jobs)
		developed_ha += hectares if block_ids.is_empty() and (neighborhood.households > 0 or neighborhood.jobs > 0) else 0.0
		home_cost += float(displaced_homes) * maxf(120000.0, neighborhood.assessed_home_value)
		job_cost += float(displaced_jobs) * JOB_COMPENSATION
		affected.append({"id": neighborhood.id, "area_ha": hectares, "homes": displaced_homes, "jobs": displaced_jobs, "block_ids": block_ids, "bridge_edges": bridge_edges, "through_edges": through_edges})
	var land_cost: int = roundi(land_ha * LAND_COST_PER_HA)
	var site_cost: int = roundi((developed_ha + redevelopment_ha) * SITE_COST_PER_HA)
	return {"land_ha": land_ha, "land_cost": land_cost, "site_cost": site_cost, "street_cost": roundi(street_cost), "local_bridge_cost": roundi(local_bridge_cost), "home_cost": roundi(home_cost), "job_cost": roundi(job_cost), "neighborhoods": affected, "surface_paths": paths, "cost": land_cost + site_cost + roundi(street_cost + local_bridge_cost + home_cost + job_cost)}


static func _dry_length_fraction(region, path: PackedVector2Array) -> float:
	if region.terrain == null:
		return 1.0
	var total := 0.0
	var dry := 0.0
	for index in range(1, path.size()):
		var first: Vector2 = path[index - 1]
		var last: Vector2 = path[index]
		var length: float = first.distance_to(last)
		var steps: int = maxi(1, ceili(length / 0.025))
		for step in range(steps):
			var midpoint: Vector2 = first.lerp(last, (float(step) + 0.5) / float(steps))
			var portion: float = length / float(steps)
			total += portion
			if not region.terrain.water_at(midpoint):
				dry += portion
	return dry / maxf(0.000001, total)


static func apply(region, points: PackedVector2Array, road_class: String, project_id: int, impact: Dictionary) -> void:
	var surface_paths: Array[PackedVector2Array] = []
	for path in impact.get("surface_paths", [points]):
		surface_paths.append(path)
	var clearance_masks: Array[PackedVector2Array] = _masks_for_paths(surface_paths, road_class, 1)
	for item in impact.get("neighborhoods", []):
		var neighborhood = region.neighborhoods[int(item["id"])]
		_displace(neighborhood, int(item["homes"]), int(item["jobs"]))
		_demolish_blocks(neighborhood, item.get("block_ids", PackedInt32Array()), clearance_masks, item.get("bridge_edges", PackedInt32Array()), item.get("through_edges", PackedInt32Array()))
	region.road_reservations.append(_reservation(points, road_class, -1, project_id, surface_paths))
	for neighborhood in region.neighborhoods:
		if neighborhood.baseline_developable_area_ha <= 0.0:
			neighborhood.baseline_developable_area_ha = neighborhood.developable_area_ha
		_recalculate_neighborhood(region, neighborhood)


static func apply_to_new_neighborhood(region, neighborhood) -> void:
	neighborhood.baseline_developable_area_ha = neighborhood.developable_area_ha
	var masks: Array[PackedVector2Array] = masks_for_bounds(region, neighborhood.street_layout.bounds) if neighborhood.street_layout != null else []
	var affected: PackedInt32Array = _affected_blocks(neighborhood.street_layout, masks) if neighborhood.street_layout != null else PackedInt32Array()
	if not affected.is_empty():
		var preserved := PackedInt32Array()
		var highway_masks: Array[PackedVector2Array] = []
		for reservation in region.road_reservations:
			if reservation["road_class"] == "Highway" and reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				highway_masks.append_array(reservation["clearance_masks"])
		for reservation in region.road_reservations:
			if reservation["road_class"] == "Arterial" and reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				for edge_id in _arterial_through_edges(neighborhood.street_layout, reservation["points"], reservation["clearance_masks"]):
					if not preserved.has(edge_id) and not _layout_edge_intersects_masks(neighborhood.street_layout, edge_id, highway_masks):
						preserved.append(edge_id)
		_demolish_blocks(neighborhood, affected, masks, PackedInt32Array(), preserved)
		var parcel_masks: Array[PackedVector2Array] = []
		for reservation in region.road_reservations:
			if reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				parcel_masks.append_array(reservation.get("parcel_masks", reservation["masks"]))
		_rebuild_blocks(neighborhood, affected, parcel_masks, -1)
		for reservation in region.road_reservations:
			if reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				_rebuild_streets(neighborhood, reservation["points"], reservation["road_class"], reservation.get("clearance_masks", reservation["masks"]))
	_recalculate_neighborhood(region, neighborhood)


static func rebuild_project(region, project) -> void:
	var surface_paths: Array[PackedVector2Array] = project.terrain_surface_paths.duplicate()
	if surface_paths.is_empty():
		surface_paths.append(project.points)
	var masks: Array[PackedVector2Array] = _masks_for_paths(surface_paths, project.road_class, 1)
	for item in project.redevelopment_impact:
		var neighborhood = region.neighborhoods[int(item["id"])]
		if neighborhood.street_layout == null or (item.get("block_ids", PackedInt32Array()).is_empty() and item.get("bridge_edges", PackedInt32Array()).is_empty()):
			continue
		var parcel_masks: Array[PackedVector2Array] = []
		for reservation in region.road_reservations:
			if reservation["bounds"].intersects(neighborhood.street_layout.bounds):
				parcel_masks.append_array(reservation.get("parcel_masks", reservation["masks"]))
		_rebuild_blocks(neighborhood, item.get("block_ids", PackedInt32Array()), parcel_masks, project.open_day_key)
		for surface_path in surface_paths:
			_rebuild_streets(neighborhood, surface_path, project.road_class, masks, item.get("bridge_edges", PackedInt32Array()), item.get("through_edges", PackedInt32Array()))


static func mark_open(region, project_id: int, link_id: int) -> void:
	for reservation in region.road_reservations:
		if int(reservation["project_id"]) == project_id:
			reservation["project_id"] = -1
			reservation["link_id"] = link_id
			return


static func split_link_reservation(region, old_id: int, new_id: int, first: PackedVector2Array, second: PackedVector2Array) -> void:
	for reservation in region.road_reservations:
		if int(reservation["link_id"]) != old_id:
			continue
		var first_paths: Array[PackedVector2Array] = RoadTerrain.surface_paths(region, first, reservation["road_class"])
		var second_paths: Array[PackedVector2Array] = RoadTerrain.surface_paths(region, second, reservation["road_class"])
		var first_reservation: Dictionary = _reservation(first, reservation["road_class"], old_id, -1, first_paths)
		reservation["points"] = first_reservation["points"]
		reservation["masks"] = first_reservation["masks"]
		reservation["clearance_masks"] = first_reservation["clearance_masks"]
		reservation["parcel_masks"] = first_reservation["parcel_masks"]
		reservation["bounds"] = first_reservation["bounds"]
		region.road_reservations.append(_reservation(second, reservation["road_class"], new_id, -1, second_paths))
		return


static func release_link(region, link_id: int) -> void:
	for index in range(region.road_reservations.size() - 1, -1, -1):
		if int(region.road_reservations[index]["link_id"]) == link_id:
			region.road_reservations.remove_at(index)
	for neighborhood in region.neighborhoods:
		_recalculate_neighborhood(region, neighborhood)


static func contains_reserved(region, point: Vector2) -> bool:
	for reservation in region.road_reservations:
		if not reservation["bounds"].has_point(point):
			continue
		for mask in reservation["masks"]:
			if Geometry2D.is_point_in_polygon(point, mask):
				return true
	return false


static func masks_for_bounds(region, bounds: Rect2) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for reservation in region.road_reservations:
		if not bounds.intersects(reservation["bounds"]):
			continue
		for mask in reservation.get("clearance_masks", reservation["masks"]):
			result.append(mask)
	return result


static func polygon_intersects_masks(polygon: PackedVector2Array, masks: Array[PackedVector2Array]) -> bool:
	if polygon.size() < 3:
		return false
	var bounds: Rect2 = _bounds(polygon)
	for mask in masks:
		if not bounds.intersects(_bounds(mask)):
			continue
		for overlap in Geometry2D.intersect_polygons(polygon, mask):
			if _area(overlap) > 0.00000001:
				return true
	return false


static func _affected_blocks(layout, masks: Array[PackedVector2Array]) -> PackedInt32Array:
	var affected := PackedInt32Array()
	if layout == null or masks.is_empty():
		return affected
	for block_id in range(layout.blocks.size()):
		var block: Dictionary = layout.blocks[block_id]
		if block.get("demolished", false):
			continue
		if polygon_intersects_masks(block["polygon"], masks):
			affected.append(block_id)
	return affected


static func _redevelopment_blocks(layout, points: PackedVector2Array, road_class: String, masks: Array[PackedVector2Array]) -> PackedInt32Array:
	var affected: PackedInt32Array = _affected_blocks(layout, masks)
	if layout == null:
		return affected
	# Re-parcel one block depth beside the right of way.  Keep all other
	# neighborhood blocks and streets untouched.
	var reach: float = width_for(road_class) * 0.5 + (0.12 if road_class == "Highway" else 0.09)
	var route_bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		route_bounds = route_bounds.expand(point)
	route_bounds = route_bounds.grow(reach)
	for block_id in range(layout.blocks.size()):
		if affected.has(block_id) or layout.blocks[block_id].get("demolished", false):
			continue
		var polygon: PackedVector2Array = layout.blocks[block_id]["polygon"]
		if not route_bounds.intersects(_bounds(polygon)):
			continue
		var near := false
		for vertex in polygon:
			for segment in range(1, points.size()):
				if vertex.distance_to(Geometry2D.get_closest_point_to_segment(vertex, points[segment - 1], points[segment])) <= reach:
					near = true
					break
			if near:
				break
		if near:
			affected.append(block_id)
	return affected


static func _affected_local_edges(layout, masks: Array[PackedVector2Array]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for edge_id in range(layout.edges.size()):
		if layout.classes[edge_id] != "Local" or layout.closed_edges.has(edge_id):
			continue
		if _layout_edge_intersects_masks(layout, edge_id, masks):
			result.append(edge_id)
	return result


static func _bridge_edges(layout, points: PackedVector2Array, masks: Array[PackedVector2Array]) -> PackedInt32Array:
	var result := PackedInt32Array()
	if layout == null:
		return result
	var options: Array[Dictionary] = []
	var collector_stations := PackedFloat32Array()
	for edge_id in range(layout.edges.size()):
		if layout.closed_edges.has(edge_id) or layout.classes[edge_id] not in ["Local", "Collector"]:
			continue
		var path: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array())
		if path.is_empty():
			var edge: Vector2 = layout.edges[edge_id]
			path = PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]])
		for segment in range(1, path.size()):
			for route_segment in range(1, points.size()):
				var hit = Geometry2D.segment_intersects_segment(path[segment - 1], path[segment], points[route_segment - 1], points[route_segment])
				if hit == null:
					continue
				var station: float = _route_station(points, hit)
				if layout.classes[edge_id] == "Collector":
					collector_stations.append(station)
				elif _layout_edge_intersects_masks(layout, edge_id, masks) and not _point_inside_masks(path[0], masks) and not _point_inside_masks(path[-1], masks):
					options.append({"edge_id": edge_id, "station": station})
				break
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["station"]) < float(b["station"]))
	var chosen := PackedFloat32Array()
	for option in options:
		var station: float = option["station"]
		var near_other := false
		for other in collector_stations:
			if absf(station - other) < 0.35:
				near_other = true
		for other in chosen:
			if absf(station - other) < 0.55:
				near_other = true
		if near_other:
			continue
		result.append(int(option["edge_id"]))
		chosen.append(station)
	return result


static func _arterial_through_edges(layout, points: PackedVector2Array, masks: Array[PackedVector2Array]) -> PackedInt32Array:
	var chosen := PackedInt32Array()
	if layout == null:
		return chosen
	var collector_stations := PackedFloat32Array()
	var options: Array[Dictionary] = []
	for edge_id in range(layout.edges.size()):
		if layout.closed_edges.has(edge_id) or layout.classes[edge_id] not in ["Local", "Collector"]:
			continue
		var path: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array())
		if path.is_empty():
			var edge: Vector2 = layout.edges[edge_id]
			path = PackedVector2Array([layout.nodes[int(edge.x)], layout.nodes[int(edge.y)]])
		for segment in range(1, path.size()):
			var street_axis: Vector2 = (path[segment] - path[segment - 1]).normalized()
			for route_segment in range(1, points.size()):
				var hit = Geometry2D.segment_intersects_segment(path[segment - 1], path[segment], points[route_segment - 1], points[route_segment])
				if hit == null:
					continue
				var road_axis: Vector2 = (points[route_segment] - points[route_segment - 1]).normalized()
				if absf(street_axis.dot(road_axis)) > cos(deg_to_rad(35.0)):
					continue
				var station: float = _route_station(points, hit)
				if layout.classes[edge_id] == "Collector":
					collector_stations.append(station)
				elif _layout_edge_intersects_masks(layout, edge_id, masks) and not _point_inside_masks(path[0], masks) and not _point_inside_masks(path[-1], masks):
					options.append({"edge_id": edge_id, "station": station})
				break
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["station"]) < float(b["station"]))
	var local_stations := PackedFloat32Array()
	for option in options:
		var station: float = option["station"]
		var near_other := false
		for other in collector_stations:
			if absf(station - other) < 0.18:
				near_other = true
		for other in local_stations:
			if absf(station - other) < 0.22:
				near_other = true
		if near_other:
			continue
		chosen.append(int(option["edge_id"]))
		local_stations.append(station)
	return chosen


static func _layout_edge_intersects_masks(layout, edge_id: int, masks: Array[PackedVector2Array]) -> bool:
	var path: PackedVector2Array = layout.edge_paths.get(edge_id, PackedVector2Array())
	if path.is_empty():
		var edge: Vector2 = layout.edges[edge_id]
		return _segment_intersects_masks(layout.nodes[int(edge.x)], layout.nodes[int(edge.y)], masks)
	for segment in range(1, path.size()):
		if _segment_intersects_masks(path[segment - 1], path[segment], masks):
			return true
	return false


static func _demolish_blocks(neighborhood, affected: PackedInt32Array, masks: Array[PackedVector2Array], bridge_edges: PackedInt32Array = PackedInt32Array(), through_edges: PackedInt32Array = PackedInt32Array()) -> void:
	if (affected.is_empty() and bridge_edges.is_empty() and through_edges.is_empty()) or neighborhood.street_layout == null:
		return
	var layout = neighborhood.street_layout.copy()
	for block_id in affected:
		if block_id < 0 or block_id >= layout.blocks.size():
			continue
		var block: Dictionary = layout.blocks[block_id]
		block["previous_zone"] = neighborhood.block_zoning[block_id] if block_id < neighborhood.block_zoning.size() else 0
		block["demolished"] = true
		layout.blocks[block_id] = block
		if block_id < neighborhood.block_zoning.size():
			neighborhood.block_zoning[block_id] = 0
	for edge_id in _affected_local_edges(layout, masks):
		if through_edges.has(edge_id):
			continue
		if not bridge_edges.has(edge_id):
			layout.closed_edges[edge_id] = true
		else:
			layout.grade_separated_edges[edge_id] = "above"
	neighborhood.street_layout = layout


static func _rebuild_blocks(neighborhood, affected: PackedInt32Array, masks: Array[PackedVector2Array], open_day: int) -> void:
	if affected.is_empty() or neighborhood.street_layout == null:
		return
	var layout = neighborhood.street_layout.copy()
	for block_id in affected:
		if block_id < 0 or block_id >= layout.blocks.size():
			continue
		var old: Dictionary = layout.blocks[block_id]
		var fragments: Array[PackedVector2Array] = [old["polygon"]]
		for mask in masks:
			if not _bounds(old["polygon"]).intersects(_bounds(mask)):
				continue
			var remaining: Array[PackedVector2Array] = []
			for fragment in fragments:
				remaining.append_array(Geometry2D.clip_polygons(fragment, mask))
			fragments = remaining
		var old_zone: int = int(old.get("previous_zone", 0))
		for fragment in fragments:
			var area: float = _area(fragment)
			if area < 0.000025 or Geometry2D.triangulate_polygon(fragment).is_empty() or polygon_intersects_masks(fragment, masks):
				continue
			var access_node: int = _nearest_active_node(layout, old["nodes"], fragment, masks)
			if access_node < 0:
				continue
			var block: Dictionary = old.duplicate(true)
			block["polygon"] = fragment
			block["nodes"] = PackedInt32Array([access_node])
			block["area_ha"] = area * 100.0
			block["seed"] = int(old["seed"]) + layout.blocks.size() * 7919
			if old.has("canonical_id"):
				block["canonical_id"] = "%s:rebuilt:%d:%d" % [old["canonical_id"], open_day, layout.blocks.size()]
			block["demolished"] = false
			block["redevelopment_day"] = open_day
			layout.blocks.append(block)
			neighborhood.block_zoning.append(old_zone)
	neighborhood.street_layout = layout


static func _rebuild_streets(neighborhood, points: PackedVector2Array, road_class: String, masks: Array[PackedVector2Array], bridge_edges: PackedInt32Array = PackedInt32Array(), through_edges: PackedInt32Array = PackedInt32Array()) -> void:
	if neighborhood.street_layout == null:
		return
	var layout = neighborhood.street_layout.copy()
	for edge_id in bridge_edges:
		layout.closed_edges.erase(edge_id)
		layout.grade_separated_edges[edge_id] = "above"
	for edge_id in through_edges:
		layout.closed_edges.erase(edge_id)
	var original_edge_count: int = layout.edges.size()
	var highway_frontiers: Array[Vector2] = []
	for edge_id in layout.closed_edges:
		if edge_id >= original_edge_count or layout.classes[edge_id] != "Local":
			continue
		var edge: Vector2 = layout.edges[edge_id]
		if not _layout_edge_intersects_masks(layout, edge_id, masks):
			continue
		for node_id in [int(edge.x), int(edge.y)]:
			var endpoint: Vector2 = layout.nodes[node_id]
			if _point_inside_masks(endpoint, masks):
				continue
			if road_class == "Arterial":
				var opposite_id: int = int(edge.y) if node_id == int(edge.x) else int(edge.x)
				var continuation: Vector2 = _trimmed_street_end(endpoint, layout.nodes[opposite_id], masks)
				if continuation.distance_to(endpoint) > 0.005 and Geography.segment_on_land(layout.polygon, endpoint, continuation):
					var end_id: int = layout.nodes.size()
					layout.nodes.append(continuation)
					_append_local_edge(layout, node_id, end_id, layout.phases[edge_id])
				continue
			var nearest: Vector2 = _nearest_route_point(points, endpoint)
			var outward: Vector2 = (endpoint - nearest).normalized()
			if outward == Vector2.ZERO:
				continue
			var setback: float = PARCEL_BUFFER_KM + 0.02 if road_class == "Highway" else CLEARANCE_KM + 0.001
			var frontier: Vector2 = nearest + outward * (width_for(road_class) * 0.5 + setback)
			if endpoint.distance_to(frontier) > 0.25 or _point_inside_masks(frontier, masks) or not Geography.segment_on_land(layout.polygon, endpoint, frontier):
				continue
			if endpoint.distance_to(frontier) > 0.005:
				var frontier_id: int = layout.nodes.size()
				layout.nodes.append(frontier)
				_append_local_edge(layout, node_id, frontier_id, layout.phases[edge_id])
				if road_class == "Highway":
					highway_frontiers.append(Vector2(frontier_id, _route_station(points, frontier)))
	if road_class == "Highway":
		highway_frontiers.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
		for index in range(1, highway_frontiers.size()):
			var first_id: int = int(highway_frontiers[index - 1].x)
			var last_id: int = int(highway_frontiers[index].x)
			var first: Vector2 = layout.nodes[first_id]
			var last: Vector2 = layout.nodes[last_id]
			if first.distance_to(last) > 0.32 or first.distance_to(last) < 0.02:
				continue
			if _segment_intersects_masks(first, last, masks) or not Geography.segment_on_land(layout.polygon, first, last):
				continue
			_append_local_edge(layout, first_id, last_id, 1)
	neighborhood.street_layout = layout


static func _trimmed_street_end(first: Vector2, last: Vector2, masks: Array[PackedVector2Array]) -> Vector2:
	if _point_inside_masks(first, masks):
		return first
	var low := 0.0
	var high := 1.0
	if not _point_inside_masks(last, masks):
		var found := false
		var probes: int = clampi(ceili(first.distance_to(last) / 0.005), 20, 400)
		for step in range(1, probes + 1):
			var fraction: float = float(step) / float(probes)
			if _point_inside_masks(first.lerp(last, fraction), masks):
				high = fraction
				found = true
				break
		if not found:
			return first
	for _step in range(16):
		var middle: float = (low + high) * 0.5
		if _point_inside_masks(first.lerp(last, middle), masks):
			high = middle
		else:
			low = middle
	return first.lerp(last, maxf(0.0, low - 0.005 / maxf(0.001, first.distance_to(last))))


static func _route_station(points: PackedVector2Array, point: Vector2) -> float:
	var best := INF
	var station := 0.0
	var result := 0.0
	for index in range(1, points.size()):
		var first: Vector2 = points[index - 1]
		var last: Vector2 = points[index]
		var trial: Vector2 = Geometry2D.get_closest_point_to_segment(point, first, last)
		var distance: float = trial.distance_squared_to(point)
		if distance < best:
			best = distance
			result = station + first.distance_to(trial)
		station += first.distance_to(last)
	return result


static func _append_local_edge(layout, first: int, last: int, phase: int) -> void:
	layout.edges.append(Vector2(first, last))
	layout.classes.append("Local")
	layout.phases.append(phase)
	layout.lengths.append(layout.nodes[first].distance_to(layout.nodes[last]))


static func _nearest_route_point(points: PackedVector2Array, point: Vector2) -> Vector2:
	var nearest: Vector2 = points[0]
	var best := INF
	for index in range(1, points.size()):
		var trial: Vector2 = Geometry2D.get_closest_point_to_segment(point, points[index - 1], points[index])
		var distance: float = trial.distance_squared_to(point)
		if distance < best:
			nearest = trial
			best = distance
	return nearest


static func _point_inside_masks(point: Vector2, masks: Array[PackedVector2Array]) -> bool:
	for mask in masks:
		if Geometry2D.is_point_in_polygon(point, mask):
			return true
	return false


static func _nearest_active_node(layout, preferred: PackedInt32Array, polygon: PackedVector2Array, masks: Array[PackedVector2Array]) -> int:
	var center := Vector2.ZERO
	for point in polygon:
		center += point
	center /= float(polygon.size())
	var best := -1
	var distance := INF
	for node_id in preferred:
		if node_id < 0 or node_id >= layout.nodes.size():
			continue
		var point: Vector2 = layout.nodes[node_id]
		var blocked := false
		for mask in masks:
			if Geometry2D.is_point_in_polygon(point, mask):
				blocked = true
				break
		if not blocked and point.distance_squared_to(center) < distance:
			best = node_id
			distance = point.distance_squared_to(center)
	return best


static func _segment_intersects_masks(first: Vector2, last: Vector2, masks: Array[PackedVector2Array]) -> bool:
	var bounds := Rect2(first, Vector2.ZERO).expand(last)
	for mask in masks:
		if not bounds.intersects(_bounds(mask)):
			continue
		if Geometry2D.is_point_in_polygon(first, mask) or Geometry2D.is_point_in_polygon(last, mask):
			return true
		for index in range(mask.size()):
			if Geometry2D.segment_intersects_segment(first, last, mask[index], mask[(index + 1) % mask.size()]) != null:
				return true
	return false


static func _building_displacement(region, neighborhood, new_masks: Array[PackedVector2Array], block_ids: PackedInt32Array) -> Dictionary:
	var layout = neighborhood.street_layout
	if layout == null or neighborhood.block_zoning.is_empty():
		return {}
	var existing_masks: Array[PackedVector2Array] = masks_for_bounds(region, layout.bounds)
	var homes_total := 0
	var jobs_total := 0
	var homes_hit := 0
	var jobs_hit := 0
	for block_id in range(mini(layout.blocks.size(), neighborhood.block_zoning.size())):
		var block: Dictionary = layout.blocks[block_id]
		if block.get("demolished", false):
			continue
		var code: int = neighborhood.block_zoning[block_id] - 1
		if code < 0 or block["park"]:
			continue
		var zone: String = ["Residential", "Commercial", "Office", "Mixed", "Industry"][floori(float(code) / 3.0)]
		var has_homes: bool = zone in ["Residential", "Mixed"]
		var has_jobs: bool = zone != "Residential"
		var density: int = code % 3
		var footprints: Array = ParcelGeometry.buildings(block, zone, density, neighborhood.character_profile, region.terrain)
		for building_id in range(footprints.size()):
			var appearance: float = float(posmod(int(block["seed"]) + building_id * 7919, 1000)) / 1000.0
			if appearance > neighborhood.built_fraction:
				continue
			if polygon_intersects_masks(footprints[building_id], existing_masks):
				continue
			if has_homes:
				homes_total += 1
			if has_jobs:
				jobs_total += 1
			if block_ids.has(block_id) or polygon_intersects_masks(footprints[building_id], new_masks):
				if has_homes:
					homes_hit += 1
				if has_jobs:
					jobs_hit += 1
	var result: Dictionary = {"homes_hit": homes_hit, "jobs_hit": jobs_hit}
	if homes_total > 0:
		result["home_fraction"] = float(homes_hit) / float(homes_total)
	if jobs_total > 0:
		result["job_fraction"] = float(jobs_hit) / float(jobs_total)
	return result


static func _reservation(points: PackedVector2Array, road_class: String, link_id: int, project_id: int, surface_paths: Array[PackedVector2Array] = []) -> Dictionary:
	var paths: Array[PackedVector2Array] = surface_paths.duplicate()
	if paths.is_empty():
		paths.append(points)
	var masks: Array[PackedVector2Array] = _masks_for_paths(paths, road_class, 0)
	var clearance_masks: Array[PackedVector2Array] = _masks_for_paths(paths, road_class, 1)
	var parcel_masks: Array[PackedVector2Array] = _masks_for_paths(paths, road_class, 2)
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return {"points": points, "road_class": road_class, "link_id": link_id, "project_id": project_id, "masks": masks, "clearance_masks": clearance_masks, "parcel_masks": parcel_masks, "bounds": bounds.grow(width_for(road_class))}


static func _displace(neighborhood, homes: int, jobs: int) -> void:
	var previous_homes: int = neighborhood.households
	neighborhood.households = maxi(0, previous_homes - homes)
	if previous_homes > 0:
		neighborhood.population = roundi(float(neighborhood.population) * float(neighborhood.households) / float(previous_homes))
	var previous_jobs: int = neighborhood.jobs
	neighborhood.jobs = maxi(0, previous_jobs - jobs)
	if previous_jobs > 0:
		var entry: int = mini(neighborhood.jobs, roundi(float(neighborhood.jobs_by_skill.get("Entry", 0)) * float(neighborhood.jobs) / float(previous_jobs)))
		var professional: int = mini(neighborhood.jobs - entry, roundi(float(neighborhood.jobs_by_skill.get("Professional", 0)) * float(neighborhood.jobs) / float(previous_jobs)))
		neighborhood.jobs_by_skill = {"Entry": entry, "Skilled": neighborhood.jobs - entry - professional, "Professional": professional}
	neighborhood.shopping_attraction = minf(neighborhood.shopping_attraction, float(neighborhood.jobs))


static func _recalculate_neighborhood(region, neighborhood) -> void:
	var polygon: PackedVector2Array = region.jurisdictions[neighborhood.jurisdiction_id].polygon_km
	var remaining := _area(polygon)
	for reservation_index in range(region.road_reservations.size()):
		var reservation: Dictionary = region.road_reservations[reservation_index]
		if not reservation["bounds"].intersects(region.jurisdictions[neighborhood.jurisdiction_id].bounds_km):
			continue
		for mask in reservation["masks"]:
			remaining -= _unclaimed_area_before(region, polygon, mask, reservation_index)
	var reserved_ha: float = maxf(0.0, _area(polygon) - remaining) * 100.0
	var ratio: float = clampf(1.0 - reserved_ha / maxf(0.000001, neighborhood.baseline_developable_area_ha), 0.0, 1.0)
	neighborhood.developable_area_ha = neighborhood.baseline_developable_area_ha * ratio
	neighborhood.housing_capacity = roundi(float(neighborhood.base_housing_capacity) * ratio)
	neighborhood.job_capacity = roundi(float(neighborhood.base_job_capacity) * ratio)
	if neighborhood.households > neighborhood.housing_capacity:
		var previous_households: int = neighborhood.households
		var previous_population: int = neighborhood.population
		neighborhood.households = neighborhood.housing_capacity
		neighborhood.population = roundi(float(previous_population) * float(neighborhood.households) / maxf(1.0, float(previous_households)))
	if neighborhood.jobs > neighborhood.job_capacity:
		var previous_jobs: int = neighborhood.jobs
		var next_jobs: int = neighborhood.job_capacity
		var entry: int = mini(next_jobs, roundi(float(neighborhood.jobs_by_skill.get("Entry", 0)) * float(next_jobs) / maxf(1.0, float(previous_jobs))))
		var professional: int = mini(next_jobs - entry, roundi(float(neighborhood.jobs_by_skill.get("Professional", 0)) * float(next_jobs) / maxf(1.0, float(previous_jobs))))
		neighborhood.jobs = next_jobs
		neighborhood.jobs_by_skill = {"Entry": entry, "Skilled": next_jobs - entry - professional, "Professional": professional}
		neighborhood.shopping_attraction = minf(neighborhood.shopping_attraction, float(next_jobs))
	if neighborhood.households == 0 and neighborhood.jobs == 0:
		neighborhood.average_household_wealth = 0.0
	if neighborhood.development_plan != null:
		var plan = neighborhood.development_plan
		plan.target_housing = neighborhood.housing_capacity
		plan.target_jobs = neighborhood.job_capacity


static func _unclaimed_area(region, base: PackedVector2Array, mask: PackedVector2Array) -> float:
	return _unclaimed_area_before(region, base, mask, -1)


static func _unclaimed_area_before(region, base: PackedVector2Array, mask: PackedVector2Array, stop_at: int) -> float:
	var fragments: Array[PackedVector2Array] = Geometry2D.intersect_polygons(base, mask)
	var mask_bounds: Rect2 = _bounds(mask)
	var count: int = region.road_reservations.size() if stop_at < 0 else stop_at
	for index in range(count):
		var reservation: Dictionary = region.road_reservations[index]
		if not mask_bounds.intersects(reservation["bounds"]):
			continue
		for old_mask in reservation["masks"]:
			var remaining: Array[PackedVector2Array] = []
			for fragment in fragments:
				remaining.append_array(Geometry2D.clip_polygons(fragment, old_mask))
			fragments = remaining
	return _net_area(fragments)


static func _area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var total := 0.0
	var origin: Vector2 = polygon[0]
	for index in range(polygon.size()):
		var first: Vector2 = polygon[index] - origin
		var last: Vector2 = polygon[(index + 1) % polygon.size()] - origin
		total += float(first.x) * float(last.y) - float(first.y) * float(last.x)
	return absf(total) * 0.5


static func _net_area(polygons: Array[PackedVector2Array]) -> float:
	var total := 0.0
	for polygon in polygons:
		if polygon.size() < 3:
			continue
		var signed := 0.0
		var origin: Vector2 = polygon[0]
		for index in range(polygon.size()):
			var first: Vector2 = polygon[index] - origin
			var last: Vector2 = polygon[(index + 1) % polygon.size()] - origin
			signed += float(first.x) * float(last.y) - float(first.y) * float(last.x)
		total += signed * 0.5
	return absf(total)


static func _bounds(polygon: PackedVector2Array) -> Rect2:
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		bounds = bounds.expand(point)
	return bounds
