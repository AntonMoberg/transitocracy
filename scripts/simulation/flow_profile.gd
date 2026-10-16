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
var is_compact: bool = false
var compact_region
var compact_city_od: Dictionary = {}
var compact_region_od: Dictionary = {}
var compact_origin_daily: Dictionary = {}
var compact_destination_daily: Dictionary = {}
var compact_curves: Dictionary = {}
var build_timings_us: Dictionary = {}
var hourly_od: Array = []
var hourly_work_od: Array = []
var hourly_shopping_od: Array = []
var hourly_social_od: Array = []
var hourly_work_outbound_od: Array = []
var hourly_work_return_od: Array = []
var hourly_shopping_outbound_od: Array = []
var hourly_shopping_return_od: Array = []
var hourly_social_outbound_od: Array = []
var hourly_social_return_od: Array = []
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


func get_interpolated_neighborhood_totals(neighborhood_id: int, hour: int, fraction: float, purpose: String = ALL, next_day_profile = null) -> Vector3:
	if is_compact:
		var current: Vector3 = _compact_neighborhood_totals(neighborhood_id, hour, purpose)
		var next_hour: int = (hour + 1) % 24
		var next_profile = next_day_profile if hour == 23 and next_day_profile != null else self
		var next: Vector3 = next_profile._compact_neighborhood_totals(neighborhood_id, next_hour, purpose)
		return current.lerp(next, clampf(fraction, 0.0, 1.0))
	var current_matrix: Array = get_hour_matrix(hour, purpose)
	var next_matrix: Array = next_day_profile.get_hour_matrix(0, purpose) if hour == 23 and next_day_profile != null else get_hour_matrix((hour + 1) % 24, purpose)
	var current_out := 0.0
	var current_in := 0.0
	var next_out := 0.0
	var next_in := 0.0
	for other_id in range(current_matrix.size()):
		current_out += current_matrix[neighborhood_id][other_id]
		current_in += current_matrix[other_id][neighborhood_id]
		next_out += next_matrix[neighborhood_id][other_id]
		next_in += next_matrix[other_id][neighborhood_id]
	var blend: float = clampf(fraction, 0.0, 1.0)
	return Vector3(lerpf(current_out, next_out, blend), lerpf(current_in, next_in, blend), lerpf(current_matrix[neighborhood_id][neighborhood_id], next_matrix[neighborhood_id][neighborhood_id], blend))


func _compact_neighborhood_totals(neighborhood_id: int, hour: int, purpose: String) -> Vector3:
	if purpose == ALL:
		return _compact_neighborhood_totals(neighborhood_id, hour, WORK) + _compact_neighborhood_totals(neighborhood_id, hour, COMMERCIAL) + _compact_neighborhood_totals(neighborhood_id, hour, SOCIAL)
	var origin: float = compact_origin_daily[purpose][neighborhood_id]
	var destination: float = compact_destination_daily[purpose][neighborhood_id]
	var outward: float = compact_curves[purpose]["out"][hour]
	var returning: float = compact_curves[purpose]["back"][hour]
	return Vector3(origin * outward + destination * returning, destination * outward + origin * returning, 0.0)


func compact_city_hour_matrix(hour: int, purpose: String = ALL) -> Array[PackedFloat32Array]:
	var city_count: int = compact_city_od[WORK].size()
	var matrix: Array[PackedFloat32Array] = []
	for origin_id in range(city_count):
		var row := PackedFloat32Array()
		row.resize(city_count)
		for destination_id in range(city_count):
			if purpose == ALL:
				for category in [WORK, COMMERCIAL, SOCIAL]:
					row[destination_id] += _compact_city_hour_pair(origin_id, destination_id, hour, category)
			else:
				row[destination_id] = _compact_city_hour_pair(origin_id, destination_id, hour, purpose)
		matrix.append(row)
	return matrix


func _compact_city_hour_pair(origin_id: int, destination_id: int, hour: int, purpose: String) -> float:
	var daily: Array = compact_city_od[purpose]
	if hour == 24:
		return (daily[origin_id][destination_id] + daily[destination_id][origin_id]) / 24.0
	var curves: Dictionary = compact_curves[purpose]
	return daily[origin_id][destination_id] * curves["out"][hour] + daily[destination_id][origin_id] * curves["back"][hour]


func _compact_region_hour_pair(origin_id: int, destination_id: int, hour: int, purpose: String) -> float:
	var daily: Array = compact_region_od[purpose]
	if hour == 24:
		return (daily[origin_id][destination_id] + daily[destination_id][origin_id]) / 24.0
	var curves: Dictionary = compact_curves[purpose]
	return daily[origin_id][destination_id] * curves["out"][hour] + daily[destination_id][origin_id] * curves["back"][hour]


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


func get_daily_totals() -> Dictionary:
	var totals := {ALL: 0.0, WORK: 0.0, COMMERCIAL: 0.0, SOCIAL: 0.0}
	for hour in range(hourly_trips.size()):
		totals[ALL] += hourly_trips[hour]
		totals[WORK] += hourly_work_trips[hour]
		totals[COMMERCIAL] += hourly_shopping_trips[hour]
		totals[SOCIAL] += hourly_social_trips[hour]
	return totals


func get_interpolated_hourly_total(hour: int, fraction: float, purpose: String = ALL, next_day_profile = null) -> float:
	var hour_index := clampi(hour, 0, 23)
	var next_total: float = next_day_profile.get_hourly_total(0, purpose) if hour_index == 23 and next_day_profile != null else get_hourly_total((hour_index + 1) % 24, purpose)
	return lerpf(get_hourly_total(hour_index, purpose), next_total, clampf(fraction, 0.0, 1.0))


func get_outgoing(neighborhood_id: int, hour: int, purpose: String = ALL) -> float:
	if is_compact:
		return _compact_neighborhood_totals(neighborhood_id, clampi(hour, 0, 23), purpose).x
	var total := 0.0
	for trips in get_hour_matrix(hour, purpose)[neighborhood_id]:
		total += trips
	return total


func get_incoming(neighborhood_id: int, hour: int, purpose: String = ALL) -> float:
	if is_compact:
		return _compact_neighborhood_totals(neighborhood_id, clampi(hour, 0, 23), purpose).y
	var total := 0.0
	for row in get_hour_matrix(hour, purpose):
		total += row[neighborhood_id]
	return total
