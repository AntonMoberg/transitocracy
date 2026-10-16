extends SceneTree

const RegionData = preload("res://scripts/simulation/region_data.gd")
const RoadLinkData = preload("res://scripts/simulation/road_link_data.gd")
const RoadTrafficCalculator = preload("res://scripts/simulation/road_traffic_calculator.gd")
const RoadTrafficProfile = preload("res://scripts/simulation/road_traffic_profile.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var region = RegionData.new()
	var link = RoadLinkData.new()
	link.id = 11
	link.length_km = 10.0
	link.road_class = RoadLinkData.ARTERIAL
	link.lanes_per_direction = 1
	region.road_links.append(link)
	var hourly_volumes: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(1800.0, 0.0)]),
		PackedVector2Array([Vector2.ZERO]),
		PackedVector2Array([Vector2(0.0, 450.0)]),
	]
	var result: Dictionary = RoadTrafficCalculator.load_queues(region, hourly_volumes)
	var quarters: Array[PackedVector2Array] = result["quarter_hour_queues"]
	_check(is_equal_approx(quarters[0][0].x, 225.0) and is_equal_approx(quarters[3][0].x, 900.0), "excess directional arrivals must form a queue across quarter hours")
	_check(is_equal_approx(quarters[4][0].x, 675.0) and is_equal_approx(quarters[7][0].x, 0.0), "unused capacity must drain the queue in the following hour")
	_check(quarters[11][0].x == 0.0 and quarters[11][0].y == 0.0, "opposite directions must have independent capacity and queues")
	var served: Array[PackedVector2Array] = result["hourly_served"]
	_check(served[0][0] == Vector2(900.0, 0.0) and served[1][0] == Vector2(900.0, 0.0) and served[2][0] == Vector2(0.0, 450.0), "actual road flow must respect directional capacity and clear queued arrivals")
	_check(is_equal_approx(hourly_volumes[0][0].x + hourly_volumes[1][0].x - served[0][0].x - served[1][0].x, quarters[7][0].x), "each link must conserve vehicles across hours")
	var times: Array[PackedVector2Array] = result["hourly_link_times"]
	_check(times[1][0].x > times[2][0].x and times[1][0].x > times[1][0].y, "a draining queue must continue to delay its direction after new demand falls")
	var profile = RoadTrafficProfile.new()
	profile.initial_queues = result["initial_queues"]
	profile.quarter_hour_queues = quarters
	_check(is_equal_approx(profile.interpolated_queue(0, 1, 0.0).x, 900.0), "the next hour must begin with the previous hour's queue")
	_check(is_equal_approx(profile.interpolated_queue(0, 1, 0.125).x, 787.5), "queue display must interpolate within a quarter hour")
	var next_day: Dictionary = RoadTrafficCalculator.load_queues(region, [PackedVector2Array([Vector2.ZERO])], quarters[3])
	_check(is_equal_approx(next_day["initial_queues"][0].x, 900.0) and is_equal_approx(next_day["end_queues"][0].x, 0.0), "a prior day's queue must carry into and clear during the next day")
	profile.link_ids = PackedInt32Array([11, 12])
	profile.end_queues = PackedVector2Array([Vector2(900.0, 0.0), Vector2(0.0, 30.0)])
	var remapped: PackedVector2Array = RoadTrafficCalculator.carry_queues(PackedInt32Array([12, 13, 11]), profile)
	_check(remapped[0] == Vector2(0.0, 30.0) and remapped[1] == Vector2.ZERO and remapped[2] == Vector2(900.0, 0.0), "road edits must preserve queues on surviving link IDs")
	if failures == 0:
		print("Road queue smoke checks passed.")
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
