extends RefCounted


static func completed_hour(state, hour: int) -> Dictionary:
	if state == null or hour < 0 or hour >= 24:
		return {}
	var profile = state.profile
	if profile == null or hour * 4 + 3 >= profile.recorded_bin:
		return {}
	return {
		"day_key": state.day_key,
		"link_ids": profile.link_ids,
		"by_link_id": _indices(profile.link_ids),
		"demand": profile.hourly_volumes[hour],
		"served": profile.hourly_served[hour],
		"queue": profile.quarter_hour_queues[hour * 4 + 3],
		"time": profile.hourly_link_times[hour],
	}


static func completed_day(state) -> Dictionary:
	if state == null or state.profile == null:
		return {}
	var profile = state.profile
	var first_hour: int = state.first_recorded_bin / 4
	var hour_count: int = 24 - first_hour
	if hour_count <= 0 or profile.recorded_bin < 96:
		return {}
	var count: int = profile.link_ids.size()
	var demand := PackedVector2Array()
	var served := PackedVector2Array()
	var queue := PackedVector2Array()
	var time := PackedVector2Array()
	demand.resize(count)
	served.resize(count)
	queue.resize(count)
	time.resize(count)
	var weight: float = 1.0 / float(hour_count)
	for hour in range(first_hour, 24):
		var demand_row: PackedVector2Array = profile.hourly_volumes[hour]
		var served_row: PackedVector2Array = profile.hourly_served[hour]
		var time_row: PackedVector2Array = profile.hourly_link_times[hour]
		for index in range(count):
			demand[index] += demand_row[index] * weight
			served[index] += served_row[index] * weight
			time[index] += time_row[index] * weight
	for index in range(count):
		queue[index] = (profile.initial_queues[index] + profile.end_queues[index]) * 0.5
	return {
		"day_key": state.day_key,
		"link_ids": profile.link_ids,
		"by_link_id": _indices(profile.link_ids),
		"demand": demand,
		"served": served,
		"queue": queue,
		"time": time,
	}


static func _indices(link_ids: PackedInt32Array) -> Dictionary:
	var result: Dictionary = {}
	for index in range(link_ids.size()):
		result[link_ids[index]] = index
	return result
