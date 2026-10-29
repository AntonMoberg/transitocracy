extends Control

signal section_selected(section: String)
signal inspector_closed
signal safe_area_changed(insets: Vector4)

const PAPER = Color("f7f8f3")
const INK = Color("344957")
const MUTED = Color("667d83")
const ACCENT = Color("287b88")
const FOOTER_HEIGHT = 80.0

var section := ""
var footer: PanelContainer
var clock_slot: VBoxContainer
var status_slot: VBoxContainer
var population_label: Label
var funds_button: Button
var inspector_panel: PanelContainer
var inspector_body: VBoxContainer
var inspector_scroll: ScrollContainer
var drawers: Dictionary = {}
var slots: Dictionary = {}
var section_buttons: Dictionary = {}
var tool_buttons: Dictionary = {}
var map_buttons: Dictionary = {}
var trips_toggle: CheckButton


class Glyph extends Control:
	var kind := ""
	func _draw() -> void:
		var c := Color("287b88")
		match kind:
			"Roads":
				draw_line(Vector2(6,2),Vector2(2,23),c,2,true)
				draw_line(Vector2(18,2),Vector2(22,23),c,2,true)
				for y in [3,11,19]: draw_line(Vector2(12,y),Vector2(12,y+4),c,1.5,true)
			"Zoning":
				for i in range(3):
					for j in range(3): draw_rect(Rect2(2+i*8,2+j*8,5,5),c,false,1.3)
			"Planning":
				draw_polyline(PackedVector2Array([Vector2(3,21),Vector2(9,5),Vector2(22,13)]),c,2,true)
				for p in [Vector2(3,21),Vector2(9,5),Vector2(22,13)]: draw_circle(p,3,PAPER); draw_arc(p,3,0,TAU,16,c,1.5,true)
			"Map":
				for y in [4,10,16]: draw_polyline(PackedVector2Array([Vector2(2,y+3),Vector2(12,y-2),Vector2(23,y+3),Vector2(12,y+8),Vector2(2,y+3)]),c,1.5,true)
			"Statistics":
				for i in range(3): draw_rect(Rect2(3+i*8,20-i*6,4,5+i*6),c)
				draw_line(Vector2(1,25),Vector2(25,25),c,1.2,true)


func _ready() -> void:
	name = "GameHUD"
	z_index = 300
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = make_theme()
	_build_footer()
	for title in ["Roads","Zoning","Planning","Map","Statistics","Menu"]:
		_build_drawer(title)
	_build_inspector()
	resized.connect(_layout)
	_layout()


static func style(color: Color = PAPER, padding: int = 12) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = Color("d4dfdc")
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.set_content_margin_all(padding)
	box.shadow_color = Color(0.15,0.23,0.25,0.08)
	box.shadow_size = 4
	return box


static func make_theme() -> Theme:
	var result := Theme.new()
	result.default_font_size = 14
	for kind in ["Label","Button","OptionButton","CheckBox","CheckButton","LineEdit","SpinBox","ItemList","RichTextLabel","PopupMenu"]:
		for key in ["font_color","font_hover_color","font_pressed_color","font_focus_color","default_color"]:
			result.set_color(key,kind,INK)
		result.set_color("font_disabled_color",kind,Color("8d9c9d"))
		result.set_color("font_selected_color",kind,INK)
	for kind in ["Button","OptionButton","LineEdit"]:
		for state in ["normal","hover","pressed","disabled"]:
			var box := style({"normal":Color("edf1ed"),"hover":Color("e1eeea"),"pressed":Color("cfe5df"),"disabled":Color("eff1ed")}[state],7)
			box.shadow_size = 0
			result.set_stylebox(state,kind,box)
		var focus := style(Color(0,0,0,0),7)
		focus.border_color = ACCENT
		result.set_stylebox("focus",kind,focus)
	for kind in ["PanelContainer","PopupPanel","PopupMenu","ItemList"]:
		result.set_stylebox("panel",kind,style())
	result.set_stylebox("selected", "ItemList", style(Color("d8eae4"),2))
	result.set_stylebox("selected_focus", "ItemList", style(Color("cfe5df"),2))
	result.set_color("selection_color","RichTextLabel",Color("cfe5df"))
	result.set_color("font_color","TooltipLabel",INK)
	result.set_stylebox("panel","TooltipPanel",style(PAPER,8))
	return result


func _build_footer() -> void:
	footer = PanelContainer.new()
	footer.name = "Toolbar"
	footer.add_theme_stylebox_override("panel",style(PAPER,10))
	footer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(footer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation",12)
	footer.add_child(row)
	clock_slot = VBoxContainer.new()
	clock_slot.custom_minimum_size.x = 250
	clock_slot.add_theme_constant_override("separation",4)
	row.add_child(clock_slot)
	row.add_child(VSeparator.new())
	var tools := HBoxContainer.new()
	tools.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.alignment = BoxContainer.ALIGNMENT_CENTER
	tools.add_theme_constant_override("separation",5)
	row.add_child(tools)
	for title in ["Roads","Zoning","Planning","Map","Statistics"]:
		var button := Button.new()
		button.name = title
		button.custom_minimum_size = Vector2(66,54)
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.tooltip_text = title
		tools.add_child(button)
		var column := VBoxContainer.new()
		column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		column.offset_top = 3
		button.add_child(column)
		var glyph := Glyph.new()
		glyph.kind = title
		glyph.custom_minimum_size = Vector2(26,26)
		glyph.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(glyph)
		var label := Label.new()
		label.text = title
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size",12)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		column.add_child(label)
		section_buttons[title] = button
		button.pressed.connect(func(): select_section("" if section==title else title))
	row.add_child(VSeparator.new())
	status_slot = VBoxContainer.new()
	status_slot.custom_minimum_size.x = 165
	row.add_child(status_slot)
	population_label = Label.new()
	population_label.text = "Population —"
	population_label.clip_text = true
	status_slot.add_child(population_label)
	funds_button = Button.new()
	funds_button.text = "Finances"
	funds_button.clip_text = true
	funds_button.focus_mode = Control.FOCUS_NONE
	status_slot.add_child(funds_button)
	var menu := Button.new()
	menu.text = "Menu"
	menu.focus_mode = Control.FOCUS_NONE
	menu.toggle_mode = true
	row.add_child(menu)
	section_buttons.Menu = menu
	menu.pressed.connect(func(): select_section("" if section=="Menu" else "Menu"))


func _build_drawer(title: String) -> void:
	var panel := PanelContainer.new()
	panel.name = title+"Drawer"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.visible = false
	add_child(panel)
	drawers[title] = panel
	var column := VBoxContainer.new()
	panel.add_child(column)
	column.add_child(_heading(title,func(): select_section("")))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation",8)
	scroll.add_child(body)
	slots[title] = body


func _build_inspector() -> void:
	inspector_panel = PanelContainer.new()
	inspector_panel.name = "Inspector"
	inspector_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	inspector_panel.visible = false
	add_child(inspector_panel)
	var column := VBoxContainer.new()
	inspector_panel.add_child(column)
	column.add_child(_heading("Details",func(): hide_inspector(); inspector_closed.emit()))
	inspector_body = VBoxContainer.new()
	inspector_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(inspector_body)


func _heading(title: String, close: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = title.to_upper()
	label.add_theme_font_size_override("font_size",12)
	label.add_theme_color_override("font_color",ACCENT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var button := Button.new()
	button.text = "×"
	button.tooltip_text = "Close • Escape"
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(close)
	row.add_child(button)
	return row


func add_tool(title: String, index: int, group: String, callback: Callable) -> void:
	if not slots.has(group+"Tools"):
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation",6)
		flow.add_theme_constant_override("v_separation",6)
		slots[group].add_child(flow)
		slots[group+"Tools"] = flow
	var button := Button.new()
	button.text = title
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback.bind(index))
	slots[group+"Tools"].add_child(button)
	tool_buttons[index] = button


func mark_tool(index: int) -> void:
	for key in tool_buttons: tool_buttons[key].set_pressed_no_signal(key==index)


func select_section(value: String, notify: bool = true) -> void:
	section = value
	for key in drawers: drawers[key].visible = key==value
	for key in section_buttons: section_buttons[key].set_pressed_no_signal(key==value)
	if value=="Statistics": inspector_panel.hide()
	_layout()
	if notify: section_selected.emit(value)


func show_inspector() -> void:
	inspector_panel.show()
	if inspector_scroll!=null: inspector_scroll.scroll_vertical = 0
	_layout()


func hide_inspector() -> void:
	inspector_panel.hide()
	_layout()


func _layout() -> void:
	if footer==null: return
	footer.position = Vector2(0,size.y-FOOTER_HEIGHT)
	footer.size = Vector2(size.x,FOOTER_HEIGHT)
	var inspector_width := 400.0 if size.x>=1440 else 360.0
	inspector_panel.position = Vector2(size.x-inspector_width-12,12)
	inspector_panel.size = Vector2(inspector_width,maxf(100,size.y-FOOTER_HEIGHT-36))
	var available_width: float = size.x-24-(inspector_width+12 if inspector_panel.visible else 0.0)
	for key in drawers:
		var width: float = minf(900.0 if key=="Statistics" else (340.0 if key=="Menu" else 760.0),available_width)
		var height: float = minf({"Roads":240.0,"Zoning":280.0,"Planning":160.0,"Map":190.0,"Statistics":420.0,"Menu":340.0}[key],size.y-FOOTER_HEIGHT-24)
		drawers[key].position = Vector2(available_width-width+12 if key=="Menu" else 12.0,size.y-FOOTER_HEIGHT-height-12)
		drawers[key].size = Vector2(width,height)
	var bottom: float = FOOTER_HEIGHT+12
	if not section.is_empty() and section!="Menu": bottom += drawers[section].size.y+12
	safe_area_changed.emit(Vector4(12,12,inspector_width+24 if inspector_panel.visible else 12.0,bottom))
