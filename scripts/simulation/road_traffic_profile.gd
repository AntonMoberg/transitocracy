extends RefCounted

var active_day_key: int = -1
var hourly_volumes: Array[PackedVector2Array] = []
var hourly_link_times: Array[PackedVector2Array] = []
var hourly_pair_times: Array = []
var hourly_peak_ratio: PackedFloat32Array = PackedFloat32Array()


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
	var first: Vector2 = hourly_link_times[clampi(hour, 0, 23)][link_index]
	var second: Vector2
	if hour < 23:
		second = hourly_link_times[hour + 1][link_index]
	elif next_profile != null and not next_profile.hourly_link_times.is_empty() and link_index < next_profile.hourly_link_times[0].size():
		second = next_profile.hourly_link_times[0][link_index]
	else:
		second = hourly_link_times[0][link_index]
	return first.lerp(second, clampf(fraction, 0.0, 1.0))
