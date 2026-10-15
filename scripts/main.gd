extends Control

const RegionGenerator = preload("res://scripts/simulation/region_generator.gd")
const AccessibilityCalculator = preload("res://scripts/simulation/accessibility_calculator.gd")
const RegionData = preload("res://scripts/simulation/region_data.gd")
const RegionMap = preload("res://scripts/ui/region_map.gd")

const DEFAULT_SEED = 1729

var region
var map_view
var seed_input: SpinBox
var summary_label: Label
var inspector: RichTextLabel


func _ready() -> void:
	get_window().min_size = Vector2i(1024, 640)
	_build_interface()
	_generate_region(DEFAULT_SEED)


func _build_interface() -> void:
	var background := ColorRect.new()
	background.color = Color("0b1421")
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	layout.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	var title := Label.new()
	title.text = "TRANSITOCRACY"
	title.add_theme_font_size_override("font_size", 27)
	title.add_theme_color_override("font_color", Color("e8f1f7"))
	titles.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Regional simulation baseline"
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color("8ea4b8"))
	titles.add_child(subtitle)

	var seed_label := Label.new()
	seed_label.text = "Region seed"
	seed_label.add_theme_color_override("font_color", Color("b8c9d6"))
	header.add_child(seed_label)
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 9999999
	seed_input.step = 1
	seed_input.rounded = true
	seed_input.value = DEFAULT_SEED
	seed_input.custom_minimum_size = Vector2(116, 0)
	header.add_child(seed_input)
	var generate_button := Button.new()
	generate_button.text = "Generate"
	generate_button.pressed.connect(_on_generate_pressed)
	header.add_child(generate_button)
	var quit_button := Button.new()
	quit_button.text = "Quit"
	quit_button.tooltip_text = "Close Transitocracy"
	quit_button.pressed.connect(_on_quit_pressed)
	header.add_child(quit_button)

	summary_label = Label.new()
	summary_label.add_theme_font_size_override("font_size", 14)
	summary_label.add_theme_color_override("font_color", Color("b5cad9"))
	layout.add_child(summary_label)

	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	layout.add_child(content)

	var map_panel := PanelContainer.new()
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_panel.add_theme_stylebox_override("panel", _panel_style(Color("101b2b"), 0))
	content.add_child(map_panel)
	map_view = RegionMap.new()
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_view.neighborhood_selected.connect(_on_neighborhood_selected)
	map_panel.add_child(map_view)

	var inspector_panel := PanelContainer.new()
	inspector_panel.custom_minimum_size = Vector2(340, 0)
	inspector_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_panel.add_theme_stylebox_override("panel", _panel_style(Color("152235"), 16))
	content.add_child(inspector_panel)
	inspector = RichTextLabel.new()
	inspector.bbcode_enabled = true
	inspector.selection_enabled = true
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector.add_theme_font_size_override("normal_font_size", 14)
	inspector_panel.add_child(inspector)


func _panel_style(color: Color, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(12)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


func _on_generate_pressed() -> void:
	_generate_region(int(seed_input.value))


func _on_quit_pressed() -> void:
	get_tree().quit()


func _generate_region(seed_value: int) -> void:
	region = RegionGenerator.generate_region(seed_value)
	AccessibilityCalculator.recalculate(region)
	var errors: PackedStringArray = region.validation_errors()
	if not errors.is_empty():
		push_error("Invalid generated region: " + "; ".join(errors))
		inspector.text = "[color=#ff8c8c]Region generation failed validation.[/color]"
		return
	map_view.set_region(region)
	var totals: Dictionary = region.get_region_totals()
	summary_label.text = "%s  ›  %s  ›  %s     •     %d cities     •     %d neighborhoods     •     %s people     •     %s jobs" % [
		region.state_name, region.region_name, region.county_name,
		region.cities.size(), region.neighborhoods.size(),
		_format_count(totals["population"]), _format_count(totals["jobs"]),
	]
	_on_neighborhood_selected(0)


func _on_neighborhood_selected(neighborhood_id: int) -> void:
	map_view.set_selected(neighborhood_id)
	if neighborhood_id < 0:
		inspector.text = "[font_size=21][b]Neighborhood inspector[/b][/font_size]\n\nSelect a neighborhood to inspect its baseline statistics."
		return
	var neighborhood = region.neighborhoods[neighborhood_id]
	var city_totals: Dictionary = region.get_city_totals(neighborhood.city_id)
	var region_totals: Dictionary = region.get_region_totals()
	var access: float = region.accessibility[neighborhood_id]
	var share_of_jobs: float = 100.0 * access / maxf(1.0, float(region_totals["jobs"]))
	var text_lines := PackedStringArray()
	text_lines.append("[font_size=22][b]%s[/b][/font_size]" % neighborhood.name)
	text_lines.append("[color=#91abc0]%s City  •  %.0f hectares[/color]" % [region.get_city_name(neighborhood.city_id), neighborhood.land_area_ha])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]BASELINE[/b][/color]")
	text_lines.append("Population: %s   Households: %s" % [_format_count(neighborhood.population), _format_count(neighborhood.households)])
	text_lines.append("Housing capacity: %s" % _format_count(neighborhood.housing_capacity))
	text_lines.append("Jobs: %s   Job capacity: %s" % [_format_count(neighborhood.jobs), _format_count(neighborhood.job_capacity)])
	text_lines.append("Monthly rent: $%s" % _format_count(neighborhood.monthly_rent))
	text_lines.append("Job access: [b]%s[/b] weighted jobs (%.1f%% of total)" % [_format_count(roundi(access)), share_of_jobs])
	text_lines.append("[color=#91abc0]Jobs are discounted by travel time.[/color]")
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]ZONING · SHARE / DENSITY[/b][/color]")
	for zone in RegionData.ZONE_TYPES:
		text_lines.append("%s: %d%% / %s" % [zone, neighborhood.zone_shares[zone], RegionData.DENSITY_NAMES[neighborhood.zone_density[zone]]])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]JOBS BY SKILL[/b][/color]")
	for skill in ["Entry", "Skilled", "Professional"]:
		text_lines.append("%s: %s" % [skill, _format_count(neighborhood.jobs_by_skill[skill])])
	text_lines.append("")
	text_lines.append("[color=#78c8dc][b]TRAVEL TIMES[/b][/color]")
	var travel_order: Array[int] = []
	for id in range(region.neighborhoods.size()):
		travel_order.append(id)
	travel_order.sort_custom(func(a: int, b: int) -> bool: return region.travel_times[neighborhood_id][a] < region.travel_times[neighborhood_id][b])
	for id in travel_order:
		text_lines.append("%s: %.1f min" % [region.neighborhoods[id].name, region.travel_times[neighborhood_id][id]])
	text_lines.append("")
	text_lines.append("[color=#91abc0]%s City total: %s people / %s jobs[/color]" % [region.get_city_name(neighborhood.city_id), _format_count(city_totals["population"]), _format_count(city_totals["jobs"])])
	inspector.text = "\n".join(text_lines)
	inspector.scroll_to_line(0)


func _format_count(value: int) -> String:
	var digits := str(value)
	var formatted := ""
	while digits.length() > 3:
		formatted = "," + digits.substr(digits.length() - 3, 3) + formatted
		digits = digits.substr(0, digits.length() - 3)
	return digits + formatted
