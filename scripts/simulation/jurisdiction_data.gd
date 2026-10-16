extends RefCounted

const STATE = "State"
const REGION = "Region"
const COUNTY = "County"
const CITY = "City"
const NEIGHBORHOOD = "Neighborhood"

var id: int = -1
var kind: String = ""
var name: String = ""
var parent_id: int = -1
var child_ids: Array[int] = []
var neighborhood_ids: Array[int] = []
var center_km: Vector2 = Vector2.ZERO
var bounds_km: Rect2 = Rect2()

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
var daily_road_upkeep: float = 0.0
var last_fiscal_change: float = 0.0


func daily_revenue() -> float:
	return daily_income_revenue + daily_property_revenue + daily_sales_revenue + daily_fee_revenue


func is_congestion_hour(hour: int) -> bool:
	if congestion_start_hour == congestion_end_hour:
		return false
	if congestion_start_hour < congestion_end_hour:
		return hour >= congestion_start_hour and hour < congestion_end_hour
	return hour >= congestion_start_hour or hour < congestion_end_hour
