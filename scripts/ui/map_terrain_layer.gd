extends Node2D
## Retained terrain tiles; changing the camera never recreates GPU resources.
var map
var tiles: Dictionary = {}
var base: Node2D
var last_style := ""
var source

class Tile:
	extends Node2D
	var textures: Dictionary = {}
	var rect: Rect2
	var map
	func _draw() -> void:
		var key := "satellite" if map.base_map_style == "Satellite" else ("terrain" if map.show_terrain_overlay else "color")
		if key == "color" and textures.get("map_mesh") != null:
			draw_mesh(textures.map_mesh, null, Transform2D(0.0, rect.position))
		elif textures.get(key) != null:
			draw_texture_rect(textures[key], rect, false)
		if map.base_map_style == "Map":
			if map.show_slope_overlay and textures.get("slope") != null:
				draw_texture_rect(textures.slope, rect, false)
			if map.show_contours and textures.get("contours") != null:
				draw_texture_rect(textures.contours, rect, false)

func sync() -> void:
	if map.region == null:
		return
	transform = map._screen_transform()
	if source != map.region.terrain:
		source = map.region.terrain
		for node in tiles.values():
			node.queue_free()
		tiles.clear()
		if base != null:
			base.queue_free()
		base = Tile.new()
		base.map = map
		base.rect = source.bounds
		base.textures = {"color": map.terrain_texture, "terrain": map.terrain_relief_texture, "satellite": map.satellite_texture, "slope": map.terrain_slope_texture, "contours": map.terrain_contour_texture}
		add_child(base)
	var style: String = "%s:%s:%s:%s" % [map.base_map_style, map.show_terrain_overlay, map.show_slope_overlay, map.show_contours]
	if style != last_style:
		last_style = style
		base.queue_redraw()
		for tile in tiles.values():
			tile.queue_redraw()
	var wanted := {}
	for key in map.terrain_detail_visible:
		var candidate: Vector3i = key
		while candidate.x >= 0:
			if map.terrain_detail_tiles.has(candidate):
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
			tiles[key] = tile
	for key in tiles.keys():
		var tile: Node2D = tiles[key]
		tile.visible = wanted.has(key)
		if not map.terrain_detail_tiles.has(key):
			tile.queue_free()
			tiles.erase(key)

func refresh_base() -> void:
	if base == null:
		return
	base.textures = {"color": map.terrain_texture, "terrain": map.terrain_relief_texture, "satellite": map.satellite_texture, "slope": map.terrain_slope_texture, "contours": map.terrain_contour_texture}
	base.queue_redraw()
