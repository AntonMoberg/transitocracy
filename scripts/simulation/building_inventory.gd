extends RefCounted
## Buildings are simulation data. The camera only consumes their geometry.
const Parcels=preload("res://scripts/simulation/parcel_geometry.gd")
const Geography=preload("res://scripts/simulation/state_geography.gd")
const Section=preload("res://scripts/simulation/street_cross_section.gd")
const ZONES=["Residential","Commercial","Office","Mixed","Industry"]

static func overlaps(polygon:PackedVector2Array,masks:Array,mask_bounds:Array=[]) -> bool:
	var bounds:=Geography._bounds(polygon)
	for i in range(masks.size()):
		var mask:PackedVector2Array=masks[i]
		if not bounds.intersects(mask_bounds[i] if not mask_bounds.is_empty() else Geography._bounds(mask)): continue
		for piece in Geometry2D.intersect_polygons(polygon,mask):
			if Geography.polygon_area(piece)>.00000001: return true
	return false

static func masks_for(region,layout) -> Array:
	var masks:Array=[]
	var extent:Rect2=layout.bounds.grow(.08)
	for road in region.road_links:
		if not Geography._bounds(road.points).intersects(extent): continue
		for i in range(1,road.points.size()):
			if not Rect2(road.points[i-1],Vector2.ZERO).expand(road.points[i]).intersects(extent): continue
			var middle:Vector2=(road.points[i-1]+road.points[i])*.5
			var separated:=false
			for span in road.terrain_spans:
				if span.kind not in ["Bridge","Tunnel"]: continue
				var path:PackedVector2Array=span.get("points",PackedVector2Array([span.from,span.to]))
				for j in range(1,path.size()):
					if middle.distance_to(Geometry2D.get_closest_point_to_segment(middle,path[j-1],path[j]))<.001: separated=true; break
			if not separated: masks.append_array(Section.exclusion(PackedVector2Array([road.points[i-1],road.points[i]]),road.road_class,road.lanes_per_direction))
	for edge_id in range(layout.edges.size()):
		if layout.closed_edges.has(edge_id) or layout.grade_separated_edges.has(edge_id): continue
		var edge:Vector2=layout.edges[edge_id]
		var path:PackedVector2Array=layout.edge_paths.get(edge_id,PackedVector2Array([layout.nodes[int(edge.x)],layout.nodes[int(edge.y)]]))
		masks.append_array(Section.exclusion(path,layout.classes[edge_id]))
	for reservation in region.road_reservations:
		if reservation.bounds.intersects(extent):
			for mask in reservation.get("clearance_masks",reservation.masks):
				var bounds:=Geography._bounds(mask)
				if not bounds.intersects(extent): continue
				# A reservation may describe hundreds of kilometres of road.
				# Clip it once to this district before testing individual houses.
				if extent.encloses(bounds): masks.append(mask)
				else: masks.append_array(Geometry2D.intersect_polygons(mask,_bounds_polygon(extent)))
	return masks

static func _bounds_polygon(bounds:Rect2) -> PackedVector2Array:
	return PackedVector2Array([bounds.position,Vector2(bounds.end.x,bounds.position.y),bounds.end,Vector2(bounds.position.x,bounds.end.y)])

static func zone_for(block:Dictionary,shares:Dictionary) -> String:
	var choice:int=posmod(int(block.seed),100)
	for zone in ZONES:
		choice-=int(shares.get(zone,0))
		if choice<0: return zone
	return "Residential"

static func template(zone:String,density:int,character:String) -> Dictionary:
	var kind:="Row house"
	var floors:int=2 if density<2 else 4
	var days:=7
	if character=="Garden": kind="Detached house"; floors=1 if density==0 else 2
	if density==2: kind="Apartment"; floors=4; days=14
	if character=="Courtyard": kind="Courtyard apartment"; floors=[3,5,8][density]; days=21
	if zone=="Commercial": kind="Shop"; floors=[1,2,3][density]; days=14
	if zone=="Mixed": kind="Mixed use"; floors=[2,3,5][density]; days=14
	if zone=="Office": kind="Office"; floors=[2,4,8][density]; days=30
	if zone=="Industry": kind="Industry"; floors=1 if density<2 else 2; days=30
	return {"type":kind,"floors":floors,"days":days}

static func generate(n,terrain=null,masks:Array=[],shares:Dictionary={},densities:Dictionary={},timings:Dictionary={}) -> Array[Dictionary]:
	var parcels_us:=0
	var clearance_us:=0
	var frontage_us:=0
	var clip_calls:=0
	var max_fragments:=0
	var result:Array[Dictionary]=[]
	if n.street_layout==null: return result
	if shares.is_empty(): shares=n.zone_shares
	if densities.is_empty(): densities=n.zone_density
	var mask_bounds:Array[Rect2]=[]
	for mask in masks: mask_bounds.append(Geography._bounds(mask))
	var frontage_edges:Array=[]
	var layout=n.street_layout
	for edge_id in range(layout.edges.size()):
		if layout.closed_edges.has(edge_id) or layout.grade_separated_edges.has(edge_id): continue
		var edge:Vector2=layout.edges[edge_id]
		var path:PackedVector2Array=layout.edge_paths.get(edge_id,PackedVector2Array([layout.nodes[int(edge.x)],layout.nodes[int(edge.y)]]))
		frontage_edges.append({"points":path,"bounds":Geography._bounds(path).grow(.05),"phase":layout.phases[edge_id]})
	for block_id in range(n.street_layout.blocks.size()):
		var block:Dictionary=n.street_layout.blocks[block_id]
		if block.park or block.get("demolished",false): continue
		var block_bounds:=Geography._bounds(block.polygon)
		var nearby_masks:Array=[]
		var nearby_bounds:Array[Rect2]=[]
		var nearby_edges:Array=frontage_edges.filter(func(edge):return edge.bounds.intersects(block_bounds))
		for mask_id in range(masks.size()):
			if block_bounds.intersects(mask_bounds[mask_id]):
				nearby_masks.append(masks[mask_id])
				nearby_bounds.append(mask_bounds[mask_id])
		var zone:=zone_for(block,shares)
		var density:int=densities[zone]
		var spec:=template(zone,density,n.character_profile)
		var part_started:=Time.get_ticks_usec()
		var parcels:=Parcels.parcels(block,zone,density,n.character_profile,terrain)
		parcels_us+=Time.get_ticks_usec()-part_started
		for parcel in parcels:
			part_started=Time.get_ticks_usec()
			var pieces:Array=[]
			for polygon in parcel.buildings:
				var polygon_bounds:=Geography._bounds(polygon)
				var local_masks:Array=[]
				var local_bounds:Array[Rect2]=[]
				for mask_id in range(nearby_masks.size()):
					if polygon_bounds.intersects(nearby_bounds[mask_id]):
						local_masks.append(nearby_masks[mask_id])
						local_bounds.append(nearby_bounds[mask_id])
				var fragments:Array=[polygon]
				for mask in local_masks:
					var remaining:Array=[]
					for fragment in fragments:
						clip_calls+=1
						for cut in Geometry2D.clip_polygons(fragment,mask):
							# Clockwise contours are holes: they are road space,
							# not independent building fragments to clip again.
							if not Geometry2D.is_polygon_clockwise(cut): remaining.append(cut)
					fragments=remaining
					max_fragments=maxi(max_fragments,fragments.size())
					if fragments.is_empty(): break
				for fragment in fragments:
					if Geography.polygon_area(fragment)>=maxf(.00004,Geography.polygon_area(polygon)*.65) and not overlaps(fragment,local_masks,local_bounds): pieces.append(fragment)
			clearance_us+=Time.get_ticks_usec()-part_started
			if pieces.is_empty(): continue
			part_started=Time.get_ticks_usec()
			var area:=0.0
			for piece in pieces: area+=Geography.polygon_area(piece)*1000000.0
			var residential_floors:int=spec.floors-(1 if zone=="Mixed" else 0)
			var homes:=0
			if zone in ["Residential","Mixed"]: homes=1 if spec.type in ["Row house","Detached house"] else floori(area*residential_floors*.8/80.0)
			var jobs:=0
			if zone!="Residential": jobs=floori(area*(1 if zone=="Mixed" else spec.floors)*.8/({"Office":15.0,"Industry":50.0}.get(zone,20.0)))
			if homes+jobs==0: continue
			var identity:="%d:%d:%d" % [n.id,int(block.seed),hash(parcel.polygon)]
			var phase:int=block.phase
			var nearest:=INF
			var center:=Geography._bounds(pieces[0]).get_center()
			for edge in nearby_edges:
				for i in range(1,edge.points.size()):
					var distance:float=center.distance_squared_to(Geometry2D.get_closest_point_to_segment(center,edge.points[i-1],edge.points[i]))
					if distance<nearest:
						nearest=distance
						phase=edge.phase
			result.append({"id":identity,"block_id":block_id,"parcel":parcel.polygon,"footprints":pieces,"type":spec.type,"zone":zone,"floors":spec.floors,"housing":homes,"jobs":jobs,"occupied_homes":0,"occupied_jobs":0,"phase":phase,"days":spec.days,"state":"Planned","completion_day":-1})
			frontage_us+=Time.get_ticks_usec()-part_started
	timings["parcels"]=parcels_us
	timings["clearance"]=clearance_us
	timings["frontage"]=frontage_us
	timings["clip_calls"]=clip_calls
	timings["max_fragments"]=max_fragments
	return result

static func serviced_capacity(n) -> Vector2i:
	var capacity:=Vector2i.ZERO
	for b in n.buildings:
		if b.phase<=n.development_plan.completed_phase: capacity+=Vector2i(b.housing,b.jobs)
	return capacity

static func initialize(region) -> void:
	for n in region.neighborhoods:
		if n.street_layout==null: continue
		var home_ratio:float=float(n.households)/maxf(1,n.housing_capacity)
		var job_ratio:float=float(n.jobs)/maxf(1,n.job_capacity)
		var people:float=float(n.population)/maxf(1,n.households)
		rebuild(region,n,true)
		n.households=roundi(n.housing_capacity*clampf(home_ratio,.68,.88)) if n.initially_developed else 0
		set_jobs(n,roundi(n.job_capacity*clampf(job_ratio,.64,.86)) if n.initially_developed else 0)
		n.population=roundi(n.households*maxf(2.0,people))
		allocate_occupancy(n)
		if n.development_plan!=null:
			n.development_plan.design_demand=maxf(1,n.base_housing_capacity*2+n.base_job_capacity)

static func rebuild(region,n,initial:bool=false,preserve_completed:bool=false,timings:Dictionary={}) -> void:
	var started:=Time.get_ticks_usec()
	if n.street_layout==null: return
	var signature:int=hash([n.street_layout.get_instance_id(),n.street_layout.blocks,n.zone_shares,n.zone_density,region.road_geometry_revision,region.road_reservations.size()])
	if not initial and n.building_model_version>0 and signature==n.building_plan_signature: return
	var masks:=masks_for(region,n.street_layout)
	var nearby:Dictionary={}
	var mask_bounds:Array[Rect2]=[]
	for mask in masks: mask_bounds.append(Geography._bounds(mask))
	for block_id in range(n.street_layout.blocks.size()):
		var bounds:=Geography._bounds(n.street_layout.blocks[block_id].polygon)
		var local_masks:Array=[]
		for index in range(masks.size()):
			if bounds.intersects(mask_bounds[index]): local_masks.append(masks[index])
		nearby[block_id]=local_masks
	var old:Dictionary={}
	for b in n.buildings: old[b.id]=b
	timings["building_masks"]=Time.get_ticks_usec()-started
	started=Time.get_ticks_usec()
	var next:=generate(n,region.terrain,masks,{},{},timings)
	timings["building_generate"]=Time.get_ticks_usec()-started
	for b in next:
		if old.has(b.id):
			var previous:Dictionary=old[b.id]
			var intact:bool=preserve_completed or not previous.footprints.any(func(polygon):return overlaps(polygon,nearby[b.block_id]))
			if previous.state=="Complete" and intact:
				var block_id:int=b.block_id
				b.merge(previous,true)
				b.block_id=block_id
			elif previous.footprints==b.footprints:
				b.state=previous.state; b.completion_day=previous.completion_day
		elif initial and n.initially_developed: b.state="Complete"
	var next_ids:Dictionary={}
	for b in next: next_ids[b.id]=true
	for b in n.buildings:
		if next_ids.has(b.id) or b.state!="Complete" or b.block_id>=n.street_layout.blocks.size(): continue
		if n.street_layout.blocks[b.block_id].get("demolished",false): continue
		var safe:=true
		for polygon in b.footprints:
			if not preserve_completed and overlaps(polygon,nearby[b.block_id]): safe=false; break
		if safe:
			next=next.filter(func(candidate):return candidate.parcel!=b.parcel and not overlaps(candidate.parcel,b.footprints))
			next.append(b.duplicate(true))
	n.buildings=next
	n.building_model_version=1
	n.building_geometry_revision+=1
	n.building_plan_signature=signature
	refresh_capacity(n)
	allocate_occupancy(n)

static func refresh_capacity(n) -> void:
	var homes:=0
	var jobs:=0
	var planned_homes:=0
	var planned_jobs:=0
	for b in n.buildings:
		planned_homes+=b.housing; planned_jobs+=b.jobs
		if b.state=="Complete": homes+=b.housing; jobs+=b.jobs
	n.housing_capacity=homes
	n.job_capacity=jobs
	n.base_housing_capacity=planned_homes
	n.base_job_capacity=planned_jobs
	if n.development_plan!=null:
		n.development_plan.target_housing=planned_homes
		n.development_plan.target_jobs=planned_jobs
	var previous_households:int=n.households
	n.households=mini(n.households,homes)
	set_jobs(n,mini(n.jobs,jobs))
	if n.households!=previous_households:
		n.population=roundi(float(n.population)*n.households/maxi(1,previous_households))

static func set_jobs(n,count:int) -> void:
	var old:int=maxi(1,n.jobs)
	var mix:Dictionary=n.jobs_by_skill if n.jobs>0 else n.development_jobs_by_skill
	if n.jobs==0: old=maxi(1,int(mix.get("Entry",0))+int(mix.get("Skilled",0))+int(mix.get("Professional",0)))
	var entry:int=mini(count,roundi(float(mix.get("Entry",0))*count/old))
	var professional:int=mini(count-entry,roundi(float(mix.get("Professional",0))*count/old))
	n.jobs=count
	n.jobs_by_skill={"Entry":entry,"Skilled":count-entry-professional,"Professional":professional}
	n.shopping_attraction=count*n.development_retail_share

static func allocate_occupancy(n) -> void:
	var homes:int=n.households
	var jobs:int=n.jobs
	var changed:=false
	for b in n.buildings:
		var h:int=mini(homes,b.housing) if b.state=="Complete" else 0
		var j:int=mini(jobs,b.jobs) if b.state=="Complete" else 0
		changed=changed or h!=b.occupied_homes or j!=b.occupied_jobs
		b.occupied_homes=h; b.occupied_jobs=j
		homes-=h; jobs-=j
	if changed: n.building_occupancy_revision+=1

static func advance_day(region,n,connected:bool) -> void:
	var changed:=false
	for b in n.buildings:
		if b.state=="Constructing" and b.completion_day<=region.current_day_key:
			b.state="Complete"; changed=true
	if changed:
		n.building_geometry_revision+=1
		refresh_capacity(n)
	if not connected or not n.development_approved: return
	var serviced_h:=0
	var serviced_j:=0
	var committed_h:=0
	var committed_j:=0
	for b in n.buildings:
		if b.phase>n.development_plan.completed_phase: continue
		serviced_h+=b.housing; serviced_j+=b.jobs
		if b.state!="Planned": committed_h+=b.housing; committed_j+=b.jobs
	var factor:float=(.02+.98*exp(-n.position_km.distance_to(region.cities[n.city_id].center_km)/12.0))*clampf(n.desirability/58.0,.3,1.0)
	var desired_h:int=ceili((n.households+serviced_h*.01*factor*14)/.85)
	var desired_j:int=ceili((n.jobs+serviced_j*.01*factor*14)/.80)
	var funded:float=minf(1.0,n.development_plan.installed_multiplier/maxf(1.0,n.development_plan.capacity_multiplier))
	desired_h=mini(desired_h,ceili(serviced_h*funded))
	desired_j=mini(desired_j,ceili(serviced_j*funded))
	for b in n.buildings:
		if b.state!="Planned" or b.phase>n.development_plan.completed_phase: continue
		if (b.housing==0 or committed_h>=desired_h) and (b.jobs==0 or committed_j>=desired_j): continue
		b.state="Constructing"
		b.completion_day=region.current_day_key+b.days
		committed_h+=b.housing; committed_j+=b.jobs
		n.building_geometry_revision+=1
