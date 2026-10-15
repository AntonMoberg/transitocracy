extends RefCounted

const ALL = "All"
const WORK = "Work"
const COMMERCIAL = "Commercial"
const SOCIAL = "Social"

# Daily OD matrices count one-way visits. Hourly matrices include outbound and return trips.
var daily_commuters: float = 0.0
var daily_work_od: Array[PackedFloat32Array] = []
var weekday_shopping_od: Array[PackedFloat32Array] = []
var weekend_shopping_od: Array[PackedFloat32Array] = []
var weekday_social_od: Array[PackedFloat32Array] = []
var weekend_social_od: Array[PackedFloat32Array] = []
var weekday_shopping_visits: float = 0.0
var weekend_shopping_visits: float = 0.0
var weekday_social_visits: float = 0.0
var weekend_social_visits: float = 0.0

var active_day_key: int = -1
var active_weekend: bool = false
var hourly_od: Array = []
var hourly_work_od: Array = []
var hourly_shopping_od: Array = []
var hourly_social_od: Array = []
var hourly_trips: PackedFloat32Array = PackedFloat32Array()
var hourly_work_trips: PackedFloat32Array = PackedFloat32Array()
var hourly_shopping_trips: PackedFloat32Array = PackedFloat32Array()
var hourly_social_trips: PackedFloat32Array = PackedFloat32Array()
var peak_net_trips_by_purpose: Dictionary = {ALL: 1.0, WORK: 1.0, COMMERCIAL: 1.0, SOCIAL: 1.0}


func get_hour_matrix(hour: int, purpose: String = ALL) -> Array:
	var hour_index := clampi(hour, 0, 23)
	match purpose:
		WORK:
			return hourly_work_od[hour_index]
		COMMERCIAL:
			return hourly_shopping_od[hour_index]
		SOCIAL:
			return hourly_social_od[hour_index]
		_:
			return hourly_od[hour_index]


func get_interpolated_hour_matrix(hour: int, fraction: float, purpose: String = ALL, next_day_profile = null) -> Array:
	var hour_index := clampi(hour, 0, 23)
	var blend := clampf(fraction, 0.0, 1.0)
	var current_matrix: Array = get_hour_matrix(hour_index, purpose)
	if blend <= 0.0:
		return current_matrix
	var next_matrix: Array = next_day_profile.get_hour_matrix(0, purpose) if hour_index == 23 and next_day_profile != null else get_hour_matrix((hour_index + 1) % 24, purpose)
	if blend >= 1.0:
		return next_matrix
	var blended_matrix: Array[PackedFloat32Array] = []
	for origin_id in range(current_matrix.size()):
		var row := PackedFloat32Array()
		row.resize(current_matrix[origin_id].size())
		for destination_id in range(row.size()):
			row[destination_id] = lerpf(current_matrix[origin_id][destination_id], next_matrix[origin_id][destination_id], blend)
		blended_matrix.append(row)
	return blended_matrix


func get_hourly_total(hour: int, purpose: String = ALL) -> float:
	var hour_index := clampi(hour, 0, 23)
	match purpose:
		WORK:
			return hourly_work_trips[hour_index]
		COMMERCIAL:
			return hourly_shopping_trips[hour_index]
		SOCIAL:
			return hourly_social_trips[hour_index]
		_:
			return hourly_trips[hour_index]


func get_interpolated_hourly_total(hour: int, fraction: float, purpose: String = ALL, next_day_profile = null) -> float:
	var hour_index := clampi(hour, 0, 23)
	var next_total: float = next_day_profile.get_hourly_total(0, purpose) if hour_index == 23 and next_day_profile != null else get_hourly_total((hour_index + 1) % 24, purpose)
	return lerpf(get_hourly_total(hour_index, purpose), next_total, clampf(fraction, 0.0, 1.0))


func get_outgoing(neighborhood_id: int, hour: int, purpose: String = ALL) -> float:
	var total := 0.0
	for trips in get_hour_matrix(hour, purpose)[neighborhood_id]:
		total += trips
	return total


func get_incoming(neighborhood_id: int, hour: int, purpose: String = ALL) -> float:
	var total := 0.0
	for row in get_hour_matrix(hour, purpose):
		total += row[neighborhood_id]
	return total
