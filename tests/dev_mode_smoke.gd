extends SceneTree

const UiFixture = preload("res://tests/ui_fixture.gd")
const RoadPlanner = preload("res://scripts/simulation/road_planner.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const DevelopmentBudget = preload("res://scripts/simulation/development_budget.gd")
const DayCycleCalculator = preload("res://scripts/simulation/day_cycle_calculator.gd")
const RegionData = preload("res://scripts/simulation/region_data.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = await UiFixture.attach_small(self)
	main.playing = false
	var preview: Dictionary = {}
	for link in main.region.road_links:
		preview = RoadPlanner.widen_preview(main.region, link.id, main._current_day_key())
		if preview.get("ok", false) and int(preview["cost"]) > 0:
			break
	_check(preview.get("ok", false), "A road project must be available for the budget check.")
	if preview.is_empty() or not preview.get("ok", false):
		quit(1)
		return
	var owner = main.region.jurisdictions[preview["owner_id"]]
	owner.treasury = -100.0
	main.pending_road_preview = preview
	main._update_road_status()
	_check(main.road_build_button.disabled, "A road with insufficient funds must be blocked in normal mode.")
	main.dev_mode_button.button_pressed = true
	await _wait_for_mode(main, true)
	main._update_road_status()
	_check(main.region.dev_mode and not main.road_build_button.disabled and main.fiscal_label.text.contains("$∞ available"), "Dev Mode must unlock road building and show unlimited available funds.")
	main.dev_mode_button.button_pressed = false
	await _wait_for_mode(main, false)
	main._update_road_status()
	_check(main.road_build_button.disabled and is_equal_approx(owner.treasury, -100.0), "Turning Dev Mode off must restore the ordinary budget gate without changing the treasury.")
	main.dev_mode_button.button_pressed = true
	await _wait_for_mode(main, true)
	var road_result: Dictionary = RoadPlanner.commit(main.region, preview, main._current_day_key())
	_check(road_result.get("ok", false) and is_equal_approx(owner.treasury, -100.0), "Dev Mode must fund a road without debiting its owner.")
	var candidate_id := -1
	for candidate in main.region.development_candidates:
		if candidate["neighborhood_id"] < 0 and candidate["frontage_link_id"] >= 0 and candidate["layout_input"].get("edge_frontage", false):
			candidate_id = candidate["id"]
			break
	_check(candidate_id >= 0, "An arterial frontage candidate must be available for development.")
	if candidate_id >= 0:
		var candidate: Dictionary = main.region.development_candidates[candidate_id]
		var city = main.region.jurisdictions[main.region.city_jurisdiction_ids[candidate["city_id"]]]
		city.treasury = -200.0
		var approval: Dictionary = DevelopmentPlanner.set_approval(main.region, candidate_id, true)
		_check(approval.get("ok", false), "Dev Mode must approve development with an empty city treasury.")
		if approval.get("ok", false):
			var neighborhood = main.region.neighborhoods[candidate["neighborhood_id"]]
			var plan = neighborhood.development_plan
			_check(plan.reserved == 0 and is_equal_approx(city.treasury, -200.0), "Dev Mode approval must avoid creating a refundable reserve or debiting the city.")
			main.dev_mode_button.button_pressed = false
			await _wait_for_mode(main, false)
			DevelopmentBudget.advance_day(main.region, main.region.current_day_key + 1)
			_check(plan.constructing_phase == 0 and plan.status == "Awaiting funds", "Normal funding rules must return when Dev Mode is turned off.")
			main.dev_mode_button.button_pressed = true
			await _wait_for_mode(main, true)
			DevelopmentBudget.advance_day(main.region, main.region.current_day_key + 1)
			_check(plan.constructing_phase == 1 and plan.spent > 0 and plan.reserved == 0 and is_equal_approx(city.treasury, -200.0), "Dev Mode must fund construction phases automatically without spending city money.")
			_check(DayCycleCalculator.copy_region(main.region).dev_mode, "Worker snapshots must retain Dev Mode.")
	var large = RegionData.new()
	large.is_large_scale = true
	large.dev_mode = true
	_check(DayCycleCalculator.copy_region(large).dev_mode, "Large-scale worker snapshots must retain Dev Mode.")
	if failures == 0:
		print("Dev Mode button, road and development budgets, and snapshots passed.")
	quit(1 if failures > 0 else 0)


func _wait_for_mode(main, expected: bool) -> void:
	var deadline: int = Time.get_ticks_msec() + 10000
	while main.region.dev_mode != expected and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(main.region.dev_mode == expected, "The Dev Mode button must update the active region.")


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures += 1
		push_error(description)
