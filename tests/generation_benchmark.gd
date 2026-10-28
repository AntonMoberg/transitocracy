extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var seed_value:=8752568
	var cities:=256
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="): seed_value=int(arg.trim_prefix("seed="))
		if arg.begins_with("cities="): cities=int(arg.trim_prefix("cities="))
	var progress=preload("res://scripts/simulation/generation_progress.gd").new()
	var start:=Time.get_ticks_usec()
	var result=preload("res://scripts/simulation/region_setup.gd").build(seed_value,cities,.1,progress)
	var elapsed:=(Time.get_ticks_usec()-start)/1000000.0
	progress.report("Complete")
	print("Generation seed=%d cities=%d: %.3f seconds; stages_us=%s"%[seed_value,cities,elapsed,progress.status().timings])
	if not result.errors.is_empty(): push_error(str(result.errors))
	quit(0 if result.errors.is_empty() else 1)
