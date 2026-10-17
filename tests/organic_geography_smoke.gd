extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")
const JurisdictionData = preload("res://scripts/simulation/jurisdiction_data.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const UiFixture = preload("res://tests/ui_fixture.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for city_count in [32, 256, 768]:
		for seed_value in [1729, 42]:
			var region = RegionGenerator.generate_region(seed_value) if city_count == 32 else RegionGenerator.generate_large_region(seed_value, city_count)
			var county_counts: Dictionary = {}
			var city_counts: Dictionary = {}
			var neighborhood_counts: Dictionary = {}
			var minimum_area := INF
			var maximum_area := 0.0
			_check(region.jurisdictions[0].polygon_km.size() > 120, "coastlines must have finer coves and headlands")
			for region_id in region.region_ids:
				var area = region.jurisdictions[region_id]
				county_counts[area.child_ids.size()] = true
				var area_km2: float = StateGeography._area(area.polygon_km)
				minimum_area = minf(minimum_area, area_km2)
				maximum_area = maxf(maximum_area, area_km2)
			_check(county_counts.size() > 1 and maximum_area / minimum_area > 1.8, "regions must vary in both area and county count")
			for county_id in region.county_ids:
				var county = region.jurisdictions[county_id]
				city_counts[county.child_ids.size()] = true
			_check(city_counts.size() > 1, "counties must have different city counts")
			var shape_counts: Dictionary = {}
			for area in region.jurisdictions:
				if area.kind == "State":
					continue
				if not shape_counts.has(area.kind):
					shape_counts[area.kind] = Vector2i.ZERO
				shape_counts[area.kind].x += 1
				if area.polygon_km.size() > 5:
					shape_counts[area.kind].y += 1
				_check(not Geometry2D.triangulate_polygon(area.polygon_km).is_empty(), "organic boundaries must remain simple renderable polygons")
			for kind in shape_counts:
				if kind == "Neighborhood":
					continue
				_check(shape_counts[kind].y > shape_counts[kind].x * 0.6, "%s boundaries must have varied bends instead of four-sided boxes" % kind)
			for parent in region.jurisdictions:
				if not parent.child_ids.is_empty():
					_check_partition(region, parent)
			for city in region.cities:
				neighborhood_counts[city["neighborhood_ids"].size()] = true
				for neighborhood_id in city["neighborhood_ids"]:
					var neighborhood = region.neighborhoods[neighborhood_id]
					var district = region.jurisdictions[neighborhood.jurisdiction_id]
					_check(district.polygon_km.size() >= 3 and district.contains_point(neighborhood.position_km), "neighborhoods need selectable polygon boundaries")
					_check(region.jurisdiction_at_point(neighborhood.position_km) == district.id, "neighborhood ownership must follow parcel borders")
					_check(is_equal_approx(neighborhood.land_area_ha, StateGeography._area(district.polygon_km) * 100.0), "neighborhood land area must include its entire boundary")
					_check(neighborhood.developable_area_ha > 0.0 and neighborhood.developable_area_ha <= minf(130.0, neighborhood.land_area_ha), "larger administrative boundaries must not inflate developable housing and job capacity")
			_check(neighborhood_counts.size() >= 2, "anchor and dormant cities must have different neighborhood counts")
			if region.is_large_scale:
				var snapshot = DayCycleCalculator.copy_region(region)
				var district_id: int = region.neighborhoods[0].jurisdiction_id
				_check(snapshot.jurisdictions[district_id].polygon_km == region.jurisdictions[district_id].polygon_km, "background snapshots must preserve neighborhood boundaries")
				_check(snapshot.neighborhoods[0].developable_area_ha == region.neighborhoods[0].developable_area_ha, "background snapshots must preserve developable land")
	var main = await UiFixture.attach_small(self)
	main.playing = false
	var map = main.map_view
	var city: Dictionary = main.region.cities[0]
	var city_area = main.region.jurisdictions[city["jurisdiction_id"]]
	map.zoom = minf(64.0, 0.8 * minf(map.size.x / city_area.bounds_km.size.x, map.size.y / city_area.bounds_km.size.y) / map._map_scale())
	map.pan = -(city["center_km"] - map._world_center()) * map._map_scale() * map.zoom
	map.queue_redraw()
	await process_frame
	await process_frame
	_check(map.last_drawn_neighborhood_borders > 0, "neighborhood borders must be drawn when inspecting a city")
	var neighborhood = main.region.neighborhoods[0]
	var district = main.region.jurisdictions[neighborhood.jurisdiction_id]
	var parcel_position: Vector2 = district.center_km
	_check(map._jurisdiction_at(map._world_to_screen(parcel_position)) == district.id, "clicking inside a visible neighborhood must select that polygon")
	var county = main.region.jurisdictions[main.region.county_ids[0]]
	var ownership = main.region.jurisdictions[main.region.jurisdiction_at_point(county.center_km)]
	_check(ownership.kind in ["City", "Neighborhood"] and ownership.id != county.id, "empty county land must still belong to a city")
	if failures == 0:
		print("Uneven hierarchies, organic boundaries, full administrative tiling, and polygon selection passed.")
	quit(1 if failures > 0 else 0)


func _check_partition(region, parent) -> void:
	var parent_area: float = StateGeography._area(parent.polygon_km)
	var perimeter := 0.0
	for vertex in range(parent.polygon_km.size()):
		perimeter += parent.polygon_km[vertex].distance_to(parent.polygon_km[(vertex + 1) % parent.polygon_km.size()])
	var tolerance: float = maxf(0.0001, perimeter * JurisdictionData.BOUNDARY_TOLERANCE_KM)
	var covered_area := 0.0
	for local_id in range(parent.child_ids.size()):
		var child = region.jurisdictions[parent.child_ids[local_id]]
		covered_area += StateGeography._area(child.polygon_km)
		for vertex in child.polygon_km:
			_check(parent.contains_point(vertex), "child boundaries must stay inside their parent")
		for other_id in range(local_id):
			var other = region.jurisdictions[parent.child_ids[other_id]]
			if not child.bounds_km.intersects(other.bounds_km):
				continue
			var overlap := 0.0
			for intersection in Geometry2D.intersect_polygons(child.polygon_km, other.polygon_km):
				overlap += StateGeography._area(intersection)
			_check(overlap < tolerance, "sibling polygons must not overlap")
	if parent.kind == "City":
		_check(covered_area < parent_area and covered_area > 0.0, "small neighborhoods must leave undeveloped city land")
	else:
		_check(absf(covered_area - parent_area) < tolerance, "%s children must cover their parent without gaps" % parent.kind)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
