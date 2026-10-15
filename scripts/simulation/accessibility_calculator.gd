extends RefCounted

const ROAD_SPEED_KMH = 35.0
const ACCESS_TIME_DECAY_MINUTES = 30.0
const LOCAL_TRAVEL_MINUTES = 5.0


static func recalculate(region) -> void:
	region.travel_times.clear()
	region.accessibility = PackedFloat32Array()
	var count: int = region.neighborhoods.size()
	for origin_id in range(count):
		var times := PackedFloat32Array()
		times.resize(count)
		var reachable_jobs := 0.0
		for destination_id in range(count):
			var origin = region.neighborhoods[origin_id]
			var destination = region.neighborhoods[destination_id]
			var distance_km: float = origin.position_km.distance_to(destination.position_km)
			var minutes: float = LOCAL_TRAVEL_MINUTES + distance_km * 60.0 / ROAD_SPEED_KMH
			times[destination_id] = minutes
			reachable_jobs += destination.jobs * exp(-minutes / ACCESS_TIME_DECAY_MINUTES)
		region.travel_times.append(times)
		region.accessibility.append(reachable_jobs)
