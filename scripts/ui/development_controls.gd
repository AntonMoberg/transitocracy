extends VBoxContainer

signal allocation_requested(neighborhood_id: int, amount: int)
signal zoning_requested(neighborhood_id: int, shares: Dictionary, density: Dictionary)
signal design_requested(candidate_id: int, variant: int)
signal character_requested(candidate_id: int, profile: String)

const Budget = preload("res://scripts/simulation/development_budget.gd")
const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const NeighborhoodData = preload("res://scripts/simulation/neighborhood_data.gd")
const Plan = preload("res://scripts/simulation/development_plan.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const ZoneTypes = ["Residential", "Commercial", "Office", "Mixed", "Industry"]
var neighborhood_id: int = -1
var candidate_id: int = -1
var neighborhood = null
var current_region = null
var style_input: OptionButton
var character_input: OptionButton
var allocation_input: SpinBox
var preview_label: Label
var zone_inputs: Dictionary = {}
var density_inputs: Dictionary = {}
var zoning_grid: VBoxContainer
var zoning_popup: PopupPanel
var editor_status_label: Label
var apply_button: Button
var suppress_preview: bool = false
var custom_allocation: bool = false
var allocation_buttons: Array[Button] = []
var dev_mode: bool = false


func _ready() -> void:
	var allocation_row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Allocate $"
	allocation_row.add_child(label)
	allocation_input = SpinBox.new()
	allocation_input.max_value = 1000000000000.0
	allocation_input.step = 1.0
	allocation_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	allocation_row.add_child(allocation_input)
	allocation_input.value_changed.connect(func(_value: float) -> void:
		if not suppress_preview:
			custom_allocation = true)
	for action in ["Top up", "Return"]:
		var button := Button.new()
		button.text = action
		button.pressed.connect(func() -> void:
			if neighborhood_id >= 0:
				allocation_requested.emit(neighborhood_id, roundi(allocation_input.value) * (1 if action == "Top up" else -1)))
		allocation_row.add_child(button)
		allocation_buttons.append(button)
	var expand := Button.new()
	expand.text = "Budget, land use and density…"
	expand.pressed.connect(func() -> void: zoning_popup.popup_centered(Vector2i(360, 0)))
	add_child(expand)
	zoning_popup = PopupPanel.new()
	var popup_style := StyleBoxFlat.new()
	popup_style.bg_color = Color("152235")
	popup_style.border_color = Color("52717b")
	popup_style.set_border_width_all(1)
	popup_style.set_corner_radius_all(8)
	zoning_popup.add_theme_stylebox_override("panel", popup_style)
	add_child(zoning_popup)
	visibility_changed.connect(func() -> void:
		if not visible:
			zoning_popup.hide())
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	zoning_popup.add_child(margin)
	zoning_grid = VBoxContainer.new()
	margin.add_child(zoning_grid)
	var heading := Label.new()
	heading.text = "Land-use shares and density"
	zoning_grid.add_child(heading)
	var style_row := HBoxContainer.new()
	var style_label := Label.new()
	style_label.text = "Street design"
	style_row.add_child(style_label)
	style_input = OptionButton.new()
	style_input.add_item("Connected grid")
	style_input.add_item("Longer blocks across")
	style_input.add_item("Longer blocks along")
	style_input.item_selected.connect(func(index: int) -> void:
		if not suppress_preview and candidate_id >= 0:
			design_requested.emit(candidate_id, index))
	style_row.add_child(style_input)
	zoning_grid.add_child(style_row)
	var character_row := HBoxContainer.new()
	var character_label := Label.new()
	character_label.text = "Neighbourhood character"
	character_row.add_child(character_label)
	character_input = OptionButton.new()
	for profile in ["Auto", "Fine Grain", "Courtyard", "Garden", "Large Plot"]:
		character_input.add_item(profile)
	character_input.item_selected.connect(func(index: int) -> void:
		if not suppress_preview and candidate_id >= 0:
			character_requested.emit(candidate_id, character_input.get_item_text(index)))
	character_row.add_child(character_input)
	zoning_grid.add_child(character_row)
	zoning_grid.add_child(allocation_row)
	var grid := GridContainer.new()
	grid.columns = 3
	zoning_grid.add_child(grid)
	for zone in ZoneTypes:
		var zone_label := Label.new()
		zone_label.text = zone
		grid.add_child(zone_label)
		var percentage := SpinBox.new()
		percentage.max_value = 100.0
		percentage.step = 1.0
		percentage.suffix = "%"
		percentage.value_changed.connect(func(_value: float) -> void: _preview())
		zone_inputs[zone] = percentage
		grid.add_child(percentage)
		var density := OptionButton.new()
		for level in ["Low", "Medium", "High"]:
			density.add_item(level)
		density.item_selected.connect(func(_index: int) -> void: _preview())
		density_inputs[zone] = density
		grid.add_child(density)
	apply_button = Button.new()
	apply_button.text = "Apply zoning next day"
	apply_button.pressed.connect(func() -> void:
		zoning_requested.emit(neighborhood_id, shares(), densities())
		zoning_popup.hide())
	zoning_grid.add_child(apply_button)
	editor_status_label = Label.new()
	editor_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	editor_status_label.custom_minimum_size.x = 300
	editor_status_label.add_theme_font_size_override("font_size", 12)
	zoning_grid.add_child(editor_status_label)
	var done := Button.new()
	done.text = "Keep draft / Close"
	done.pressed.connect(func() -> void: zoning_popup.hide())
	zoning_grid.add_child(done)
	preview_label = Label.new()
	preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_label.add_theme_font_size_override("font_size", 12)
	add_child(preview_label)


func show_plan(region, candidate: Dictionary, reset: bool = true) -> void:
	current_region=region
	dev_mode = region.dev_mode
	candidate_id = candidate["id"]
	neighborhood_id = candidate["neighborhood_id"]
	suppress_preview = true
	style_input.select(int(candidate.get("design_variant", 0)))
	style_input.disabled = neighborhood_id >= 0
	var character_choice: String = region.neighborhoods[neighborhood_id].character_profile if neighborhood_id >= 0 else candidate.get("character_override", "Auto")
	for index in range(character_input.item_count):
		if character_input.get_item_text(index) == character_choice:
			character_input.select(index)
			break
	character_input.disabled = neighborhood_id >= 0
	suppress_preview = false
	neighborhood = region.neighborhoods[neighborhood_id] if neighborhood_id >= 0 else null
	var defaults: Dictionary
	if neighborhood != null:
		defaults = {"shares": neighborhood.zone_shares, "density": neighborhood.zone_density}
	else:
		defaults = RegionGenerator.zone_defaults(region, candidate["city_id"], candidate["grid"])
		neighborhood = NeighborhoodData.new()
		neighborhood.developable_area_ha = minf(105.0, Geography.polygon_area(candidate["polygon"]) * 100.0)
		neighborhood.zone_shares = defaults["shares"]
		neighborhood.zone_density = defaults["density"]
		var rng := RandomNumberGenerator.new()
		rng.seed = region.generation_seed
		RegionGenerator._populate_capacity_and_occupancy(neighborhood, rng, region.cities[candidate["city_id"]]["density"])
		neighborhood.street_layout = candidate["layout"]
		neighborhood.development_plan = Plan.new()
		neighborhood.development_plan.target_housing = neighborhood.housing_capacity
		neighborhood.development_plan.target_jobs = neighborhood.job_capacity
		neighborhood.development_plan.design_demand = maxf(1.0, float(neighborhood.housing_capacity) * 2.0 + neighborhood.job_capacity)
	if reset:
		zoning_popup.hide()
		suppress_preview = true
		custom_allocation = false
		for zone in ZoneTypes:
			zone_inputs[zone].value = defaults["shares"][zone]
			density_inputs[zone].select(defaults["density"][zone])
		allocation_input.value = 0 if dev_mode else maxi(0, Budget.remaining_cost(neighborhood) - neighborhood.development_plan.reserved)
		suppress_preview = false
	_preview()
	for index in range(allocation_buttons.size()):
		allocation_buttons[index].disabled = neighborhood_id < 0 or not neighborhood.development_plan.active or (dev_mode and index == 0)
	visible = true


func shares() -> Dictionary:
	var values: Dictionary = {}
	for zone in ZoneTypes:
		values[zone] = roundi(zone_inputs[zone].value)
	return values


func densities() -> Dictionary:
	var values: Dictionary = {}
	for zone in ZoneTypes:
		values[zone] = density_inputs[zone].selected
	return values


func _preview() -> void:
	if suppress_preview or preview_label == null:
		return
	var total := 0
	for value in shares().values():
		total += value
	apply_button.disabled = total != 100 or neighborhood_id < 0
	if total != 100:
		preview_label.text = "Land use totals %d%%; it must total 100%%." % total
		editor_status_label.text = preview_label.text
	elif neighborhood != null and neighborhood.development_plan != null:
		var estimate: Dictionary = Budget.zoning_estimate(neighborhood, shares(), densities(),current_region)
		if not custom_allocation:
			suppress_preview = true
			allocation_input.value = 0 if dev_mode else estimate["top_up"]
			suppress_preview = false
		editor_status_label.text = "Target: %d homes • %d jobs\nRemaining $%d • Top-up $%d\nNext work $%d\nReserved $%d • Spent $%d" % [estimate["housing"], estimate["jobs"], estimate["remaining"], estimate["top_up"], estimate["next_cost"], neighborhood.development_plan.reserved, neighborhood.development_plan.spent]
		preview_label.text = "Target: %d homes • %d jobs\nRemaining $%d • Reserved $%d" % [estimate["housing"], estimate["jobs"], estimate["remaining"], neighborhood.development_plan.reserved]
		if dev_mode:
			editor_status_label.text += "\nDev Mode funds construction automatically."
			preview_label.text += "\nDev Mode funds construction automatically."
