extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const MultiScaleDay = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var setup: Dictionary = Setup.build(1729, 32, 0.1)
	var source = setup["region"]
	var original_day: int = source.current_day_key
	var next_day: int = original_day + 1
	var serial: Dictionary = MultiScaleDay.advance_day(RegionSnapshot.copy_region(source), next_day, setup["flow"], MultiScaleTraffic.fork_for_week(setup["traffic_state"]))
	var worker := Thread.new()
	var status: Error = worker.start(Callable(MultiScaleDay, "advance_day").bind(RegionSnapshot.copy_region(source), next_day, setup["flow"], MultiScaleTraffic.fork_for_week(setup["traffic_state"])))
	if status != OK:
		push_error("Could not start the daily simulation worker")
		quit(1)
		return
	var parallel: Dictionary = worker.wait_to_finish()
	var same: bool = source.current_day_key == original_day and parallel["region"].current_day_key == next_day
	same = same and serial["summary_stats"] == parallel["summary_stats"]
	same = same and serial["flow"].hourly_trips == parallel["flow"].hourly_trips
	same = same and serial["region"].accessibility == parallel["region"].accessibility
	if not same:
		push_error("Daily simulation differs between a worker and the main thread, or changed the live region")
		quit(1)
		return
	print("Detached worker and serial daily simulation agree.")
	quit(0)
