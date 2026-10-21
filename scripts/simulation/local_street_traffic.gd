extends RefCounted

const Paths = preload("res://scripts/simulation/street_paths.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")


static func prepare(region, state, previous_state = null, unix_seconds: int = -1) -> void:
	var previous_districts: Dictionary = previous_state.local_districts if previous_state != null else {}
	state.local_districts = {}
	state.local_clock = unix_seconds if unix_seconds >= 0 else state.unix_seconds
	for neighborhood in region.neighborhoods:
		var layout = neighborhood.street_layout
		var plan = neighborhood.development_plan
		if layout == null or plan == null or plan.completed_phase == 0:
			continue
		var old: Dictionary = previous_districts.get(neighborhood.id, {})
		var portals := PackedInt32Array()
		for local_id in plan.core_node_ids:
			portals.append(local_id)
		var signature: int = hash([layout.get_instance_id(), plan.completed_phase, portals, plan.installed_multiplier, neighborhood.zone_shares, neighborhood.zone_density])
		var count: int = layout.edges.size()
		var queues := PackedVector2Array()
		if not old.is_empty() and old["queues"].size() == count:
			queues = old["queues"].duplicate()
		else:
			queues.resize(count)
		if old.get("signature", -1) == signature:
			var reused: Dictionary = old.duplicate()
			reused["queues"] = queues
			reused["served"] = old["served"].duplicate()
			reused["hour"] = -1
			state.local_districts[neighborhood.id] = reused
			continue
		var enabled := PackedByteArray()
		var costs := PackedFloat32Array()
		var served := PackedVector2Array()
		enabled.resize(count)
		served.resize(count)
		for edge_id in range(count):
			enabled[edge_id] = 1 if layout.phases[edge_id] <= plan.completed_phase and not layout.closed_edges.has(edge_id) else 0
			costs.append(layout.lengths[edge_id] * 60.0 / RoadGraph.free_speed_kmh(layout.classes[edge_id]))
		var adjacency: Array = Paths.adjacency(layout.nodes.size(), layout.edges, enabled)
		var tree_result: Dictionary = Paths.tree(adjacency, costs, portals)
		var record: Dictionary = {"queues": queues, "served": served, "tree": tree_result, "hour": -1, "entered": float(old.get("entered", 0.0)), "discharged": float(old.get("discharged", 0.0)), "wait_minutes": float(old.get("wait_minutes", 0.0)), "queued": float(old.get("queued", 0.0))}
		record["adjacency"] = adjacency
		record["base_costs"] = costs
		record["portals"] = portals
		_build_weights(neighborhood, record)
		record["signature"] = signature
		record["capacity"] = 225.0 * plan.installed_multiplier
		state.local_districts[neighborhood.id] = record


static func advance_to(region, profile, state, unix_seconds: int) -> void:
	while state.local_clock < unix_seconds:
		var hour: int = floori(float(posmod(state.local_clock, 86400)) / 3600.0)
		var finish: int = mini(unix_seconds, (floori(float(state.local_clock) / 3600.0) + 1) * 3600)
		var hours: float = float(finish - state.local_clock) / 3600.0
		for neighborhood_id in state.local_districts:
			var neighborhood = region.neighborhoods[neighborhood_id]
			var record: Dictionary = state.local_districts[neighborhood_id]
			if record["hour"] != hour:
				if record["queued"] > 0.00001:
					_reroute(neighborhood, record)
				_load_hour(neighborhood, profile, record, hour)
			var layout = neighborhood.street_layout
			var total_rate: float = record["out_rate"] + record["in_rate"]
			if record["queued"] < 0.00001 and total_rate * record["largest_weight"] < record["capacity"]:
				var home_rates: Vector2 = record["home_rates"]
				var job_rates: Vector2 = record["job_rates"]
				var entered: float = ((home_rates.x + home_rates.y) * record["home_weight_sum"] + (job_rates.x + job_rates.y) * record["job_weight_sum"]) * hours
				record["entered"] += entered
				record["discharged"] += entered
				record["wait_minutes"] = 0.0
				neighborhood.access_minutes = record["free_minutes"]
				continue
			var queues: PackedVector2Array = record["queues"]
			var served: PackedVector2Array = record["served"]
			var queued := 0.0
			var arrival_rate := 0.0
			for edge_id in range(layout.edges.size()):
				if layout.classes[edge_id] != Roads.LOCAL:
					continue
				var rates: Vector2 = edge_rate(record, edge_id)
				var arriving: Vector2 = rates * hours
				var available: Vector2 = queues[edge_id] + arriving
				var capacity: float = record["capacity"] * hours
				var discharged := Vector2(minf(available.x, capacity), minf(available.y, capacity))
				queues[edge_id] = available - discharged
				served[edge_id] = discharged / maxf(hours, 0.000001)
				record["entered"] += arriving.x + arriving.y
				record["discharged"] += discharged.x + discharged.y
				queued += queues[edge_id].x + queues[edge_id].y
				arrival_rate += rates.x + rates.y
			record["queues"] = queues
			record["served"] = served
			record["queued"] = queued
			record["wait_minutes"] = queued * 60.0 / maxf(1.0, arrival_rate)
			neighborhood.access_minutes = float(record.get("free_minutes", 0.0)) + record["wait_minutes"]
		state.local_clock = finish


static func _load_hour(neighborhood, profile, record: Dictionary, hour: int) -> void:
	var outward := 0.0
	var inward := 0.0
	var home_rates := Vector2.ZERO
	var job_rates := Vector2.ZERO
	if profile.is_compact:
		for purpose in ["Work", "Commercial", "Social"]:
			var divisor: float = {"Work": 1.2, "Commercial": 1.5, "Social": 1.8}[purpose]
			var origins: float = profile.compact_origin_daily[purpose][neighborhood.id] / divisor * 0.6
			var destinations: float = profile.compact_destination_daily[purpose][neighborhood.id] / divisor * 0.6
			outward += origins * profile.compact_curves[purpose]["out"][hour] + destinations * profile.compact_curves[purpose]["back"][hour]
			inward += destinations * profile.compact_curves[purpose]["out"][hour] + origins * profile.compact_curves[purpose]["back"][hour]
			home_rates += Vector2(origins * profile.compact_curves[purpose]["out"][hour], origins * profile.compact_curves[purpose]["back"][hour])
			job_rates += Vector2(destinations * profile.compact_curves[purpose]["back"][hour], destinations * profile.compact_curves[purpose]["out"][hour])
	else:
		for destination_id in range(profile.hourly_od[hour].size()):
			outward += profile.hourly_od[hour][neighborhood.id][destination_id] * 0.5
			inward += profile.hourly_od[hour][destination_id][neighborhood.id] * 0.5
		home_rates = Vector2(outward, inward) * 0.5
		job_rates = home_rates
	record["out_rate"] = outward
	record["in_rate"] = inward
	record["home_rates"] = home_rates
	record["job_rates"] = job_rates
	record["hour"] = hour


static func edge_rate(record: Dictionary, edge_id: int) -> Vector2:
	var weight: Vector2 = record["weights"][edge_id]
	var jobs: Vector2 = record["job_weights"][edge_id]
	var home_rate: Vector2 = record.get("home_rates", Vector2.ZERO)
	var job_rate: Vector2 = record.get("job_rates", Vector2.ZERO)
	return Vector2(weight.x * home_rate.x + weight.y * home_rate.y + jobs.x * job_rate.x + jobs.y * job_rate.y, weight.y * home_rate.x + weight.x * home_rate.y + jobs.y * job_rate.x + jobs.x * job_rate.y)


static func _build_weights(neighborhood, record: Dictionary) -> void:
	var layout = neighborhood.street_layout
	var weights := PackedVector2Array()
	weights.resize(layout.edges.size())
	var job_weights := PackedVector2Array()
	job_weights.resize(layout.edges.size())
	var blocks: Array = []
	var total_weight := 0.0
	var total_jobs := 0.0
	for block_id in range(layout.blocks.size()):
		var block: Dictionary = layout.blocks[block_id]
		if block["phase"] > neighborhood.development_plan.completed_phase or block["park"] or block.get("demolished", false):
			continue
		var node_id: int = block["nodes"][0]
		if record["tree"]["distances"][node_id] >= 1000000.0:
			continue
		var choice: int = posmod(block["seed"], 100)
		var zone := "Residential"
		for zone_type in region_zone_types():
			choice -= int(neighborhood.zone_shares[zone_type])
			if choice < 0:
				zone = zone_type
				break
		var density: int = neighborhood.zone_density[zone]
		if block_id < neighborhood.block_zoning.size() and neighborhood.block_zoning[block_id] > 0:
			var code: int = neighborhood.block_zoning[block_id] - 1
			zone = region_zone_types()[floori(float(code) / 3.0)]
			density = code % 3
		var area: float = block.get("area_ha", 1.0)
		var weight: float = (float(RegionGenerator.HOUSING_YIELDS.get(zone, [0, 0, 0])[density]) + 0.1) * area
		var jobs: float = (float(RegionGenerator.JOB_YIELDS.get(zone, [0, 0, 0])[density]) + 0.1) * area
		blocks.append({"node": node_id, "weight": weight, "jobs": jobs})
		total_weight += weight
		total_jobs += jobs
	var free_minutes := 0.0
	for block in blocks:
		var weight: float = block["weight"] / maxf(1.0, total_weight)
		var jobs: float = block["jobs"] / maxf(1.0, total_jobs)
		for edge in Paths.path(record["tree"], block["node"], layout.edges):
			free_minutes += record["base_costs"][edge.x] * weight
			weights[edge.x] += Vector2(0.0, weight) if edge.y == 0 else Vector2(weight, 0.0)
			job_weights[edge.x] += Vector2(0.0, jobs) if edge.y == 0 else Vector2(jobs, 0.0)
	record["free_minutes"] = free_minutes
	record["weights"] = weights
	record["job_weights"] = job_weights
	var largest := 0.0
	var total := 0.0
	var job_total := 0.0
	for edge_id in range(weights.size()):
		if layout.classes[edge_id] == Roads.LOCAL:
			largest = maxf(largest, weights[edge_id].x + weights[edge_id].y)
			largest = maxf(largest, job_weights[edge_id].x + job_weights[edge_id].y)
			total += weights[edge_id].x + weights[edge_id].y
			job_total += job_weights[edge_id].x + job_weights[edge_id].y
	record["largest_weight"] = largest
	record["weight_sum"] = total
	record["home_weight_sum"] = total
	record["job_weight_sum"] = job_total


static func region_zone_types() -> Array:
	return ["Residential", "Commercial", "Office", "Mixed", "Industry"]


static func _reroute(neighborhood, record: Dictionary) -> void:
	var costs: PackedFloat32Array = record["base_costs"].duplicate()
	var queues: PackedVector2Array = record["queues"]
	for edge_id in range(costs.size()):
		costs[edge_id] += (queues[edge_id].x + queues[edge_id].y) * 30.0 / record["capacity"]
	record["tree"] = Paths.tree(record["adjacency"], costs, record["portals"])
	_build_weights(neighborhood, record)


static func copy_districts(districts: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for neighborhood_id in districts:
		result[neighborhood_id] = districts[neighborhood_id].duplicate()
		result[neighborhood_id]["queues"] = districts[neighborhood_id]["queues"].duplicate()
		result[neighborhood_id]["served"] = districts[neighborhood_id]["served"].duplicate()
	return result
