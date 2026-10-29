extends SceneTree
var failures: Array[String] = []

class LayoutMain extends "res://scripts/main.gd":
	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_build_interface()

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	var main := LayoutMain.new()
	root.add_child(main)
	for resolution in [Vector2i(1024,700),Vector2i(1920,1080),Vector2i(2560,1440)]:
		root.size = resolution
		for step in range(5): await process_frame
		_check(main.map_view.position==Vector2.ZERO and main.map_view.size==main.size,"Map must fill the window")
		_check(main.hud.footer.get_rect().end.x<=main.size.x+.1,"Toolbar overflow")
		_check(main.hud.footer.size.y<=81,"Toolbar must stay compact")
		for section in ["Roads","Zoning","Planning","Map","Statistics","Menu"]:
			main.hud.select_section(section,false)
			main.hud.show_inspector()
			for step in range(3): await process_frame
			var rect: Rect2 = main.hud.drawers[section].get_rect()
			_check(rect.position.x>=0 and rect.end.x<=main.size.x+.1,"Drawer overflow: "+section)
			_check(rect.end.y<=main.hud.footer.position.y,"Drawer overlaps toolbar: "+section)
			_check(not rect.intersects(main.hud.inspector_panel.get_rect()),"Drawer overlaps inspector: "+section)
			main.hud.hide_inspector()
	main.queue_free()
	await process_frame
	print("HUD layouts fit 1024×700, 1920×1080 and 2560×1440.")
	if not failures.is_empty(): push_error("; ".join(failures))
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)
