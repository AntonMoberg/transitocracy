extends Control
signal retry_requested
signal back_requested
var reporter
var preview_view:SubViewport
var preview_canvas:Control
var label:Label
var last_revision:=-1
var actions:HBoxContainer
var can_return:=false
func _ready() -> void:
	z_index=1000
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter=Control.MOUSE_FILTER_STOP
	preview_view=SubViewport.new()
	preview_view.disable_3d=true
	preview_view.render_target_update_mode=SubViewport.UPDATE_ONCE
	add_child(preview_view)
	preview_canvas=preload("res://scripts/ui/generation_preview.gd").new()
	preview_canvas.reporter=reporter
	preview_view.add_child(preview_canvas)
	var backdrop:=TextureRect.new()
	backdrop.mouse_filter=Control.MOUSE_FILTER_IGNORE
	backdrop.texture=preview_view.get_texture()
	backdrop.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	var shader:=Shader.new()
	shader.code="shader_type canvas_item; void fragment(){ vec2 d=TEXTURE_PIXEL_SIZE*1.5; vec3 c=texture(TEXTURE,UV).rgb*0.4; c+=(texture(TEXTURE,UV+vec2(d.x,0)).rgb+texture(TEXTURE,UV-vec2(d.x,0)).rgb+texture(TEXTURE,UV+vec2(0,d.y)).rgb+texture(TEXTURE,UV-vec2(0,d.y)).rgb)*0.15; COLOR=vec4(c,1.0); }"
	var material:=ShaderMaterial.new()
	material.shader=shader
	backdrop.material=material
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label=Label.new()
	label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size",24)
	add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	actions=HBoxContainer.new()
	actions.alignment=BoxContainer.ALIGNMENT_CENTER
	add_child(actions)
	actions.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	actions.position.y-=100
	var retry:=Button.new()
	retry.text="Retry"
	retry.pressed.connect(func():retry_requested.emit())
	actions.add_child(retry)
	var back:=Button.new()
	back.text="Return to map" if can_return else "Change seed"
	back.pressed.connect(func():back_requested.emit())
	actions.add_child(back)
	actions.hide()
	resized.connect(_refresh_preview)
	_refresh_preview()
func _process(_delta:float) -> void:
	if reporter==null: return
	var state:Dictionary=reporter.status()
	label.text="Creating your state"+".".repeat(1+int(Time.get_ticks_msec()/450)%3)+"\n\n"+state.stage+"\n%.0f seconds"%state.seconds
	if state.total>0: label.text+="\n%d / %d routes checked"%[state.completed,state.total]
	if state.stage_number>0: label.text+="\nStage %d of 9"%state.stage_number
	actions.visible=state.failed
	if state.failed: label.text="Could not create the state\n\n"+state.stage
	if state.revision!=last_revision:
		last_revision=state.revision
		_refresh_preview()
func _refresh_preview() -> void:
	if preview_view==null: return
	var ratio:float=minf(1.0,1024.0/maxf(1.0,maxf(size.x,size.y)))
	preview_view.size=Vector2i(maxi(1,roundi(size.x*ratio)),maxi(1,roundi(size.y*ratio)))
	preview_canvas.size=Vector2(preview_view.size)
	preview_canvas.queue_redraw()
	preview_view.render_target_update_mode=SubViewport.UPDATE_ONCE
