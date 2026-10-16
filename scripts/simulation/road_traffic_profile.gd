extends RefCounted

var active_day_key: int = -1
var link_ids: PackedInt32Array = PackedInt32Array()
var hourly_volumes: Array[PackedVector2Array] = []
var hourly_link_times: Array[PackedVector2Array] = []
var hourly_pair_times: Array = []
var hourly_peak_ratio: PackedFloat32Array = PackedFloat32Array()
var hourly_assignment_gap: PackedFloat32Array = PackedFloat32Array()
var initial_queues: PackedVector2Array = PackedVector2Array()
var quarter_hour_queues: Array[PackedVector2Array] = []
var quarter_hour_served: Array[PackedVector2Array] = []
var quarter_hour_link_times: Array[PackedVector2Array] = []
var hourly_served: Array[PackedVector2Array] = []
var end_queues: PackedVector2Array = PackedVector2Array()


func interpolated_volume(link_index: int, hour: int, fraction: float, next_profile = null) -> Vector2:
	if hourly_volumes.is_empty() or link_index < 0 or link_index >= hourly_volumes[0].size():
		return Vector2.ZERO
	var first: Vector2 = hourly_volumes[clampi(hour, 0, 23)][link_index]
	var second: Vector2
	if hour < 23:
		second = hourly_volumes[hour + 1][link_index]
	elif next_profile != null and not next_profile.hourly_volumes.is_empty() and link_index < next_profile.hourly_volumes[0].size():
		second = next_profile.hourly_volumes[0][link_index]
	else:
		second = hourly_volumes[0][link_index]
	return first.lerp(second, clampf(fraction, 0.0, 1.0))


func interpolated_link_time(link_index: int, hour: int, fraction: float, next_profile = null) -> Vector2:
	if hourly_link_times.is_empty() or link_index < 0 or link_index >= hourly_link_times[0].size():
		return Vector2.ZERO
	if not quarter_hour_link_times.is_empty():
		var quarter_index: int = clampi(hour, 0, 23) * 4 + mini(3, floori(clampf(fraction, 0.0, 0.999999) * 4.0))
		var quarter_fraction: float = fposmod(fraction * 4.0, 1.0)
		var first_quarter: Vector2 = quarter_hour_link_times[quarter_index][link_index]
		var second_quarter: Vector2 = first_quarter
		if quarter_index + 1 < quarter_hour_link_times.size():
			second_quarter = quarter_hour_link_times[quarter_index + 1][link_index]
		elif next_profile != null and not next_profile.quarter_hour_link_times.is_empty() and link_index < next_profile.quarter_hour_link_times[0].size():
			second_quarter = next_profile.quarter_hour_link_times[0][link_index]
		return first_quarter.lerp(second_quarter, quarter_fraction)
	var first: Vector2 = hourly_link_times[clampi(hour, 0, 23)][link_index]
	var second: Vector2
	if hour < 23:
		second = hourly_link_times[hour + 1][link_index]
	elif next_profile != null and not next_profile.hourly_link_times.is_empty() and link_index < next_profile.hourly_link_times[0].size():
		second = next_profile.hourly_link_times[0][link_index]
	else:
		second = hourly_link_times[0][link_index]
	return first.lerp(second, clampf(fraction, 0.0, 1.0))


func interpolated_queue(link_index: int, hour: int, fraction: float) -> Vector2:
	if quarter_hour_queues.is_empty() or link_index < 0 or link_index >= quarter_hour_queues[0].size():
		return Vector2.ZERO
	var quarter_position: float = clampf(fraction, 0.0, 0.999999) * 4.0
	var quarter_index: int = clampi(hour, 0, 23) * 4 + floori(quarter_position)
	var start_queue: Vector2 = initial_queues[link_index] if quarter_index == 0 else quarter_hour_queues[quarter_index - 1][link_index]
	return start_queue.lerp(quarter_hour_queues[quarter_index][link_index], quarter_position - floorf(quarter_position))


func interpolated_served_rate(link_index: int, hour: int, fraction: float, next_profile = null) -> Vector2:
	if quarter_hour_served.is_empty() or link_index < 0 or link_index >= quarter_hour_served[0].size():
		return Vector2.ZERO
	var quarter_position: float = clampf(fraction, 0.0, 0.999999) * 4.0
	var quarter_index: int = clampi(hour, 0, 23) * 4 + floori(quarter_position)
	var first: Vector2 = quarter_hour_served[quarter_index][link_index]
	var second: Vector2 = first
	if quarter_index + 1 < quarter_hour_served.size():
		second = quarter_hour_served[quarter_index + 1][link_index]
	elif next_profile != null and not next_profile.quarter_hour_served.is_empty() and link_index < next_profile.quarter_hour_served[0].size():
		second = next_profile.quarter_hour_served[0][link_index]
	return first.lerp(second, quarter_position - floorf(quarter_position)) * 4.0
