extends SceneTree
const Inventory=preload("res://scripts/simulation/building_inventory.gd")
const Region=preload("res://scripts/simulation/region_data.gd")
const Neighborhood=preload("res://scripts/simulation/neighborhood_data.gd")
const Layout=preload("res://scripts/simulation/street_layout.gd")
const Plan=preload("res://scripts/simulation/development_plan.gd")
const Snapshot=preload("res://scripts/simulation/region_snapshot.gd")
var errors:Array[String]=[]
func _initialize() -> void:
	var region=Region.new()
	region.cities.append({"center_km":Vector2.ZERO})
	var n=Neighborhood.new()
	n.id=0; n.city_id=0; n.development_approved=true; n.desirability=58
	n.character_profile="Fine Grain"
	n.zone_shares={"Residential":100,"Commercial":0,"Mixed":0,"Office":0,"Industry":0}
	n.zone_density={"Residential":1,"Commercial":1,"Mixed":1,"Office":1,"Industry":1}
	n.development_plan=Plan.new(); n.development_plan.completed_phase=3
	n.street_layout=Layout.new()
	n.street_layout.bounds=Rect2(0,0,.16,.11)
	n.street_layout.blocks=[{"polygon":PackedVector2Array([Vector2.ZERO,Vector2(.16,0),Vector2(.16,.11),Vector2(0,.11)]),"seed":42,"park":false,"phase":1}]
	region.neighborhoods.append(n)
	Inventory.rebuild(region,n)
	_check(not n.buildings.is_empty() and n.housing_capacity==0,"planned buildings are not completed capacity")
	for b in n.buildings:
		_check(b.housing==1 and b.floors==2,"row house has one home and two floors")
		for polygon in b.footprints:
			var box:=Inventory.Geography._bounds(polygon)
			_check(box.size.y<=.0201 and box.size.y>=.0149,"row-house depth is 15–20 m")
	Inventory.advance_day(region,n,true)
	_check(n.buildings.any(func(b):return b.state=="Constructing"),"empty serviced districts can start construction")
	_check(n.housing_capacity==0,"construction does not add capacity early")
	region.current_day_key=7
	Inventory.advance_day(region,n,true)
	_check(n.housing_capacity>0,"completed buildings supply capacity")
	n.households=mini(2,n.housing_capacity)
	Inventory.allocate_occupancy(n)
	var occupied:=0
	for b in n.buildings: occupied+=b.occupied_homes
	_check(occupied==n.households,"building occupancy sums to neighborhood occupancy")
	var revision:int=n.building_geometry_revision
	n.households=0; Inventory.allocate_occupancy(n)
	_check(revision==n.building_geometry_revision,"vacancy changes do not rebuild map geometry")
	var capacity:int=n.housing_capacity
	var completed:Array=n.buildings.filter(func(b):return b.state=="Complete")
	n.zone_density.Residential=2
	Inventory.rebuild(region,n)
	_check(n.housing_capacity==capacity,"rezoning does not create capacity or demolish completed houses")
	for b in completed:
		_check(n.buildings.any(func(other):return other.id==b.id and other.footprints==b.footprints and other.state=="Complete"),"rezoning preserves existing footprints")
	var copy=Snapshot.copy_region(region)
	copy.neighborhoods[0].buildings[0].state="Planned"
	_check(n.buildings[0].state!="Planned","snapshots detach mutable building state")
	var mask:=PackedVector2Array([Vector2(0,0),Vector2(.16,0),Vector2(.16,.012),Vector2(0,.012)])
	for b in Inventory.generate(n,null,[mask]):
		for polygon in b.footprints: _check(not Inventory.overlaps(polygon,[mask]),"buildings exclude road clearance")
	var mixed:Dictionary={"Residential":0,"Commercial":0,"Mixed":100,"Office":0,"Industry":0}
	for b in Inventory.generate(n,null,[],mixed):
		var area:=0.0
		for polygon in b.footprints: area+=Inventory.Geography.polygon_area(polygon)*1000000.0
		_check(b.housing==floori(area*(b.floors-1)*.8/80.0) and b.jobs==floori(area*.8/20.0),"mixed-use ground-floor jobs and upstairs housing use floor area")
	n.street_layout.nodes=PackedVector2Array([Vector2.ZERO,Vector2(.16,0),Vector2(0,.11),Vector2(.16,.11)])
	n.street_layout.edges=PackedVector2Array([Vector2(0,1),Vector2(2,3)])
	n.street_layout.phases=PackedInt32Array([1,2])
	n.street_layout.blocks[0].phase=2
	var frontage:=Inventory.generate(n)
	_check(frontage.any(func(b):return b.phase==1) and frontage.any(func(b):return b.phase==2),"construction follows each building's frontage street rather than the entire block's last phase")
	print("Building inventory: ","PASS" if errors.is_empty() else errors)
	quit(0 if errors.is_empty() else 1)
func _check(value:bool,message:String) -> void:
	if not value: errors.append(message)
