extends SceneTree
const Planner = preload("res://scripts/simulation/terrain_route_planner.gd")
const Route = preload("res://scripts/simulation/road_route_builder.gd")
class Area:
	var bounds_km := Rect2(0,0,240,120)
	func contains_point(p: Vector2) -> bool: return bounds_km.has_point(p)
class Terrain:
	var barrier := false
	func elevation_at(p: Vector2) -> float:
		return 100.0 + 1400.0 * exp(-pow((p.x-120.0)/12.0,2)) * (1.0-exp(-pow((p.y-24.0)/16.0,2)))
	func slope_at(p: Vector2) -> float:
		return Vector2(elevation_at(p+Vector2(.1,0))-elevation_at(p-Vector2(.1,0)),elevation_at(p+Vector2(0,.1))-elevation_at(p-Vector2(0,.1))).length()/200.0
	func water_at(p: Vector2) -> bool: return barrier and p.x > 108.0 and p.x < 132.0
class NarrowRidge:
	func elevation_at(p: Vector2) -> float: return 100.0 + 200.0 * exp(-pow((p.x-120.0)/0.5,2))
	func slope_at(_p: Vector2) -> float: return 0.0
	func water_at(_p: Vector2) -> bool: return false
class Region:
	var jurisdictions := [Area.new()]
	var terrain = Terrain.new()
var errors: Array[String] = []
func _initialize() -> void:
	var region := Region.new()
	var macro := Planner.new(region,8.0)
	var trace: Dictionary = macro.plan_corridor(Vector2(16,80),Vector2(224,80))
	_check(not trace.is_empty(), "surface pass must be discoverable")
	if not trace.is_empty():
		var crosses_pass := false
		for p in trace.points:
			if absf(p.x-120)<9 and p.y < 42: crosses_pass = true
		_check(crosses_pass,"corridor must seek the saddle instead of crossing the ridge")
		var detail := Planner.new(region,4.0)
		var alignment := detail.align_corridor(trace.points)
		_check(not alignment.is_empty(),"macro corridor must refine into a valid highway")
		if not alignment.is_empty():
			_check(Route.significant_curve_radius(alignment.points)>=2.0,"pass curves must retain highway radius")
			for i in range(1,alignment.points.size()):
				var grade: float = absf(alignment.elevations_m[i]-alignment.elevations_m[i-1])/maxf(.001,alignment.points[i].distance_to(alignment.points[i-1])*1000.0)
				_check(grade<=.0601,"surface pass exceeds highway grade")
			for span in alignment.terrain_spans: _check(span.kind!="Tunnel","a feasible surface pass must not tunnel")
		var repeat: Dictionary = macro.plan_corridor(Vector2(16,80),Vector2(224,80))
		_check(repeat.points == trace.points,"corridor selection must be deterministic")
	region.terrain.barrier = true
	var blocked := Planner.new(region,8.0)
	_check(blocked.plan_corridor(Vector2(16,80),Vector2(224,80)).is_empty(),"impossible water barrier must not gain a straight fallback")
	# Reusing a planner across classes must not reuse a permissive grade cost.
	var reused := Planner.new(Region.new(),4.0)
	reused.route(Vector2(80,80),Vector2(160,80),"Collector",Vector2.ZERO,Vector2.ZERO,false)
	var highway: Dictionary = reused.route(Vector2(80,80),Vector2(160,80),"Highway",Vector2.ZERO,Vector2.ZERO,false)
	var fresh := Planner.new(reused.region,4.0)
	_check(highway == fresh.route(Vector2(80,80),Vector2(160,80),"Highway",Vector2.ZERO,Vector2.ZERO,false),"route result must not depend on previous road class")
	var unbounded:=Planner.new(reused.region,4.0)
	unbounded.use_tunnel_cost_bound=false
	_check(highway==unbounded.route(Vector2(80,80),Vector2(160,80),"Highway",Vector2.ZERO,Vector2.ZERO,false),"cost bound must preserve mountain route results")
	var tunnel_region := Region.new()
	tunnel_region.terrain = NarrowRidge.new()
	var tunneling := Planner.new(tunnel_region,1.0)
	tunneling.generated_highway = true
	tunneling.tunnel_limit_km = 3.0
	_check(tunneling._tunnel_cost(Vector2i(119,60),Vector2i(121,60),.04) < INF,"short tunnel with valid cover must be feasible")
	var tunnel_fresh:=Planner.new(tunnel_region,1.0)
	for grade_limit in [.01,.04,.06]:
		_check(tunneling._tunnel_cost(Vector2i(119,60),Vector2i(121,60),grade_limit)==tunnel_fresh._tunnel_cost(Vector2i(119,60),Vector2i(121,60),grade_limit),"retained tunnel measurements must preserve grade decisions")
	var line := PackedVector2Array()
	for x in range(32,449): line.append(Vector2(x*.5,60))
	var short_tunnel := tunneling._profile(line,"Highway",[{"from":Vector2(119,60),"to":Vector2(121,60)}])
	var profile_only:=Planner.new(tunnel_region,1.0)
	_check(profile_only.cell_filled.is_empty() and profile_only.edge_costs.is_empty(),"unused planners must not allocate terrain search grids")
	profile_only._profile(line,"Collector",[])
	_check(profile_only.cell_filled.is_empty() and profile_only.edge_costs.is_empty(),"geometry validation must not allocate terrain search grids")
	_check(not short_tunnel.is_empty(),"exceptional short tunnel must pass final profile validation")
	_check(tunneling._profile(line,"Highway",[{"from":Vector2(112,60),"to":Vector2(128,60)}]).is_empty(),"long tunnel must fail final profile validation")
	print("Terrain corridors: ", "PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message): errors.append(message)
