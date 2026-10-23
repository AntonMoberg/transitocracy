extends RefCounted

const CELL_KM = 2.0


static func in_bounds(region, bounds: Rect2) -> Array[int]:
	var data: Dictionary = region.neighborhood_spatial_cache
	if data.get("revision", -1) != region.road_geometry_revision or data.get("count", -1) != region.neighborhoods.size():
		data = {"revision": region.road_geometry_revision, "count": region.neighborhoods.size(), "cells": {}}
		var cells: Dictionary = data["cells"]
		for neighborhood in region.neighborhoods:
			var extent: Rect2 = region.jurisdictions[neighborhood.jurisdiction_id].bounds_km
			if neighborhood.street_layout != null:
				extent = extent.merge(neighborhood.street_layout.bounds)
			for grid_y in range(floori(extent.position.y / CELL_KM), floori(extent.end.y / CELL_KM) + 1):
				for grid_x in range(floori(extent.position.x / CELL_KM), floori(extent.end.x / CELL_KM) + 1):
					var cell := Vector2i(grid_x, grid_y)
					if not cells.has(cell):
						cells[cell] = []
					cells[cell].append(neighborhood.id)
		region.neighborhood_spatial_cache = data
	var found: Dictionary = {}
	for grid_y in range(floori(bounds.position.y / CELL_KM), floori(bounds.end.y / CELL_KM) + 1):
		for grid_x in range(floori(bounds.position.x / CELL_KM), floori(bounds.end.x / CELL_KM) + 1):
			for neighborhood_id in data["cells"].get(Vector2i(grid_x, grid_y), []):
				found[neighborhood_id] = true
	var result: Array[int] = []
	for neighborhood_id in found:
		result.append(neighborhood_id)
	result.sort()
	return result
