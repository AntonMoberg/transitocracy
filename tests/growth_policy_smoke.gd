extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Budget = preload("res://scripts/simulation/development_budget.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var result: Dictionary = Setup.build(8752568, 32, 0.10)
	var region = result["region"]
	var target_city := -1
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) >= 0 or int(candidate["frontage_link_id"]) < 0:
			continue
		var city_id: int = candidate["city_id"]
		var established: Array = []
		for neighborhood_id in region.cities[city_id]["neighborhood_ids"]:
			var neighborhood = region.neighborhoods[neighborhood_id]
			if neighborhood.street_layout != null and neighborhood.development_approved:
				established.append(neighborhood.street_layout.polygon)
		if Geography.polygon_area(candidate["polygon"]) >= 0.18 and Planner._adjacency_score(candidate["polygon"], established) > 0.0 and Planner._can_expand_to(region, city_id, candidate["polygon"], established):
			target_city = city_id
			break
	if target_city < 0:
		_fail("Generated cities had no road-connected adjacent growth candidate.")
		return
	for city_id in range(region.cities.size()):
		var city: Dictionary = region.cities[city_id]
		city["growth_policy"]["enabled"] = city_id == target_city
		region.cities[city_id] = city
	for neighborhood_id in region.cities[target_city]["neighborhood_ids"]:
		var neighborhood = region.neighborhoods[neighborhood_id]
		neighborhood.housing_capacity = maxi(1, neighborhood.households)
		neighborhood.job_capacity = maxi(1, neighborhood.jobs)
	var treasury = region.jurisdictions[region.city_jurisdiction_ids[target_city]]
	treasury.treasury = 1000000
	var before_count: int = region.neighborhoods.size()
	var before_funds: int = treasury.treasury
	var first_of_month: int = floori(float(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 11, "day": 1})) / 86400.0)
	if not Planner.advance_growth_policies(region, first_of_month):
		_fail("Enabled growth policy did not approve an adjacent plan under high demand.")
		return
	if region.neighborhoods.size() != before_count + 1 or treasury.treasury >= before_funds or before_funds - treasury.treasury > 100000:
		_fail("Growth policy did not respect the one-project, 10%% allowance limit.")
		return
	if not region.cities[target_city]["neighborhood_ids"].has(before_count):
		_fail("Growth policy lost ownership of the new neighborhood.")
		return
	if Planner.advance_growth_policies(region, first_of_month) or region.neighborhoods.size() != before_count + 1:
		_fail("Growth policy approved more than one project in a month.")
		return
	var approved = region.neighborhoods[before_count]
	var reserved_before: int = approved.development_plan.reserved
	if approved.development_plan.reserved < Budget.remaining_cost(approved):
		var next_month: int = floori(float(Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 12, "day": 1})) / 86400.0)
		Planner.advance_growth_policies(region, next_month)
		if region.neighborhoods.size() != before_count + 1 or approved.development_plan.reserved <= reserved_before:
			_fail("Growth policy started another district before funding its active project.")
			return
	print("Default city growth policy approved one funded, adjacent plan and respected its monthly limit.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
