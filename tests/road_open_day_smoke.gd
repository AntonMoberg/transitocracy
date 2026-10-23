extends SceneTree

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const RoadNetworkGenerator = preload("res://scripts/simulation/road_network_generator.gd")
const DevelopmentPlanner = preload("res://scripts/simulation/development_planner.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const TripFlowCalculator = preload("res://scripts/simulation/trip_flow_calculator.gd")
const CalendarClock = preload("res://scripts/simulation/calendar_clock.gd")
const MultiScaleTraffic = preload("res://scripts/simulation/multiscale_traffic.gd")
const MultiScaleDayCalculator = preload("res://scripts/simulation/multiscale_day_calculator.gd")
const RoadProject = preload("res://scripts/simulation/road_project_data.gd")
const Roads = preload("res://scripts/simulation/road_link_data.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var region = RegionGenerator.generate_large_region(7113721, 16)
	RoadNetworkGenerator.generate(region)
	DevelopmentPlanner.refresh_candidates(region)
	AccessibilityCalculator.recalculate(region)
	var clock = CalendarClock.new()
	var flow = TripFlowCalculator.build(region)
	TripFlowCalculator.populate_day(flow, region.generation_seed, clock.unix_seconds, clock.is_weekend())
	var traffic = MultiScaleTraffic.new_day(region, flow, clock.unix_seconds)
	var target_id := -1
	var old_lanes := 0
	for link in region.road_links:
		if link.road_class == Roads.ARTERIAL:
			target_id = link.id
			old_lanes = link.lanes_per_direction
			break
	if target_id < 0:
		push_error("No arterial is available for the opening-day fixture.")
		quit(1)
		return
	var project = RoadProject.new()
	project.kind = RoadProject.WIDEN
	project.target_link_id = target_id
	project.open_day_key = traffic.day_key + 1
	region.road_projects.append(project)
	var result: Dictionary = MultiScaleDayCalculator.advance_day(region, project.open_day_key, flow, traffic)
	var opened = result["region"]
	for link in opened.road_links:
		if link.id == target_id and link.lanes_per_direction == old_lanes + 1 and opened.road_projects.is_empty():
			print("Opening a road project refreshes next-day candidates and traffic.")
			quit(0)
			return
	push_error("Road project did not open during the next-day calculation.")
	quit(1)
