extends SceneTree
const Style = preload("res://scripts/ui/map_style.gd")
const Geometry = preload("res://scripts/ui/map_geometry.gd")
const Region = preload("res://scripts/simulation/region_data.gd")
const Snapshot = preload("res://scripts/simulation/region_snapshot.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
var errors: Array[String] = []
func _initialize() -> void:
	var local = Roads.new()
	local.road_class = Roads.LOCAL
	var collector = Roads.new()
	collector.road_class = Roads.COLLECTOR
	collector.managed_neighborhood_id = 0
	var rural = Roads.new()
	rural.road_class = Roads.COLLECTOR
	_check(not Style.road_visible(local, 80) and Style.road_visible(local, 150), "local visibility must match 500 m scale")
	_check(not Style.road_visible(collector, 40) and Style.road_visible(collector, 80), "urban collectors must disappear at 2 km")
	_check(Style.road_visible(rural, 40) and not Style.road_visible(rural, 8), "rural is distinct from urban collector")
	rural.map_major = true
	_check(Style.road_visible(rural, 1), "major routes must survive state overview")
	var region := Region.new()
	rural.trunk_route_id = 17
	region.road_links.append(rural)
	var snapshot = Snapshot.copy_region(region)
	_check(snapshot.road_links[0].map_major and snapshot.road_links[0].trunk_route_id == 17,"worker snapshot must retain route importance and identity")
	snapshot.road_links[0].map_major = false
	_check(rural.map_major,"snapshot style edits must not mutate live roads")
	for width in [0.035, 0.08, 0.18, 0.28]:
		var previous := 0.0
		for ppk in [1.0, 8.0, 16.0, 40.0, 80.0, 150.0]:
			var alpha: float = Style.visibility(ppk, Style.river_range(width))
			_check(alpha >= previous, "rivers must refine monotonically")
			previous = alpha
	var neutral := Style.land_color(50, Vector2.ZERO)
	_check(neutral.is_equal_approx(Style.land_color(2000, Vector2.ZERO)), "elevation alone must not create color bands")
	_check(Style.land_color(50,Vector2.ZERO,Vector3(0,1,0)).is_equal_approx(Style.OPEN), "dry/open land uses cream")
	_check(Style.land_color(1500,Vector2.ZERO,Vector3(0,0,1)).is_equal_approx(Style.ROCK), "exposed rock uses sand")
	for gradient in [Vector2(.3,.1),Vector2(-.3,-.1)]:
		var shaded := Style.land_color(500,gradient)
		_check(absf(shaded.r / neutral.r - 1.0) <= .0601, "Map relief exceeds six percent")
	var source := Geometry.index_source({"bounds":Rect2(0,0,4,4),"epoch":1,"features":[{"kind":"line","layer":"roads","points":PackedVector2Array([Vector2(0,2),Vector2(4,2)]),"style":Style.RoadStyle.LOCAL,"fade":Style.road_range(Style.RoadStyle.LOCAL),"min_ppk":110.0,"local":true,"slot":0}]})
	var packet := Geometry.build(source,Vector3i.ZERO,"roads")
	_check(not packet.parts.is_empty(), "upcoming streets must exist before their fade threshold")
	for part in packet.parts:
		_check(part.styles.size() == part.vertices.size()*4, "GPU cartographic metadata must survive bounded uploads")
		_check(part.styles[2] == 110 and part.styles[3] == 121, "shader and picking must share thresholds")
	print("Cartography policy: ", "PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
