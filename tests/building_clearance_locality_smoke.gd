extends SceneTree
const Inventory=preload("res://scripts/simulation/building_inventory.gd")

func _initialize() -> void:
	var region=preload("res://scripts/simulation/region_data.gd").new()
	var n=preload("res://scripts/simulation/neighborhood_data.gd").new()
	n.id=0; n.city_id=0; n.character_profile="Fine Grain"
	n.zone_shares={"Residential":100,"Commercial":0,"Mixed":0,"Office":0,"Industry":0}
	n.zone_density={"Residential":1,"Commercial":1,"Mixed":1,"Office":1,"Industry":1}
	n.street_layout=preload("res://scripts/simulation/street_layout.gd").new()
	n.street_layout.bounds=Rect2(0,0,.16,.11)
	n.street_layout.blocks=[{"polygon":Inventory._bounds_polygon(n.street_layout.bounds),"seed":42,"park":false,"phase":1}]
	var road:=PackedVector2Array()
	for i in range(4001):
		var x:float=(i-2000)*.1
		road.append(Vector2(x,.008+sin(x)*.002))
	for i in range(4000,-1,-1):
		var x:float=(i-2000)*.1
		road.append(Vector2(x,.016+sin(x)*.002))
	region.road_reservations.append({"bounds":Inventory.Geography._bounds(road),"masks":[road],"clearance_masks":[road]})
	var started:=Time.get_ticks_usec()
	var full:=Inventory.generate(n,null,[road])
	var full_us:=Time.get_ticks_usec()-started
	started=Time.get_ticks_usec()
	var local:=Inventory.masks_for(region,n.street_layout)
	var compact:=Inventory.generate(n,null,local)
	var compact_us:=Time.get_ticks_usec()-started
	var errors:=PackedStringArray()
	var land=preload("res://scripts/simulation/road_land.gd")
	var land_masks=land.masks_for_bounds(region,n.street_layout.bounds)
	var block:PackedVector2Array=n.street_layout.blocks[0].polygon
	var original_area:=0.0
	var local_area:=0.0
	for polygon in Geometry2D.intersect_polygons(block,road): original_area+=land._area(polygon)
	for mask in land_masks:
		for polygon in Geometry2D.intersect_polygons(block,mask): local_area+=land._area(polygon)
	if absf(original_area-local_area)>0.00000001: errors.append("Local land masks changed reserved parcel area")
	if compact.size()!=full.size(): errors.append("Local clearance changed the building count")
	var vertices:=0
	for mask in local: vertices+=mask.size()
	if vertices>=100: errors.append("Long corridor was not clipped to the district")
	for i in range(mini(full.size(),compact.size())):
		if full[i].id!=compact[i].id or full[i].housing!=compact[i].housing or full[i].jobs!=compact[i].jobs:
			errors.append("Local clearance changed building identity/capacity")
		for polygon in compact[i].footprints:
			if Inventory.overlaps(polygon,[road]): errors.append("Building overlaps the original full road corridor")
	print("Building clearance: full %d vertices / %.2f ms; local %d vertices / %.2f ms"%[road.size(),full_us/1000.0,vertices,compact_us/1000.0])
	if not errors.is_empty(): push_error("; ".join(errors))
	quit(1 if not errors.is_empty() else 0)
