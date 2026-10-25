extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	print("processors: ", OS.get_processor_count())
	var region = RegionGenerator.generate_region(1729)
	var first: Vector2 = region.cities[0]["center_km"]
	var last: Vector2 = region.cities[1]["center_km"]
	print("pair distance: ", first.distance_to(last))
	# Cold planner: first route pays the field fill.
	var cold_started: int = Time.get_ticks_usec()
	var cold = Planner.new(region)
	var cold_alignment: Dictionary = cold.route(first, last, Roads.RURAL)
	print("cold route 1: %d us ok=%s" % [Time.get_ticks_usec() - cold_started, not cold_alignment.is_empty()])
	# Warm: same planner, different pair.
	var pair_two: Vector2 = region.cities[2]["center_km"]
	var warm_started: int = Time.get_ticks_usec()
	var warm_alignment: Dictionary = cold.route(first, pair_two, Roads.RURAL)
	print("warm route 2: %d us ok=%s" % [Time.get_ticks_usec() - warm_started, not warm_alignment.is_empty()])
	# Phase split on a fresh area with a warm planner.
	var third: Vector2 = region.cities[3]["center_km"]
	var search_started: int = Time.get_ticks_usec()
	var traced: Dictionary = cold._search(first + (third - first).normalized() * 0.3, third, Roads.RURAL, Vector2.ZERO)
	var search_us: int = Time.get_ticks_usec() - search_started
	var smooth_started: int = Time.get_ticks_usec()
	var points: PackedVector2Array = cold._smooth(traced["points"], Roads.RURAL, traced["tunnels"])
	var smooth_us: int = Time.get_ticks_usec() - smooth_started
	var profile_started: int = Time.get_ticks_usec()
	var profile: Dictionary = cold._profile(points, Roads.RURAL, traced["tunnels"]) if not points.is_empty() else {}
	var profile_us: int = Time.get_ticks_usec() - profile_started
	print("phases: search=%d us smooth=%d us profile=%d us points=%d" % [search_us, smooth_us, profile_us, points.size()])
	# Cold planner per-route cost on the same pair (fresh instance).
	var fresh_started: int = Time.get_ticks_usec()
	var fresh = Planner.new(region)
	var fresh_alignment: Dictionary = fresh.route(first, last, Roads.RURAL)
	print("fresh-planner route: %d us ok=%s" % [Time.get_ticks_usec() - fresh_started, not fresh_alignment.is_empty()])
	quit(0)
