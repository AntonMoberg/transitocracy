extends RefCounted
## Shared cartographic policy for geometry, shaders and picking.
enum RoadStyle { LOCAL, COLLECTOR, RURAL, ARTERIAL, HIGHWAY }
const ROAD_COLORS = [Color("e3e7eb"), Color("ced6de"), Color("b5c1ce"), Color("aebdcd"), Color("8fa5bd")]
const LAND = Color("d3f4df")
const WOODS = Color("bcebd2")
const OPEN = Color("f2efe3")
const ROCK = Color("e8e1ce")
const URBAN = Color("f3f2f1")
const PARK = Color("b5e7cc")
const WATER = Color("94d9e8")

static func road_style(link) -> int:
	match link.road_class:
		"Highway": return RoadStyle.HIGHWAY
		"Arterial": return RoadStyle.ARTERIAL
		"Collector": return RoadStyle.RURAL if link.managed_neighborhood_id < 0 else RoadStyle.COLLECTOR
	return RoadStyle.LOCAL

static func road_range(style: int, major: bool = false) -> Vector2:
	if major or style == RoadStyle.HIGHWAY: return Vector2.ZERO
	if style == RoadStyle.LOCAL: return Vector2(110.0, 121.0)
	if style == RoadStyle.COLLECTOR: return Vector2(55.0, 60.5)
	return Vector2(11.0, 22.0)

static func river_range(width_km: float) -> Vector2:
	if width_km >= 0.24: return Vector2.ZERO
	if width_km >= 0.16: return Vector2(11.0, 13.0)
	if width_km >= 0.06: return Vector2(55.0, 60.5)
	return Vector2(110.0, 121.0)

static func visibility(ppk: float, limits: Vector2) -> float:
	return 1.0 if limits.y <= 0.0 else smoothstep(limits.x, limits.y, ppk)

static func road_visible(link, ppk: float) -> bool:
	return visibility(ppk, road_range(road_style(link), link.map_major)) > 0.05

static func land_color(_elevation: float, gradient: Vector2, cover: Vector3 = Vector3.ZERO, _detail: float = 0.0) -> Color:
	var color: Color = LAND.lerp(OPEN, smoothstep(0.05, 0.75, cover.y))
	color = color.lerp(WOODS, smoothstep(0.08, 0.8, cover.x))
	color = color.lerp(ROCK, smoothstep(0.12, 0.8, cover.z))
	var relief: float = smoothstep(0.012, 0.09, gradient.length())
	var shade: float = clampf(-(gradient.x + gradient.y) * 0.6, -0.06, 0.06) * relief
	return Color(color.r * (1.0 + shade), color.g * (1.0 + shade), color.b * (1.0 + shade), 1.0)

static func landscape_color(terrain, point: Vector2) -> Color:
	var sample := landscape_sample(terrain, point)
	return land_color(0.0, sample.gradient, sample.cover)

static func landscape_sample(terrain, point: Vector2) -> Dictionary:
	# Sample the broad height field, not expensive road/water collision queries.
	# The 2 km derivative remains identical at every tile LOD.
	var elevation: float = _height(terrain, point)
	var gradient := Vector2(_height(terrain, point + Vector2(2,0)) - _height(terrain, point - Vector2(2,0)), _height(terrain, point + Vector2(0,2)) - _height(terrain, point - Vector2(0,2))) / 4000.0
	return {"elevation": elevation, "gradient": gradient, "cover": terrain.land_cover_at(point, elevation, gradient) if terrain.has_method("land_cover_at") else Vector3.ZERO}

static func landscape_field(terrain, point: Vector2) -> Color:
	var sample := landscape_sample(terrain, point)
	var gradient: Vector2 = sample.gradient
	var cover: Vector3 = sample.cover
	return encode_landscape_field(gradient, cover)

static func encode_landscape_field(gradient: Vector2, cover: Vector3) -> Color:
	var relief: float = smoothstep(0.012, 0.09, gradient.length())
	var shade: float = clampf(-(gradient.x + gradient.y) * 0.6, -0.06, 0.06) * relief
	return Color(cover.x, cover.y, cover.z, (shade + 0.06) / 0.12)

static func _height(terrain, point: Vector2) -> float:
	if not terrain.has_method("elevation_at"):
		return terrain.visual_elevation_at(point)
	var grid: Vector2 = (point - terrain.bounds.position) / terrain.GRID_KM
	var x: int = clampi(floori(grid.x), 0, terrain.width - 2)
	var y: int = clampi(floori(grid.y), 0, terrain.height - 2)
	var fx: float = clampf(grid.x - x, 0.0, 1.0)
	var fy: float = clampf(grid.y - y, 0.0, 1.0)
	var first: int = y * terrain.width + x
	var second: int = first + terrain.width
	return lerpf(lerpf(terrain.elevations[first],terrain.elevations[first+1],fx),lerpf(terrain.elevations[second],terrain.elevations[second+1],fx),fy)
