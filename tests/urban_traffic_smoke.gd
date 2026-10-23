extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Traffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const Local = preload("res://scripts/simulation/local_street_traffic.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var setup: Dictionary = Setup.build(1729, 256, 0.1)
	var region = setup["region"]
	var state = setup["traffic_state"]
	var profile = setup["flow"]
	var start: int = state.unix_seconds
	var one_step = Traffic.fork_for_week(state)
	var chunks = Traffic.fork_for_week(state)
	for probe in [one_step, chunks]:
		for record in probe.local_districts.values():
			record["capacity"] = 0.001
	Local.advance_to(region, profile, one_step, start + 900)
	for offset in range(60, 901, 60):
		Local.advance_to(region, profile, chunks, start + offset)
	var queue_total := 0.0
	for neighborhood_id in one_step.local_districts:
		var whole: Dictionary = one_step.local_districts[neighborhood_id]
		var split: Dictionary = chunks.local_districts[neighborhood_id]
		queue_total += whole["queued"]
		_check(absf(whole["queued"] - split["queued"]) < 0.01, "local queue integration must not depend on frame batching: %.4f vs %.4f" % [whole["queued"], split["queued"]])
		_check(absf(whole["entered"] - whole["discharged"] - whole["queued"]) < 0.01, "congested local queues must conserve flow")
		_check(state.local_districts[neighborhood_id]["entered"] == 0.0, "forked local traffic must not mutate live counters")
	_check(queue_total > 1.0, "capacity-limited streets must build real queues")
	var before: Dictionary = Local.copy_districts(one_step.local_districts)
	Traffic.change_mode(region, profile, one_step, Traffic.MINUTE, Traffic.DAY)
	Traffic.change_mode(region, profile, one_step, Traffic.DAY, Traffic.MINUTE)
	_check(one_step.local_clock == start + 900 and one_step.local_districts[0]["queues"] == before[0]["queues"], "zoom and simulation mode changes must preserve local queues")
	var layout = region.neighborhoods[0].street_layout
	var congested_edge := -1
	var record: Dictionary = one_step.local_districts[0]
	for edge_id in range(layout.edges.size()):
		if Local.edge_rate(record, edge_id).length() > 0.0 and layout.classes[edge_id] == "Local":
			congested_edge = edge_id
			break
	_check(congested_edge >= 0, "actual neighborhood trips must reach local streets")
	if congested_edge >= 0:
		var old_weights: PackedVector2Array = record["weights"].duplicate()
		var queues: PackedVector2Array = record["queues"]
		queues[congested_edge] = Vector2(1000000, 1000000)
		record["queues"] = queues
		Local._reroute(region.neighborhoods[0], record)
		_check(record["weights"] != old_weights, "hourly local routing must react to queued delay and use alternatives")
	if failures == 0:
		print("Congested local flow, conservation, batching, mode invariance, and alternatives passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
