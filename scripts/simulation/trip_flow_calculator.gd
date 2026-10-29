extends RefCounted

const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")

const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const CompactTripFlowCalculator = preload("res://scripts/simulation/compact_trip_flow_calculator.gd")

const WORKERS_PER_HOUSEHOLD = 1.1
const TRAVEL_TIME_DECAY_MINUTES = 30.0
const BALANCING_PASSES = 400
const WEEKEND_COMMUTE_FRACTION = 0.25
const WEEKDAY_SHOPPING_VISITS_PER_PERSON = 0.20
const WEEKEND_SHOPPING_VISITS_PER_PERSON = 0.34
const WEEKDAY_SOCIAL_VISITS_PER_PERSON = 0.18
const WEEKEND_SOCIAL_VISITS_PER_PERSON = 0.32
const LOCAL_SOCIAL_DESTINATION_WEIGHT = 0.25
const SOCIAL_STAY_HOURS = [2, 4, 6]
const SOCIAL_STAY_SHARES = [0.55, 0.35, 0.10]


static func extend_for_empty_districts(previous, region):
	if previous.is_compact:
		return CompactTripFlowCalculator.extend_for_empty_districts(previous, region)
	var profile = FlowProfile.new()
	for property in previous.get_property_list():
		if not int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE: continue
		var field: String = property.name
		var value = previous.get(field)
		if field.ends_with("_od") and value is Array:
			if field.begins_with("hourly_"):
				var hours: Array = []
				for matrix in value: hours.append(extend_matrix(matrix, region.neighborhoods.size()))
				profile.set(field, hours)
			else:
				profile.set(field, extend_matrix(value, region.neighborhoods.size()))
		else:
			profile.set(field, value.duplicate(true) if value is Dictionary else value)
	return profile


static func extend_matrix(matrix: Array, count: int, fill: float = 0.0) -> Array[PackedFloat32Array]:
	var result: Array[PackedFloat32Array] = []
	for i in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		if fill != 0.0: row.fill(fill)
		if i < matrix.size():
			var previous: PackedFloat32Array = matrix[i]
			for j in range(previous.size()): row[j] = previous[j]
		result.append(row)
	return result


static func build(region):
	if region.is_large_scale:
		return CompactTripFlowCalculator.build(region)
	var profile = FlowProfile.new()
	var count: int = region.neighborhoods.size()
	var worker_supply := PackedFloat32Array()
	var job_demand := PackedFloat32Array()
	worker_supply.resize(count)
	job_demand.resize(count)
	for id in range(count):
		worker_supply[id] = region.neighborhoods[id].households * WORKERS_PER_HOUSEHOLD
		job_demand[id] = region.neighborhoods[id].jobs

	var row_targets := PackedFloat32Array()
	var column_targets := PackedFloat32Array()
	row_targets.resize(count)
	column_targets.resize(count)
	var assigned := PackedByteArray()
	assigned.resize(count)
	for first_id in range(count):
		if assigned[first_id] != 0:
			continue
		var component: Array[int] = []
		var workers := 0.0
		var jobs := 0.0
		for id in range(count):
			if region.travel_times[first_id][id] >= 1000000.0:
				continue
			assigned[id] = 1
			component.append(id)
			workers += worker_supply[id]
			jobs += job_demand[id]
		var commuters := minf(workers, jobs)
		profile.daily_commuters += commuters
		for id in component:
			row_targets[id] = worker_supply[id] * commuters / maxf(1.0, workers)
			column_targets[id] = job_demand[id] * commuters / maxf(1.0, jobs)

	# Balance workplace destinations against jobs while preferring shorter trips.
	for origin_id in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		for destination_id in range(count):
			var minutes: float = region.travel_times[origin_id][destination_id]
			row[destination_id] = maxf(exp(-minutes / TRAVEL_TIME_DECAY_MINUTES), 0.000001) if minutes < 1000000.0 else 0.0
		profile.daily_work_od.append(row)
	if profile.daily_commuters > 0.0:
		for pass_index in range(BALANCING_PASSES):
			for origin_id in range(count):
				var row_sum := 0.0
				for destination_id in range(count):
					row_sum += profile.daily_work_od[origin_id][destination_id]
				var row_scale: float = row_targets[origin_id] / maxf(row_sum, 0.000001)
				for destination_id in range(count):
					profile.daily_work_od[origin_id][destination_id] *= row_scale
			for destination_id in range(count):
				var column_sum := 0.0
				for origin_id in range(count):
					column_sum += profile.daily_work_od[origin_id][destination_id]
				var column_scale: float = column_targets[destination_id] / maxf(column_sum, 0.000001)
				for origin_id in range(count):
					profile.daily_work_od[origin_id][destination_id] *= column_scale
			if pass_index % 10 == 9:
				var largest_error := 0.0
				for origin_id in range(count):
					var actual := 0.0
					for commuters in profile.daily_work_od[origin_id]:
						actual += commuters
					largest_error = maxf(largest_error, absf(actual - row_targets[origin_id]) / maxf(1.0, row_targets[origin_id]))
				if largest_error < 0.005:
					break
	else:
		for row in profile.daily_work_od:
			row.fill(0.0)

	profile.weekday_shopping_od = _build_shopping_od(region, WEEKDAY_SHOPPING_VISITS_PER_PERSON)
	profile.weekend_shopping_od = _build_shopping_od(region, WEEKEND_SHOPPING_VISITS_PER_PERSON)
	profile.weekday_social_od = _build_social_od(region, WEEKDAY_SOCIAL_VISITS_PER_PERSON)
	profile.weekend_social_od = _build_social_od(region, WEEKEND_SOCIAL_VISITS_PER_PERSON)
	for row in profile.weekday_shopping_od:
		for visits in row:
			profile.weekday_shopping_visits += visits
	for row in profile.weekend_shopping_od:
		for visits in row:
			profile.weekend_shopping_visits += visits
	for row in profile.weekday_social_od:
		for visits in row:
			profile.weekday_social_visits += visits
	for row in profile.weekend_social_od:
		for visits in row:
			profile.weekend_social_visits += visits
	return profile


static func populate_day(profile, region_seed: int, unix_seconds: int, weekend: bool, previous_day_profile = null, parallel_hours: bool = true) -> void:
	if profile.is_compact:
		CompactTripFlowCalculator.populate_day(profile, profile.compact_region, unix_seconds, weekend)
		return
	var day_key := floori(float(unix_seconds) / 86400.0)
	if profile.active_day_key == day_key and profile.active_weekend == weekend:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = region_seed * 1000003 + day_key * 9176 + 13417

	# Each day's mean departure time drifts slightly. Within the day, hourly
	# departure shares follow normalized normal distributions around those means.
	var work_outbound: PackedFloat32Array
	var work_return: PackedFloat32Array
	var shopping_outbound: PackedFloat32Array
	var shopping_return: PackedFloat32Array
	if weekend:
		work_outbound = _gaussian_hours(10.5 + rng.randfn(0.0, 0.25), 1.8, 5, 14)
		work_return = _gaussian_hours(17.0 + rng.randfn(0.0, 0.25), 1.8, 15, 23)
		var shopping_shift: float = rng.randfn(0.0, 0.30)
		shopping_outbound = _gaussian_hours(13.5 + shopping_shift, 2.2, 7, 20)
		shopping_return = _gaussian_hours(16.0 + shopping_shift, 2.2, 9, 23)
	else:
		work_outbound = _gaussian_hours(8.0 + rng.randfn(0.0, 0.20), 1.2, 4, 12)
		work_return = _gaussian_hours(17.5 + rng.randfn(0.0, 0.20), 1.4, 14, 23)
		var shopping_shift: float = rng.randfn(0.0, 0.25)
		shopping_outbound = _mix_hours(
			_gaussian_hours(12.5 + shopping_shift, 1.8, 8, 17),
			_gaussian_hours(18.0 + shopping_shift, 1.2, 15, 22), 0.55)
		shopping_return = _mix_hours(
			_gaussian_hours(14.0 + shopping_shift, 1.8, 9, 20),
			_gaussian_hours(19.5 + shopping_shift, 1.2, 16, 23), 0.55)

	var shopping_od: Array[PackedFloat32Array] = profile.weekend_shopping_od if weekend else profile.weekday_shopping_od
	var social_od: Array[PackedFloat32Array] = profile.weekend_social_od if weekend else profile.weekday_social_od
	var previous_day_weekend: bool = CalendarClock.is_weekend_unix((day_key - 1) * 86400)
	var previous_source = previous_day_profile if previous_day_profile != null else profile
	var previous_social_od: Array[PackedFloat32Array] = previous_source.weekend_social_od if previous_day_weekend else previous_source.weekday_social_od
	var social_departures: PackedFloat32Array = _social_departure_hours(day_key, region_seed, weekend)
	var previous_social_departures: PackedFloat32Array = _social_departure_hours(day_key - 1, region_seed, previous_day_weekend)
	var work_scale := WEEKEND_COMMUTE_FRACTION if weekend else 1.0
	_fill_hourly_matrices(profile, shopping_od, social_od, previous_social_od, work_outbound, work_return, shopping_outbound, shopping_return, social_departures, previous_social_departures, work_scale, parallel_hours)
	profile.active_day_key = day_key
	profile.active_weekend = weekend


static func copy_for_day(base_profile, region_seed: int, unix_seconds: int, weekend: bool):
	var profile = FlowProfile.new()
	profile.daily_commuters = base_profile.daily_commuters
	profile.daily_work_od = base_profile.daily_work_od
	profile.weekday_shopping_od = base_profile.weekday_shopping_od
	profile.weekend_shopping_od = base_profile.weekend_shopping_od
	profile.weekday_social_od = base_profile.weekday_social_od
	profile.weekend_social_od = base_profile.weekend_social_od
	profile.weekday_shopping_visits = base_profile.weekday_shopping_visits
	profile.weekend_shopping_visits = base_profile.weekend_shopping_visits
	profile.weekday_social_visits = base_profile.weekday_social_visits
	profile.weekend_social_visits = base_profile.weekend_social_visits
	populate_day(profile, region_seed, unix_seconds, weekend, base_profile)
	return profile


static func _build_shopping_od(region, visits_per_person: float) -> Array[PackedFloat32Array]:
	var count: int = region.neighborhoods.size()
	var attractiveness := PackedFloat32Array()
	attractiveness.resize(count)
	for destination_id in range(count):
		attractiveness[destination_id] = region.neighborhoods[destination_id].shopping_attraction

	var daily_od: Array[PackedFloat32Array] = []
	for origin_id in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		var row_weight := 0.0
		for destination_id in range(count):
			var county = region.jurisdiction_for_neighborhood(destination_id, "County")
			var city = region.jurisdiction_for_neighborhood(destination_id, "City")
			var district = region.jurisdiction_for_neighborhood(destination_id, "Neighborhood")
			var extra_cost: float = FiscalCalculator.shopping_spend(region, origin_id) * (county.sales_tax_rate if county != null else 0.0) + (city.parking_fee if city != null else 0.0) + (district.parking_fee if district != null else 0.0)
			row[destination_id] = attractiveness[destination_id] * exp(-(region.travel_times[origin_id][destination_id] + extra_cost / 0.40) / TRAVEL_TIME_DECAY_MINUTES)
			row_weight += row[destination_id]
		if row_weight > 0.0:
			var visits: float = region.neighborhoods[origin_id].population * visits_per_person
			for destination_id in range(count):
				row[destination_id] *= visits / row_weight
		daily_od.append(row)
	return daily_od


static func _build_social_od(region, visits_per_person: float) -> Array[PackedFloat32Array]:
	var count: int = region.neighborhoods.size()
	var daily_od: Array[PackedFloat32Array] = []
	for origin_id in range(count):
		var row := PackedFloat32Array()
		row.resize(count)
		var row_weight := 0.0
		for destination_id in range(count):
			var destination_population: float = region.neighborhoods[destination_id].population
			var local_weight := LOCAL_SOCIAL_DESTINATION_WEIGHT if origin_id == destination_id else 1.0
			var city = region.jurisdiction_for_neighborhood(destination_id, "City")
			var district = region.jurisdiction_for_neighborhood(destination_id, "Neighborhood")
			var extra_cost: float = (city.parking_fee if city != null else 0.0) + (district.parking_fee if district != null else 0.0)
			row[destination_id] = destination_population * exp(-(region.travel_times[origin_id][destination_id] + extra_cost / 0.40) / TRAVEL_TIME_DECAY_MINUTES) * local_weight
			row_weight += row[destination_id]
		if row_weight > 0.0:
			var visits: float = region.neighborhoods[origin_id].population * visits_per_person
			for destination_id in range(count):
				row[destination_id] *= visits / row_weight
		daily_od.append(row)
	return daily_od


static func _social_departure_hours(day_key: int, region_seed: int, weekend: bool) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = region_seed * 1000003 + day_key * 9176 + 68147
	var midday: PackedFloat32Array
	var evening: PackedFloat32Array
	var midday_share: float
	var all_hours_share: float
	if weekend:
		midday = _circular_gaussian_hours(14.5 + rng.randfn(0.0, 0.3), 3.0)
		evening = _circular_gaussian_hours(20.5 + rng.randfn(0.0, 0.3), 2.5)
		midday_share = 0.50
		all_hours_share = 0.14
	else:
		midday = _circular_gaussian_hours(12.5 + rng.randfn(0.0, 0.25), 2.0)
		evening = _circular_gaussian_hours(19.5 + rng.randfn(0.0, 0.25), 2.5)
		midday_share = 0.25
		all_hours_share = 0.12
	var shares := _mix_hours(midday, evening, midday_share)
	for hour in range(24):
		shares[hour] = shares[hour] * (1.0 - all_hours_share) + all_hours_share / 24.0
	return shares


static func _circular_gaussian_hours(mean_hour: float, deviation: float) -> PackedFloat32Array:
	var shares := PackedFloat32Array()
	shares.resize(24)
	var total := 0.0
	for hour in range(24):
		var distance: float = absf(float(hour) - mean_hour)
		distance = minf(distance, 24.0 - distance) / deviation
		shares[hour] = exp(-0.5 * distance * distance)
		total += shares[hour]
	for hour in range(24):
		shares[hour] /= total
	return shares


static func _gaussian_hours(mean_hour: float, deviation: float, first_hour: int, last_hour: int) -> PackedFloat32Array:
	var shares := PackedFloat32Array()
	shares.resize(24)
	var total := 0.0
	for hour in range(first_hour, last_hour + 1):
		var distance: float = (float(hour) - mean_hour) / deviation
		shares[hour] = exp(-0.5 * distance * distance)
		total += shares[hour]
	if total > 0.0:
		for hour in range(24):
			shares[hour] /= total
	return shares


static func _mix_hours(first: PackedFloat32Array, second: PackedFloat32Array, first_share: float) -> PackedFloat32Array:
	var mixed := PackedFloat32Array()
	mixed.resize(24)
	for hour in range(24):
		mixed[hour] = first[hour] * first_share + second[hour] * (1.0 - first_share)
	return mixed


static func _fill_hourly_matrices(profile, shopping_od: Array[PackedFloat32Array], social_od: Array[PackedFloat32Array], previous_social_od: Array[PackedFloat32Array], work_outbound: PackedFloat32Array, work_return: PackedFloat32Array, shopping_outbound: PackedFloat32Array, shopping_return: PackedFloat32Array, social_departures: PackedFloat32Array, previous_social_departures: PackedFloat32Array, work_scale: float, parallel_hours: bool) -> void:
	profile.hourly_od.clear()
	profile.hourly_work_od.clear()
	profile.hourly_shopping_od.clear()
	profile.hourly_social_od.clear()
	profile.hourly_work_outbound_od.clear()
	profile.hourly_work_return_od.clear()
	profile.hourly_shopping_outbound_od.clear()
	profile.hourly_shopping_return_od.clear()
	profile.hourly_social_outbound_od.clear()
	profile.hourly_social_return_od.clear()
	profile.hourly_trips.resize(24)
	profile.hourly_work_trips.resize(24)
	profile.hourly_shopping_trips.resize(24)
	profile.hourly_social_trips.resize(24)
	var count: int = profile.daily_work_od.size()
	var peak_all := 1.0
	var peak_work := 1.0
	var peak_shopping := 1.0
	var peak_social := 1.0
	var inputs := {
		"shopping_od": shopping_od,
		"social_od": social_od,
		"previous_social_od": previous_social_od,
		"work_outbound": work_outbound,
		"work_return": work_return,
		"shopping_outbound": shopping_outbound,
		"shopping_return": shopping_return,
		"social_departures": social_departures,
		"previous_social_departures": previous_social_departures,
		"work_scale": work_scale,
	}
	var hourly_results: Array = []
	hourly_results.resize(24)
	# Each worker reads the same daily matrices and writes only its own hour slot.
	if parallel_hours and count >= 32 and OS.get_processor_count() > 1:
		var workers := mini(16, OS.get_processor_count())
		var task_id := WorkerThreadPool.add_group_task(
			func(hour: int) -> void:
				hourly_results[hour] = _build_hour(profile.daily_work_od, hour, count, inputs),
			24, workers, false, "Hourly trip demand")
		WorkerThreadPool.wait_for_group_task_completion(task_id)
	else:
		for hour in range(24):
			hourly_results[hour] = _build_hour(profile.daily_work_od, hour, count, inputs)
	for hour in range(24):
		var result: Dictionary = hourly_results[hour]
		profile.hourly_work_od.append(result["work_matrix"])
		profile.hourly_shopping_od.append(result["shopping_matrix"])
		profile.hourly_social_od.append(result["social_matrix"])
		profile.hourly_work_outbound_od.append(result["work_out_matrix"])
		profile.hourly_work_return_od.append(result["work_return_matrix"])
		profile.hourly_shopping_outbound_od.append(result["shopping_out_matrix"])
		profile.hourly_shopping_return_od.append(result["shopping_return_matrix"])
		profile.hourly_social_outbound_od.append(result["social_out_matrix"])
		profile.hourly_social_return_od.append(result["social_return_matrix"])
		profile.hourly_od.append(result["all_matrix"])
		profile.hourly_work_trips[hour] = result["work_total"]
		profile.hourly_shopping_trips[hour] = result["shopping_total"]
		profile.hourly_social_trips[hour] = result["social_total"]
		profile.hourly_trips[hour] = result["work_total"] + result["shopping_total"] + result["social_total"]
		peak_all = maxf(peak_all, result["peak_all"])
		peak_work = maxf(peak_work, result["peak_work"])
		peak_shopping = maxf(peak_shopping, result["peak_shopping"])
		peak_social = maxf(peak_social, result["peak_social"])
	profile.peak_net_trips_by_purpose = {FlowProfile.ALL: peak_all, FlowProfile.WORK: peak_work, FlowProfile.COMMERCIAL: peak_shopping, FlowProfile.SOCIAL: peak_social}


static func _build_hour(daily_work_od: Array[PackedFloat32Array], hour: int, count: int, inputs: Dictionary) -> Dictionary:
	var shopping_od: Array[PackedFloat32Array] = inputs["shopping_od"]
	var social_od: Array[PackedFloat32Array] = inputs["social_od"]
	var previous_social_od: Array[PackedFloat32Array] = inputs["previous_social_od"]
	var work_outbound: PackedFloat32Array = inputs["work_outbound"]
	var work_return: PackedFloat32Array = inputs["work_return"]
	var shopping_outbound: PackedFloat32Array = inputs["shopping_outbound"]
	var shopping_return: PackedFloat32Array = inputs["shopping_return"]
	var social_departures: PackedFloat32Array = inputs["social_departures"]
	var previous_social_departures: PackedFloat32Array = inputs["previous_social_departures"]
	var work_scale: float = inputs["work_scale"]
	var all_matrix: Array[PackedFloat32Array] = []
	var work_matrix: Array[PackedFloat32Array] = []
	var shopping_matrix: Array[PackedFloat32Array] = []
	var social_matrix: Array[PackedFloat32Array] = []
	var work_out_matrix: Array[PackedFloat32Array] = []
	var work_return_matrix: Array[PackedFloat32Array] = []
	var shopping_out_matrix: Array[PackedFloat32Array] = []
	var shopping_return_matrix: Array[PackedFloat32Array] = []
	var social_out_matrix: Array[PackedFloat32Array] = []
	var social_return_matrix: Array[PackedFloat32Array] = []
	var work_total := 0.0
	var shopping_total := 0.0
	var social_total := 0.0
	var social_return_today := 0.0
	var social_return_previous := 0.0
	for stay_index in range(SOCIAL_STAY_HOURS.size()):
		var departure_hour: int = hour - SOCIAL_STAY_HOURS[stay_index]
		if departure_hour >= 0:
			social_return_today += social_departures[departure_hour] * SOCIAL_STAY_SHARES[stay_index]
		else:
			social_return_previous += previous_social_departures[24 + departure_hour] * SOCIAL_STAY_SHARES[stay_index]
	for origin_id in range(count):
		var all_row := PackedFloat32Array()
		var work_row := PackedFloat32Array()
		var shopping_row := PackedFloat32Array()
		var social_row := PackedFloat32Array()
		var work_out_row := PackedFloat32Array()
		var work_return_row := PackedFloat32Array()
		var shopping_out_row := PackedFloat32Array()
		var shopping_return_row := PackedFloat32Array()
		var social_out_row := PackedFloat32Array()
		var social_return_row := PackedFloat32Array()
		all_row.resize(count)
		work_row.resize(count)
		shopping_row.resize(count)
		social_row.resize(count)
		work_out_row.resize(count)
		work_return_row.resize(count)
		shopping_out_row.resize(count)
		shopping_return_row.resize(count)
		social_out_row.resize(count)
		social_return_row.resize(count)
		for destination_id in range(count):
			work_out_row[destination_id] = daily_work_od[origin_id][destination_id] * work_outbound[hour] * work_scale
			work_return_row[destination_id] = daily_work_od[destination_id][origin_id] * work_return[hour] * work_scale
			shopping_out_row[destination_id] = shopping_od[origin_id][destination_id] * shopping_outbound[hour]
			shopping_return_row[destination_id] = shopping_od[destination_id][origin_id] * shopping_return[hour]
			social_out_row[destination_id] = social_od[origin_id][destination_id] * social_departures[hour]
			social_return_row[destination_id] = social_od[destination_id][origin_id] * social_return_today + previous_social_od[destination_id][origin_id] * social_return_previous
			var work_trips: float = work_out_row[destination_id] + work_return_row[destination_id]
			var shopping_trips: float = shopping_out_row[destination_id] + shopping_return_row[destination_id]
			var social_trips: float = social_out_row[destination_id] + social_return_row[destination_id]
			work_row[destination_id] = work_trips
			shopping_row[destination_id] = shopping_trips
			social_row[destination_id] = social_trips
			all_row[destination_id] = work_trips + shopping_trips + social_trips
			work_total += work_trips
			shopping_total += shopping_trips
			social_total += social_trips
		work_matrix.append(work_row)
		shopping_matrix.append(shopping_row)
		social_matrix.append(social_row)
		work_out_matrix.append(work_out_row)
		work_return_matrix.append(work_return_row)
		shopping_out_matrix.append(shopping_out_row)
		shopping_return_matrix.append(shopping_return_row)
		social_out_matrix.append(social_out_row)
		social_return_matrix.append(social_return_row)
		all_matrix.append(all_row)
	var peak_all := 1.0
	var peak_work := 1.0
	var peak_shopping := 1.0
	var peak_social := 1.0
	for first_id in range(count):
		for second_id in range(first_id + 1, count):
			peak_all = maxf(peak_all, absf(all_matrix[first_id][second_id] - all_matrix[second_id][first_id]))
			peak_work = maxf(peak_work, absf(work_matrix[first_id][second_id] - work_matrix[second_id][first_id]))
			peak_shopping = maxf(peak_shopping, absf(shopping_matrix[first_id][second_id] - shopping_matrix[second_id][first_id]))
			peak_social = maxf(peak_social, maxf(social_matrix[first_id][second_id], social_matrix[second_id][first_id]))
	return {"all_matrix": all_matrix, "work_matrix": work_matrix, "shopping_matrix": shopping_matrix, "social_matrix": social_matrix, "work_out_matrix": work_out_matrix, "work_return_matrix": work_return_matrix, "shopping_out_matrix": shopping_out_matrix, "shopping_return_matrix": shopping_return_matrix, "social_out_matrix": social_out_matrix, "social_return_matrix": social_return_matrix, "work_total": work_total, "shopping_total": shopping_total, "social_total": social_total, "peak_all": peak_all, "peak_work": peak_work, "peak_shopping": peak_shopping, "peak_social": peak_social}
