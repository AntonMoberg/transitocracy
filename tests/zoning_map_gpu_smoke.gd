extends SceneTree
const Setup = preload("res://scripts/simulation/region_setup.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")
var errors: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Zoning visibility requires GPU readback")
		quit(1)
		return
	root.size = Vector2i(1280,800)
	root.content_scale_size = root.size
	var region = Setup.build(1729,256,.1).region
	var proposal := -1
	for candidate in region.development_candidates:
		if candidate.neighborhood_id<0 and candidate.frontage_link_id>=0:
			proposal = candidate.id
			break
	if proposal<0:
		push_error("No suggested development district")
		quit(1)
		return
	var candidate: Dictionary = region.development_candidates[proposal]
	var map := RegionMap.new()
	root.add_child(map)
	map.size = Vector2(1280,800)
	map.set_region(region)
	for ppk in [1.5,8.0,40.0,80.0]:
		map.zoom = maxf(1,ppk/map._map_scale())
		map.pan = -(candidate.center_km-map._world_center())*map._map_scale()*map.zoom
		if ppk==40:
			# Exercise an offset camera, rather than only centered suggestions.
			map.pan += Vector2(110,-65)
		if ppk==80:
			# A fractional zoom within a bake band must use the same live
			# positions for suggestion outlines, street previews and picking.
			map.zoom *= 1.025
		map.set_map_mode("Roads")
		await process_frame
		await process_frame
		var deadline := Time.get_ticks_msec()+15000
		while (not map.chunk_renderer.is_settled() or map.terrain_texture==null or map.terrain_detail_level>=0 and map.terrain_detail_published_level!=map.terrain_detail_level) and Time.get_ticks_msec()<deadline:
			await create_timer(.01).timeout
		var roads: Image = await _capture()
		map.set_map_mode("Zoning")
		var zoning: Image = await _capture()
		var changed := _changed(map,candidate,roads,zoning)
		print("Zoning pixels ppk=%s changed=%d overlay=%.2f ms candidates=%d" % [ppk,changed,map.last_overlay_us/1000.0,region.development_candidates.size()])
		_check(changed>=8,"suggestion must become visible when switching to Zoning at %s ppk"%ppk)
		zoning.save_png("user://zoning_visibility_%d.png"%ppk)
		_check(map._visible_zoning_candidate_at(candidate.center_km)==proposal,"visible suggestion must remain clickable")
		map.set_map_mode("Roads")
		var restored: Image = await _capture()
		var remaining := _changed(map,candidate,roads,restored)
		print("Restored map ppk=%s changed=%d" % [ppk,remaining])
		_check(remaining<8,"suggestion must disappear in normal map mode at %s ppk"%ppk)
		if ppk==80:
			map.set_map_mode("Zoning")
			map.set_selected_candidate(proposal)
			var selected: Image = await _capture()
			_check(_changed(map,candidate,zoning,selected)>=8,"selected suggestion must show its highlight and street preview")
			map.set_selected_candidate(-1)
	print("GPU zoning suggestion visibility: ","PASS" if errors.is_empty() else errors)
	map.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)
func _capture() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
func _changed(map,candidate:Dictionary,before:Image,after:Image) -> int:
	var center: Vector2 = map._world_to_screen(candidate.center_km)
	var rect := Rect2(center,Vector2.ZERO)
	for point in candidate.polygon:
		rect = rect.expand(map._world_to_screen(point))
	rect = rect.grow(7).intersection(Rect2(0,0,1280,800))
	var count := 0
	for y in range(ceili(rect.position.y),floori(rect.end.y)):
		for x in range(ceili(rect.position.x),floori(rect.end.x)):
			var a := before.get_pixel(x,y)
			var b := after.get_pixel(x,y)
			if Vector3(a.r-b.r,a.g-b.g,a.b-b.b).length()>.035: count+=1
	return count
func _check(ok:bool,message:String) -> void:
	if not ok: errors.append(message)
