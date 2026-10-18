extends RefCounted

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadGraph = preload("res://scripts/simulation/road_graph.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")
const StreetNetwork = preload("res://scripts/simulation/street_network.gd")
const Spatial = preload("res://scripts/simulation/street_spatial_index.gd")


static func cancel(region, neighborhood_id: int) -> Dictionary:
	if neighborhood_id < 0 or neighborhood_id >= region.neighborhoods.size():
		return {"ok": false, "reason": "Select an approved neighborhood."}
	var neighborhood = region.neighborhoods[neighborhood_id]
	neighborhood.development_approved = false
	neighborhood.migration_remainder = minf(neighborhood.migration_remainder, 0.0)
	neighborhood.job_growth_remainder = minf(neighborhood.job_growth_remainder, 0.0)
	var refund := 0
	if neighborhood.development_plan != null:
		var plan = neighborhood.development_plan
		refund = plan.reserved
		region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]].treasury += refund
		plan.reserved = 0
		plan.active = false
		plan.status = "Cancelled"
	return {"ok": true, "new_neighborhood": false, "refund": refund}


static func allocate(region, neighborhood_id: int, amount: int) -> Dictionary:
	if neighborhood_id < 0 or neighborhood_id >= region.neighborhoods.size():
		return {"ok": false, "reason": "Select an approved neighborhood."}
	var neighborhood = region.neighborhoods[neighborhood_id]
	var plan = neighborhood.development_plan
	if plan == null or not plan.active:
		return {"ok": false, "reason": "Approve this plan before allocating funds."}
	var city = region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]]
	if amount < -plan.reserved or amount > city.treasury:
		return {"ok": false, "reason": "The transfer exceeds available funds."}
	plan.reserved += amount
	city.treasury -= amount
	return {"ok": true}


static func remaining_cost(neighborhood) -> int:
	var plan = neighborhood.development_plan
	if plan == null:
		return 0
	var cost := 0
	for phase in range(maxi(plan.completed_phase, plan.constructing_phase), 3):
		cost += phase_cost(neighborhood, phase + 1)
	return cost + upgrade_cost(neighborhood)


static func upgrade_cost(neighborhood, multiplier: float = -1.0) -> int:
	var plan = neighborhood.development_plan
	var target: float = multiplier if multiplier >= 0.0 else plan.capacity_multiplier
	var installed: float = maxf(plan.installed_multiplier, plan.upgrade_target) if plan.upgrade_open_day >= 0 else plan.installed_multiplier
	var base := 0
	for phase in range(plan.completed_phase):
		base += neighborhood.street_layout.phase_costs[phase]
	var cost: int = roundi(float(base) * maxf(0.0, target - installed) * 0.5)
	if plan.constructing_phase > plan.completed_phase:
		var paid_multiplier: float = maxf(plan.constructing_multiplier, plan.upgrade_target) if plan.upgrade_open_day >= 0 else plan.constructing_multiplier
		cost += roundi(neighborhood.street_layout.phase_costs[plan.constructing_phase - 1] * maxf(0.0, target - paid_multiplier) * 0.5)
	return cost


static func phase_cost(neighborhood, phase: int) -> int:
	return roundi(neighborhood.street_layout.phase_costs[phase - 1] * neighborhood.development_plan.capacity_multiplier)


static func validate_zoning(shares: Dictionary, density: Dictionary) -> String:
	var total := 0
	for zone in ["Residential", "Commercial", "Office", "Mixed", "Industry"]:
		var value: float = float(shares.get(zone, -1))
		if value < 0.0 or value > 100.0 or not is_equal_approx(value, roundf(value)) or int(density.get(zone, -1)) not in [0, 1, 2]:
			return "Use whole percentages from 0 to 100 and a valid density."
		total += int(value)
	if total != 100:
		return "Land-use percentages must total 100%."
	return ""


static func queue_zoning(region, neighborhood_id: int, shares: Dictionary, density: Dictionary, day_key: int) -> Dictionary:
	var reason: String = validate_zoning(shares, density)
	if not reason.is_empty():
		return {"ok": false, "reason": reason}
	if neighborhood_id < 0 or neighborhood_id >= region.neighborhoods.size() or region.neighborhoods[neighborhood_id].development_plan == null:
		return {"ok": false, "reason": "Approve a neighborhood plan first."}
	var neighborhood = region.neighborhoods[neighborhood_id]
	neighborhood.development_plan.pending_zoning = {"shares": shares.duplicate(), "density": density.duplicate()}
	neighborhood.development_plan.zoning_day = day_key + 1
	return {"ok": true}


static func zoning_estimate(neighborhood, shares: Dictionary, density: Dictionary) -> Dictionary:
	var housing := 0
	var jobs := 0
	for zone in shares:
		var area: float = neighborhood.developable_area_ha * float(shares[zone]) / 100.0
		if RegionGenerator.HOUSING_YIELDS.has(zone):
			housing += roundi(area * RegionGenerator.HOUSING_YIELDS[zone][int(density[zone])])
		if RegionGenerator.JOB_YIELDS.has(zone):
			jobs += roundi(area * RegionGenerator.JOB_YIELDS[zone][int(density[zone])])
	var base_demand: float = neighborhood.development_plan.design_demand
	var new_demand: float = float(housing) * 2.0 + float(jobs)
	var multiplier: float = clampf(new_demand / (base_demand * 1.25), 1.0, 3.0)
	var remaining := 0
	for phase in range(maxi(neighborhood.development_plan.completed_phase, neighborhood.development_plan.constructing_phase), 3):
		remaining += roundi(neighborhood.street_layout.phase_costs[phase] * multiplier)
	var next_cost: int = upgrade_cost(neighborhood, multiplier)
	remaining += next_cost
	var next_phase: int = maxi(neighborhood.development_plan.completed_phase, neighborhood.development_plan.constructing_phase) + 1
	if next_cost == 0 and next_phase <= 3:
		next_cost = roundi(neighborhood.street_layout.phase_costs[next_phase - 1] * multiplier)
	return {"housing": housing, "jobs": jobs, "multiplier": multiplier, "remaining": remaining, "next_cost": next_cost, "top_up": maxi(0, remaining - neighborhood.development_plan.reserved)}


static func advance_day(region, day_key: int) -> bool:
	var changed := false
	var rooted: PackedByteArray = RoadGraph.nodes_connected_to_start(region)
	for neighborhood in region.neighborhoods:
		var plan = neighborhood.development_plan
		if plan == null:
			continue
		if not plan.pending_zoning.is_empty() and plan.zoning_day <= day_key:
			_apply_zoning(region, neighborhood)
		if plan.upgrade_open_day >= 0 and plan.upgrade_open_day <= day_key:
			plan.installed_multiplier = maxf(plan.installed_multiplier, plan.upgrade_target)
			plan.upgrade_open_day = -1
			for link in region.road_links:
				if link.managed_neighborhood_id == neighborhood.id:
					link.lanes_per_direction = maxi(link.lanes_per_direction, ceili(plan.installed_multiplier))
			region.road_geometry_revision += 1
			changed = true
		if plan.constructing_phase > 0 and plan.open_day <= day_key:
			changed = StreetNetwork.open_phase(region, neighborhood, plan.constructing_phase) or changed
		if not plan.active:
			plan.status = "Cancelled"
			continue
		var upgrade: int = upgrade_cost(neighborhood)
		if upgrade > 0:
			if plan.reserved < upgrade:
				plan.status = "Awaiting upgrade funds"
				continue
			plan.reserved -= upgrade
			plan.spent += upgrade
			plan.upgrade_target = plan.capacity_multiplier
			plan.upgrade_open_day = day_key + 2
		if plan.upgrade_open_day >= 0:
			plan.status = "Upgrading streets"
			continue
		if plan.completed_phase == 3:
			plan.status = "Completed"
			if plan.reserved > 0:
				region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]].treasury += plan.reserved
				plan.reserved = 0
			continue
		if plan.constructing_phase > 0:
			plan.status = "Constructing phase %d" % plan.constructing_phase
			continue
		var connected := false
		if plan.completed_phase == 0:
			for local_id in neighborhood.street_layout.arterial_nodes:
				var point: Vector2 = neighborhood.street_layout.nodes[local_id]
				for link_index in Spatial.near_links(region, point):
					var link = region.road_links[link_index]
					if link.road_class == Roads.ARTERIAL and link.from_node_id < rooted.size() and link.to_node_id < rooted.size() and rooted[link.from_node_id] != 0 and rooted[link.to_node_id] != 0 and RoadPlanner.closest_point(link.points, point).distance_to(point) < 0.02:
						connected = true
						break
				if connected:
					break
		else:
			for access_id in neighborhood.access_node_ids:
				if access_id < rooted.size() and rooted[access_id] != 0:
					connected = true
		if not connected:
			plan.status = "Awaiting road access"
			continue
		var capacity: float = float(plan.target_housing + plan.target_jobs) * plan.serviced_fraction()
		if plan.completed_phase > 0 and float(neighborhood.households + neighborhood.jobs) < capacity * 0.60:
			plan.status = "Awaiting demand"
			continue
		var next_phase: int = plan.completed_phase + 1
		var cost: int = phase_cost(neighborhood, next_phase)
		if plan.reserved < cost:
			plan.status = "Awaiting funds"
			continue
		plan.reserved -= cost
		plan.spent += cost
		plan.constructing_phase = next_phase
		plan.constructing_multiplier = plan.capacity_multiplier
		plan.open_day = day_key + 2
		plan.status = "Constructing phase %d" % next_phase
	if changed:
		RoadPlanner.refresh_upkeep(region)
	return changed


static func _apply_zoning(region, neighborhood) -> void:
	var plan = neighborhood.development_plan
	var shares: Dictionary = plan.pending_zoning["shares"]
	var density: Dictionary = plan.pending_zoning["density"]
	var estimate: Dictionary = zoning_estimate(neighborhood, shares, density)
	var template = preload("res://scripts/simulation/neighborhood_data.gd").new()
	template.developable_area_ha = neighborhood.developable_area_ha
	template.zone_shares = shares.duplicate()
	template.zone_density = density.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = region.generation_seed + neighborhood.id * 7919
	RegionGenerator._populate_capacity_and_occupancy(template, rng, 0)
	neighborhood.zone_shares = shares.duplicate()
	neighborhood.zone_density = density.duplicate()
	neighborhood.housing_capacity = maxi(neighborhood.households, estimate["housing"])
	neighborhood.job_capacity = maxi(neighborhood.jobs, estimate["jobs"])
	plan.target_housing = estimate["housing"]
	plan.target_jobs = estimate["jobs"]
	plan.capacity_multiplier = estimate["multiplier"]
	plan.target_jobs_by_skill = template.jobs_by_skill.duplicate()
	neighborhood.development_jobs_by_skill = template.jobs_by_skill.duplicate()
	neighborhood.development_retail_share = template.shopping_attraction / maxf(1.0, float(template.jobs))
	plan.pending_zoning.clear()
	plan.zoning_day = -1
	var needed: int = remaining_cost(neighborhood)
	if plan.reserved > needed:
		var refund: int = plan.reserved - needed
		plan.reserved = needed
		region.jurisdictions[region.city_jurisdiction_ids[neighborhood.city_id]].treasury += refund
