extends RefCounted

const STATE = "State"
const REGION = "Region"
const COUNTY = "County"
const CITY = "City"
const NEIGHBORHOOD = "Neighborhood"
const BOUNDARY_TOLERANCE_KM = 0.0003

var id: int = -1
var kind: String = ""
var name: String = ""
var parent_id: int = -1
var child_ids: Array[int] = []
var neighborhood_ids: Array[int] = []
var center_km: Vector2 = Vector2.ZERO
var bounds_km: Rect2 = Rect2()
var polygon_km: PackedVector2Array = PackedVector2Array()
var generation_weight: float = 1.0

var income_tax_rate: float = 0.0
var property_tax_rate: float = 0.0 # Annual rate on assessed occupied homes.
var sales_tax_rate: float = 0.0
var parking_fee: float = 0.0
var congestion_fee: float = 0.0
var congestion_start_hour: int = 7
var congestion_end_hour: int = 19
var treasury: float = 0.0
var daily_income_revenue: float = 0.0
var daily_property_revenue: float = 0.0
var daily_sales_revenue: float = 0.0
var daily_fee_revenue: float = 0.0
var daily_grant_revenue: float = 0.0
var daily_transfer_expense: float = 0.0
var daily_road_upkeep: float = 0.0
var last_fiscal_change: float = 0.0


func contains_point(point: Vector2) -> bool:
	if not bounds_km.grow(BOUNDARY_TOLERANCE_KM).has_point(point):
		return false
	return polygon_contains_point(point, polygon_km) if not polygon_km.is_empty() else bounds_km.has_point(point)


static func polygon_contains_point(point: Vector2, polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	var inside := false
	for vertex in range(polygon.size()):
		var first: Vector2 = polygon[vertex]
		var second: Vector2 = polygon[(vertex + 1) % polygon.size()]
		var first_x: float = float(first.x) - float(point.x)
		var first_y: float = float(first.y) - float(point.y)
		var second_x: float = float(second.x) - float(point.x)
		var second_y: float = float(second.y) - float(point.y)
		var edge_x: float = second_x - first_x
		var edge_y: float = second_y - first_y
		var length_squared: float = edge_x * edge_x + edge_y * edge_y
		if length_squared > 0.0:
			var projection: float = clampf(-(first_x * edge_x + first_y * edge_y) / length_squared, 0.0, 1.0)
			var nearest_x: float = first_x + projection * edge_x
			var nearest_y: float = first_y + projection * edge_y
			if nearest_x * nearest_x + nearest_y * nearest_y <= BOUNDARY_TOLERANCE_KM * BOUNDARY_TOLERANCE_KM:
				return true
		if (first_y > 0.0) != (second_y > 0.0):
			var crossing_x: float = first_x - first_y * edge_x / edge_y
			if crossing_x > 0.0:
				inside = not inside
	return inside


func daily_revenue() -> float:
	return daily_income_revenue + daily_property_revenue + daily_sales_revenue + daily_fee_revenue + daily_grant_revenue


func daily_net() -> float:
	return daily_revenue() - daily_road_upkeep - daily_transfer_expense


func is_congestion_hour(hour: int) -> bool:
	if congestion_start_hour == congestion_end_hour:
		return false
	if congestion_start_hour < congestion_end_hour:
		return hour >= congestion_start_hour and hour < congestion_end_hour
	return hour >= congestion_start_hour or hour < congestion_end_hour
