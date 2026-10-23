extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadTerrain = preload("res://scripts/simulation/road_terrain.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const RoadRouteBuilder = preload("res://scripts/simulation/road_route_builder.gd")
const RoadLand = preload("res://scripts/simulation/road_land.gd")
const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const TerrainGenerator = preload("res://scripts/simulation/terrain_generator.gd")
const StateGeography = preload("res://scripts/simulation/state_geography.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var small = RegionGenerator.generate_region(5424046)
	var large = RegionGenerator.generate_large_region(5424046, 256)
	var largest = RegionGenerator.generate_large_region(5424046, 768)
	var terrain = small.terrain
	_check(terrain != null and large.terrain != null and largest.terrain != null, "all city detail levels need terrain")
	_check(terrain.elevations == large.terrain.elevations and terrain.elevations == largest.terrain.elevations, "terrain must depend on seed rather than city count")
	_check(terrain.lakes.size() >= 3 and not terrain.rivers.is_empty(), "the state needs lakes and connected rivers")
	for lake_id in range(4):
		_check(terrain.lakes[lake_id]["radius"].length() > 9.0, "the state needs several larger lakes")
	var outlet_counts := {"sea": 0, "lake": 0, "confluence": 0, "other": 0}
	var max_uphill := 0.0
	var longest_river_km := 0.0
	for river in terrain.rivers:
		var outlet: String = river.get("outlet", "other")
		outlet_counts[outlet] = int(outlet_counts.get(outlet, 0)) + 1
		var line: PackedVector2Array = river["points"]
		var levels: PackedFloat32Array = river["levels"]
		var length_km := 0.0
		_check(levels.size() == line.size(), "river channels need a surface level at every line point")
		for index in range(1, line.size()):
			length_km += line[index - 1].distance_to(line[index])
			var rise: float = terrain.elevation_at(line[index]) - terrain.elevation_at(line[index - 1])
			max_uphill = maxf(max_uphill, rise)
			_check(levels[index] <= levels[index - 1], "river water surface must descend downstream")
		if outlet == "sea":
			_check(line[-1].distance_to(TerrainGenerator._closest_coast_point(line[-1], terrain.coastline)) < 0.01, "sea-bound rivers must reach the coastline")
		elif outlet == "lake":
			_check(_on_lake_shore(terrain, line[-1]), "inland rivers must reach a lake shore")
		elif outlet == "confluence":
			_check(terrain.water_at(line[-1]), "tributaries must join a downstream river")
		longest_river_km = maxf(longest_river_km, length_km)
	_check(int(outlet_counts["sea"]) > 0 and int(outlet_counts["lake"]) > 0 and int(outlet_counts["other"]) == 0, "rivers need connected sea and lake outlets")
	_check(longest_river_km > 100.0, "at least one river should run across a substantial part of the state")
	_check(max_uphill < 1.0, "drawn river channels must follow downhill terrain")
	print("River outlets=%s longest=%.1f km max uphill=%.1f m" % [outlet_counts, longest_river_km, max_uphill])
	for seed_value in [7113721, 8752568]:
		var shape: Dictionary = StateGeography._generate_outline(seed_value)
		var alternate = TerrainGenerator.generate(seed_value, shape["polygon"], StateGeography._bounds(shape["polygon"]), shape["coastline"])
		var reaches_sea := false
		var reaches_lake := false
		for river in alternate.rivers:
			var route: PackedVector2Array = river["points"]
			var surface: PackedFloat32Array = river["levels"]
			_check(route.size() == surface.size(), "river geometry and water surface must match across seeds")
			for index in range(1, surface.size()):
				_check(surface[index] <= surface[index - 1], "river water must descend across seeds")
			if river["outlet"] == "sea":
				reaches_sea = true
				_check(route[-1].distance_to(TerrainGenerator._closest_coast_point(route[-1], alternate.coastline)) < 0.01, "sea-bound rivers must end on the coast across seeds")
			elif river["outlet"] == "lake":
				reaches_lake = true
				_check(_on_lake_shore(alternate, route[-1]), "lake-bound rivers must end on shore across seeds")
		_check(reaches_sea and reaches_lake, "each sampled state needs rivers draining to sea and lakes")
	var plains := 0
	var hills := 0
	var steep := 0
	var steep_point := Vector2.INF
	for y in range(2, terrain.height - 2, 3):
		for x in range(2, terrain.width - 2, 3):
			var point: Vector2 = terrain.bounds.position + Vector2(x, y) * terrain.GRID_KM
			if not small.jurisdictions[0].contains_point(point) or terrain.water_at(point):
				continue
			var slope: float = terrain.slope_at(point)
			plains += 1 if slope < 0.05 else 0
			hills += 1 if slope >= 0.10 and slope <= 0.25 else 0
			steep += 1 if slope > 0.25 else 0
			if slope > 0.25 and not steep_point.is_finite():
				steep_point = point
	_check(plains > 0 and hills > 0 and steep > 0, "a map needs buildable plains, hills, and prohibited steep land")
	print("Terrain samples: plains=%d hills=%d steep=%d" % [plains, hills, steep])
	if steep_point.is_finite():
		var steep_footprint := PackedVector2Array([steep_point + Vector2(-0.01, -0.01), steep_point + Vector2(0.01, -0.01), steep_point + Vector2(0.01, 0.01), steep_point + Vector2(-0.01, 0.01)])
		_check(not terrain.footprint_buildable(steep_footprint), "ordinary buildings cannot occupy very steep land")
		var axis: Vector2 = terrain.gradient_at(steep_point).normalized()
		var tunnel_line := PackedVector2Array([steep_point - axis * 0.45, steep_point + axis * 0.45])
		var tunnel: Dictionary = RoadTerrain.preview(small, tunnel_line, "Arterial")
		_check(tunnel["ok"] and float(tunnel.get("tunnel_km", 0.0)) > 0.0, "a steep road route needs a tunnel section")
		if tunnel["ok"] and float(tunnel["tunnel_km"]) > 0.0:
			var tunnel_land: Dictionary = RoadLand.preview(small, tunnel_line, "Arterial", tunnel["surface_paths"])
			var surface_land: Dictionary = RoadLand.preview(small, tunnel_line, "Arterial")
			_check(float(tunnel_land["land_ha"]) < float(surface_land["land_ha"]), "tunnels should acquire only portal land")
	var crossed := false
	for lake in terrain.lakes:
		var center: Vector2 = lake["center"]
		var radius: Vector2 = lake["radius"]
		_check(terrain.water_at(center), "lake centers must be water")
		var footprint := PackedVector2Array([center + Vector2(-0.02, -0.02), center + Vector2(0.02, -0.02), center + Vector2(0.02, 0.02), center + Vector2(-0.02, 0.02)])
		_check(not terrain.footprint_buildable(footprint), "buildings cannot occupy lakes")
		var lake_block := {"park": false, "polygon": PackedVector2Array([center + Vector2(-0.06, -0.05), center + Vector2(0.06, -0.05), center + Vector2(0.06, 0.05), center + Vector2(-0.06, 0.05)]), "seed": 87}
		_check(ParcelGeometry.buildings(lake_block, "Residential", 1, Character.FINE_GRAIN, terrain).is_empty(), "parcel generation must omit lake buildings")
		var from_point: Vector2 = center - Vector2(radius.x + 1.0, 0.0)
		var to_point: Vector2 = center + Vector2(radius.x + 1.0, 0.0)
		if not small.jurisdictions[0].contains_point(from_point) or not small.jurisdictions[0].contains_point(to_point) or terrain.water_at(from_point) or terrain.water_at(to_point):
			continue
		var impact: Dictionary = RoadTerrain.preview(small, PackedVector2Array([from_point, to_point]), "Arterial")
		if impact["ok"] and float(impact["bridge_km"]) > 0.0 and int(impact["cost"]) > 0:
			var bridge_land: Dictionary = RoadLand.preview(small, PackedVector2Array([from_point, to_point]), "Arterial", impact["surface_paths"])
			_check(float(bridge_land["land_ha"]) < from_point.distance_to(to_point) * RoadLand.ARTERIAL_WIDTH_KM * 90.0, "water beneath a bridge must not be billed as acquired land")
			var first: Dictionary = RoadPlanner.add_junction(small, from_point)
			var last: Dictionary = RoadPlanner.add_junction(small, to_point)
			if first["ok"] and last["ok"]:
				var preview: Dictionary = RoadPlanner.link_preview(small, first["node_id"], last["node_id"], "Arterial", PackedVector2Array(), 0, RoadRouteBuilder.STRAIGHT)
				_check(preview["ok"] and float(preview.get("terrain_impact", {}).get("bridge_km", 0.0)) > 0.0, "the road tool must include the bridge in its preview")
				if preview["ok"]:
					_check(int(preview["cost"]) >= int(preview["construction_cost"]) + int(impact["cost"]), "bridge construction must be included in the funded cost")
					small.dev_mode = true
					var funded: Dictionary = RoadPlanner.commit(small, preview, 0)
					_check(funded["ok"], "a valid bridge preview must fund a road project")
					if funded["ok"]:
						var project = funded["project"]
						_check(not project.terrain_spans.is_empty(), "bridge spans must persist through construction")
						RoadPlanner.advance_day(small, project.open_day_key)
						_check(not small.road_links.is_empty() and not small.road_links[-1].terrain_spans.is_empty(), "completed bridges must retain their structure spans")
			crossed = true
	_check(crossed, "road previews must identify and price a lake bridge")
	var river_crossed := false
	for river in terrain.rivers:
		var line: PackedVector2Array = river["points"]
		for segment in range(1, line.size()):
			var middle: Vector2 = (line[segment - 1] + line[segment]) * 0.5
			var normal: Vector2 = (line[segment] - line[segment - 1]).normalized().orthogonal()
			var first: Vector2 = middle - normal * 0.22
			var last: Vector2 = middle + normal * 0.22
			if not small.jurisdictions[0].contains_point(first) or not small.jurisdictions[0].contains_point(last) or terrain.water_at(first) or terrain.water_at(last):
				continue
			var crossing: Dictionary = RoadTerrain.preview(small, PackedVector2Array([first, last]), "Arterial")
			if crossing.get("ok", false) and float(crossing["bridge_km"]) > 0.0:
				river_crossed = true
				break
		if river_crossed:
			break
	_check(river_crossed, "road previews must identify a bridge across a generated river")
	if failures == 0:
		print("Terrain generation, slope limits, and bridge preview passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)


func _on_lake_shore(terrain, point: Vector2) -> bool:
	for lake in terrain._near_lakes(point):
		var polygon: PackedVector2Array = lake["polygon"]
		for edge in range(polygon.size()):
			if point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[edge], polygon[(edge + 1) % polygon.size()])) < 0.01:
				return true
	return false
