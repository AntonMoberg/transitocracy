extends SceneTree
var errors:=PackedStringArray()
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var main=preload("res://tests/ui_fixture.gd").FixtureMain.new()
	main.fixture_size=1
	root.add_child(main)
	await process_frame
	if not is_instance_valid(main.generation_overlay) or not main.generation_overlay.visible:
		errors.append("Loading screen missing on first frame")
	elif main.generation_overlay.z_index<=200 or main.generation_overlay.size!=main.size:
		errors.append("Loading screen does not cover map layers")
	var deadline:=Time.get_ticks_msec()+180000
	var preview_seen:=false
	var worst:=0.0
	while (main.generation_start_pending or main.generation_thread!=null or main.generation_render_pending) and Time.get_ticks_msec()<deadline:
		var start:=Time.get_ticks_usec()
		await process_frame
		worst=maxf(worst,(Time.get_ticks_usec()-start)/1000.0)
		if Time.get_ticks_usec()-start>50000:
			print("Startup slow frame: %.2f ms, %s"%[(Time.get_ticks_usec()-start)/1000.0,main.generation_progress.status().stage])
		var status:Dictionary=main.generation_progress.status()
		if status.failed:
			errors.append(status.stage)
			break
		if status.revision>1 and not preview_seen:
			preview_seen=true
			await RenderingServer.frame_post_draw
			var captured:=root.get_texture().get_image()
			captured.save_png("user://startup_preview.png")
			var color:=captured.get_pixel(captured.get_width()/3,captured.get_height()*2/3)
			if color.get_luminance()>.5: errors.append("Uncovered map rendered over loading preview")
	if Time.get_ticks_msec()>=deadline: errors.append("Startup timed out")
	if not preview_seen: errors.append("Growing preview never appeared")
	if main.region==null or main.map_view.terrain_base_textures.is_empty(): errors.append("Startup revealed incomplete map")
	main.playing=false
	main.generation_progress=preload("res://scripts/simulation/generation_progress.gd").new()
	main.generation_overlay=preload("res://scripts/ui/generation_overlay.gd").new()
	main.generation_overlay.reporter=main.generation_progress
	main.generation_overlay.can_return=true
	main.add_child(main.generation_overlay)
	var before=main.region
	main._generation_failed("Regression failure")
	await process_frame
	if not main.generation_overlay.actions.visible or main.region!=before: errors.append("Failure recovery lost the world or controls")
	main._dismiss_generation_failure()
	await process_frame
	print("Startup UI: worst frame %.2f ms; preview saved to %s"%[worst,ProjectSettings.globalize_path("user://startup_preview.png")])
	if not errors.is_empty(): push_error(str(errors))
	quit(0 if errors.is_empty() else 1)
