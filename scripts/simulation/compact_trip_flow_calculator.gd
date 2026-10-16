extends RefCounted

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const WORKERS_PER_HOUSEHOLD = 1.1
const TRAVEL_TIME_DECAY_MINUTES = 30.0
const BALANCING_PASSES = 40
const MAX_COMMUTE_DESTINATIONS = 64
const WEEKEND_COMMUTE_FRACTION = 0.25
const WEEKDAY_SHOPPING_VISITS_PER_PERSON = 0.20
const WEEKEND_SHOPPING_VISITS_PER_PERSON = 0.34
const WEEKDAY_SOCIAL_VISITS_PER_PERSON = 0.18
const WEEKEND_SOCIAL_VISITS_PER_PERSON = 0.32


static func build(region):
	var stage_started: int = Time.get_ticks_usec()
	var profile = FlowProfile.new()
	profile.is_compact = true
	profile.compact_region = region
	var city_count: int = region.cities.size()
	var workers := PackedFloat32Array()
	var jobs := PackedFloat32Array()
	workers.resize(city_count)
	jobs.resize(city_count)
	var origin := PackedFloat32Array()
	var destination := PackedFloat32Array()
	origin.resize(region.neighborhoods.size())
	destination.resize(region.neighborhoods.size())
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			continue
		workers[neighborhood.city_id] += float(neighborhood.households) * WORKERS_PER_HOUSEHOLD
		jobs[neighborhood.city_id] += neighborhood.jobs
	var row_targets := PackedFloat32Array()
	var column_targets := PackedFloat32Array()
	row_targets.resize(city_count)
	column_targets.resize(city_count)
	var assigned := PackedByteArray()
	assigned.resize(city_count)
	for first_city in range(city_count):
		if assigned[first_city] != 0:
			continue
		var component: Array[int] = []
		var worker_total := 0.0
		var job_total := 0.0
		for city_id in range(city_count):
			if region.city_travel_times[first_city][city_id] >= 1000000.0:
				continue
			assigned[city_id] = 1
			component.append(city_id)
			worker_total += workers[city_id]
			job_total += jobs[city_id]
		var commuters: float = minf(worker_total, job_total)
		profile.daily_commuters += commuters
		for city_id in component:
			row_targets[city_id] = workers[city_id] * commuters / maxf(1.0, worker_total)
			column_targets[city_id] = jobs[city_id] * commuters / maxf(1.0, job_total)
	profile.build_timings_us["targets"] = Time.get_ticks_usec() - stage_started
	stage_started = Time.get_ticks_usec()
	if region.city_od_candidates.size() != city_count:
		region.city_od_candidates.clear()
		for origin_city in range(city_count):
			var candidate_ids: Array[int] = []
			for destination_city in range(city_count):
				if region.city_travel_times[origin_city][destination_city] < 1000000.0:
					candidate_ids.append(destination_city)
			var times: PackedFloat32Array = region.city_travel_times[origin_city]
			candidate_ids.sort_custom(func(a: int, b: int) -> bool: return times[a] < times[b])
			var selected := PackedInt32Array()
			for index in range(mini(MAX_COMMUTE_DESTINATIONS, candidate_ids.size())):
				selected.append(candidate_ids[index])
			region.city_od_candidates.append(selected)
	var weights: Array[PackedFloat32Array] = []
	for origin_city in range(city_count):
		var row := PackedFloat32Array()
		var destinations: PackedInt32Array = region.city_od_candidates[origin_city]
		row.resize(destinations.size())
		for index in range(destinations.size()):
			var destination_city: int = destinations[index]
			var minutes: float = region.city_travel_times[origin_city][destination_city]
			if minutes < 1000000.0:
				row[index] = exp(-minutes / TRAVEL_TIME_DECAY_MINUTES)
		weights.append(row)
	profile.build_timings_us["kernel"] = Time.get_ticks_usec() - stage_started
	stage_started = Time.get_ticks_usec()
	var row_factors := PackedFloat32Array()
	var column_factors := PackedFloat32Array()
	row_factors.resize(city_count)
	column_factors.resize(city_count)
	column_factors.fill(1.0)
	var column_sums := PackedFloat32Array()
	column_sums.resize(city_count)
	for _pass_index in range(BALANCING_PASSES):
		for origin_city in range(city_count):
			var row_sum := 0.0
			var destinations: PackedInt32Array = region.city_od_candidates[origin_city]
			var row_weights: PackedFloat32Array = weights[origin_city]
			for index in range(destinations.size()):
				row_sum += row_weights[index] * column_factors[destinations[index]]
			row_factors[origin_city] = row_targets[origin_city] / maxf(0.000001, row_sum)
		column_sums.fill(0.0)
		for origin_city in range(city_count):
			var destinations: PackedInt32Array = region.city_od_candidates[origin_city]
			var row_weights: PackedFloat32Array = weights[origin_city]
			for index in range(destinations.size()):
				column_sums[destinations[index]] += row_weights[index] * row_factors[origin_city]
		for destination_city in range(city_count):
			column_factors[destination_city] = column_targets[destination_city] / maxf(0.000001, column_sums[destination_city])
	profile.build_timings_us["balance"] = Time.get_ticks_usec() - stage_started
	stage_started = Time.get_ticks_usec()
	var matrix: Array[PackedFloat32Array] = []
	for origin_city in range(city_count):
		var row := PackedFloat32Array()
		row.resize(city_count)
		var destinations: PackedInt32Array = region.city_od_candidates[origin_city]
		for index in range(destinations.size()):
			var destination_city: int = destinations[index]
			row[destination_city] = weights[origin_city][index] * row_factors[origin_city] * column_factors[destination_city]
		matrix.append(row)
	profile.compact_city_od[FlowProfile.WORK] = matrix
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			continue
		origin[neighborhood.id] = float(neighborhood.households) * WORKERS_PER_HOUSEHOLD * row_targets[neighborhood.city_id] / maxf(1.0, workers[neighborhood.city_id])
		destination[neighborhood.id] = float(neighborhood.jobs) * column_targets[neighborhood.city_id] / maxf(1.0, jobs[neighborhood.city_id])
	profile.compact_origin_daily[FlowProfile.WORK] = origin
	profile.compact_destination_daily[FlowProfile.WORK] = destination
	profile.build_timings_us["finalize"] = Time.get_ticks_usec() - stage_started
	return profile


static func populate_day(profile, region, unix_seconds: int, weekend: bool) -> void:
	var day_key: int = floori(float(unix_seconds) / 86400.0)
	if profile.active_day_key == day_key and profile.active_weekend == weekend:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = region.generation_seed * 1000003 + day_key * 9176 + 13417
	var shopping_rate: float = WEEKEND_SHOPPING_VISITS_PER_PERSON if weekend else WEEKDAY_SHOPPING_VISITS_PER_PERSON
	var social_rate: float = WEEKEND_SOCIAL_VISITS_PER_PERSON if weekend else WEEKDAY_SOCIAL_VISITS_PER_PERSON
	_build_visits(profile, region, FlowProfile.COMMERCIAL, shopping_rate)
	_build_visits(profile, region, FlowProfile.SOCIAL, social_rate)
	_build_region_od(profile, region)
	var work_out: PackedFloat32Array = _gaussian(10.5, 1.8) if weekend else _gaussian(8.0 + rng.randfn(0.0, 0.20), 1.2)
	var work_back: PackedFloat32Array = _gaussian(17.0, 1.8) if weekend else _gaussian(17.5 + rng.randfn(0.0, 0.20), 1.4)
	if weekend:
		for hour in range(24):
			work_out[hour] *= WEEKEND_COMMUTE_FRACTION
			work_back[hour] *= WEEKEND_COMMUTE_FRACTION
	var shopping_out: PackedFloat32Array = _gaussian(13.5, 2.2) if weekend else _mix(_gaussian(12.5, 1.8), _gaussian(18.0, 1.2), 0.55)
	var shopping_back: PackedFloat32Array = _gaussian(16.0, 2.2) if weekend else _mix(_gaussian(14.0, 1.8), _gaussian(19.5, 1.2), 0.55)
	var social_out: PackedFloat32Array = _mix(_gaussian(15.0, 3.5), _gaussian(21.0, 2.5), 0.6 if weekend else 0.5)
	var social_back := PackedFloat32Array()
	social_back.resize(24)
	for hour in range(24):
		social_back[hour] = 0.55 * social_out[(hour + 22) % 24] + 0.35 * social_out[(hour + 20) % 24] + 0.10 * social_out[(hour + 18) % 24]
	profile.compact_curves = {
		FlowProfile.WORK: {"out": work_out, "back": work_back},
		FlowProfile.COMMERCIAL: {"out": shopping_out, "back": shopping_back},
		FlowProfile.SOCIAL: {"out": social_out, "back": social_back},
	}
	profile.hourly_trips.resize(24)
	profile.hourly_work_trips.resize(24)
	profile.hourly_shopping_trips.resize(24)
	profile.hourly_social_trips.resize(24)
	var work_visits: float = profile.daily_commuters
	var shopping_visits: float = _sum(profile.compact_origin_daily[FlowProfile.COMMERCIAL])
	var social_visits: float = _sum(profile.compact_origin_daily[FlowProfile.SOCIAL])
	for hour in range(24):
		profile.hourly_work_trips[hour] = work_visits * (work_out[hour] + work_back[hour])
		profile.hourly_shopping_trips[hour] = shopping_visits * (shopping_out[hour] + shopping_back[hour])
		profile.hourly_social_trips[hour] = social_visits * (social_out[hour] + social_back[hour])
		profile.hourly_trips[hour] = profile.hourly_work_trips[hour] + profile.hourly_shopping_trips[hour] + profile.hourly_social_trips[hour]
	profile.active_day_key = day_key
	profile.active_weekend = weekend


static func _build_visits(profile, region, purpose: String, rate: float) -> void:
	var city_count: int = region.cities.size()
	var origin_city := PackedFloat32Array()
	var attraction_city := PackedFloat32Array()
	origin_city.resize(city_count)
	attraction_city.resize(city_count)
	var origin := PackedFloat32Array()
	var destination := PackedFloat32Array()
	origin.resize(region.neighborhoods.size())
	destination.resize(region.neighborhoods.size())
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			continue
		var visits: float = float(neighborhood.population) * rate
		var attraction: float = float(neighborhood.shopping_attraction) if purpose == FlowProfile.COMMERCIAL else float(neighborhood.population)
		origin[neighborhood.id] = visits
		origin_city[neighborhood.city_id] += visits
		attraction_city[neighborhood.city_id] += attraction
	var matrix: Array[PackedFloat32Array] = []
	var arrivals := PackedFloat32Array()
	arrivals.resize(city_count)
	for origin_id in range(city_count):
		var row := PackedFloat32Array()
		row.resize(city_count)
		var total_weight := 0.0
		var candidates: PackedInt32Array = region.city_od_candidates[origin_id]
		for destination_id in candidates:
			var minutes: float = region.city_travel_times[origin_id][destination_id]
			if minutes < 1000000.0:
				var local_weight: float = 1.25 if purpose == FlowProfile.SOCIAL and origin_id == destination_id else 1.0
				row[destination_id] = attraction_city[destination_id] * local_weight * exp(-minutes / TRAVEL_TIME_DECAY_MINUTES)
				total_weight += row[destination_id]
		if total_weight > 0.0:
			for destination_id in candidates:
				row[destination_id] *= origin_city[origin_id] / total_weight
				arrivals[destination_id] += row[destination_id]
		matrix.append(row)
	for neighborhood in region.neighborhoods:
		if region.neighborhood_accessible[neighborhood.id] == 0:
			continue
		var attraction: float = float(neighborhood.shopping_attraction) if purpose == FlowProfile.COMMERCIAL else float(neighborhood.population)
		destination[neighborhood.id] = arrivals[neighborhood.city_id] * attraction / maxf(1.0, attraction_city[neighborhood.city_id])
	profile.compact_city_od[purpose] = matrix
	profile.compact_origin_daily[purpose] = origin
	profile.compact_destination_daily[purpose] = destination


static func _build_region_od(profile, region) -> void:
	var region_count: int = region.region_ids.size()
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		var matrix: Array[PackedFloat32Array] = []
		for _region_id in range(region_count):
			var row := PackedFloat32Array()
			row.resize(region_count)
			matrix.append(row)
		var city_matrix: Array = profile.compact_city_od[purpose]
		for origin_city in range(region.cities.size()):
			var from_region: int = region.cities[origin_city]["region_id"]
			for destination_city in range(region.cities.size()):
				var to_region: int = region.cities[destination_city]["region_id"]
				matrix[from_region][to_region] += city_matrix[origin_city][destination_city]
		profile.compact_region_od[purpose] = matrix


static func _gaussian(mean_hour: float, deviation: float) -> PackedFloat32Array:
	var shares := PackedFloat32Array()
	shares.resize(24)
	var total := 0.0
	for hour in range(24):
		var distance: float = minf(absf(float(hour) - mean_hour), 24.0 - absf(float(hour) - mean_hour))
		shares[hour] = exp(-0.5 * pow(distance / deviation, 2.0))
		total += shares[hour]
	for hour in range(24):
		shares[hour] /= total
	return shares


static func _mix(first: PackedFloat32Array, second: PackedFloat32Array, first_share: float) -> PackedFloat32Array:
	var mixed := PackedFloat32Array()
	mixed.resize(24)
	for hour in range(24):
		mixed[hour] = first[hour] * first_share + second[hour] * (1.0 - first_share)
	return mixed


static func _sum(values: PackedFloat32Array) -> float:
	var result := 0.0
	for value in values:
		result += value
	return result
