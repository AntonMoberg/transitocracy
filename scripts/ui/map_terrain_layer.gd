extends Node2D
## Retained coastline-clipped terrain; camera changes only transform nodes.
const Style = preload("res://scripts/ui/map_style.gd")
const LAND_SHADER = preload("res://scripts/ui/shaders/map_land.gdshader")
var map
var tiles: Dictionary = {}
var base: Node2D
var last_style := ""
var source
var land_material := ShaderMaterial.new()

func _ready() -> void:
	land_material.shader = LAND_SHADER
	var palette := {"land_color": Style.LAND, "woods_color": Style.WOODS, "open_color": Style.OPEN, "rock_color": Style.ROCK}
	for name in palette:
		land_material.set_shader_parameter(name, palette[name])

class Tile:
	extends Node2D
	var textures: Dictionary = {}
	var rect: Rect2
	var map
	var ground: MeshInstance2D
	var slope: MeshInstance2D
	var contours: MeshInstance2D
	func configure(land_material: ShaderMaterial) -> void:
		if ground == null:
			ground = MeshInstance2D.new()
			slope = MeshInstance2D.new()
			contours = MeshInstance2D.new()
			for layer in [ground, slope, contours]:
				layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
				add_child(layer)
		position = rect.position
		for layer in [ground, slope, contours]:
			layer.mesh = textures.get("map_mesh")
		var cartographic: bool = map.base_map_style == "Map" and not map.show_terrain_overlay
		var key := "map_field" if cartographic else ("satellite" if map.base_map_style == "Satellite" else "terrain")
		ground.texture = textures.get(key)
		ground.material = land_material if cartographic else null
		slope.texture = textures.get("slope")
		slope.visible = map.base_map_style == "Map" and map.show_slope_overlay
		contours.texture = textures.get("contours")
		contours.visible = map.base_map_style == "Map" and map.show_contours

func sync() -> void:
	if map.region == null:
		return
	transform = map._screen_transform()
	if source != map.region.terrain:
		source = map.region.terrain
		for node in tiles.values(): node.queue_free()
		tiles.clear()
		if base != null: base.queue_free()
		base = Tile.new()
		base.map = map
		base.rect = source.bounds
		base.textures = map.terrain_base_textures
		add_child(base)
		base.configure(land_material)
	var style: String = "%s:%s:%s:%s" % [map.base_map_style, map.show_terrain_overlay, map.show_slope_overlay, map.show_contours]
	if style != last_style:
		last_style = style
		base.configure(land_material)
		for tile in tiles.values(): tile.configure(land_material)
	var wanted := {}
	for key in map.terrain_detail_visible:
		var candidate: Vector3i = key
		while candidate.x >= 0:
			if map._terrain_tile_ready(candidate):
				wanted[candidate] = true
				break
			candidate = Vector3i(candidate.x - 1, candidate.y / 2, candidate.z / 2)
	for key in wanted:
		if not tiles.has(key):
			var tile := Tile.new()
			tile.map = map
			tile.textures = map.terrain_detail_tiles[key]
			var width: float = map.TERRAIN_DETAIL_STEPS[key.x] * map.TerrainDetailTile.PIXELS
			tile.rect = Rect2(source.bounds.position + Vector2(key.y, key.z) * width, Vector2.ONE * width)
			tile.z_index = key.x + 1
			add_child(tile)
			tile.configure(land_material)
			tiles[key] = tile
		elif tiles[key].textures.get("map_mesh") != map.terrain_detail_tiles[key].get("map_mesh"):
			tiles[key].textures = map.terrain_detail_tiles[key]
			tiles[key].configure(land_material)
	for key in tiles.keys():
		var tile: Node2D = tiles[key]
		tile.visible = wanted.has(key)
		if not map.terrain_detail_tiles.has(key):
			tile.queue_free()
			tiles.erase(key)

func refresh_base() -> void:
	if base == null: return
	base.textures = map.terrain_base_textures
	base.configure(land_material)
