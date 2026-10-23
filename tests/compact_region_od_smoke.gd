extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const FlowProfile = preload("res://scripts/simulation/flow_profile.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var setup: Dictionary = Setup.build(1729, 256, 0.1)
	var region = setup["region"]
	var profile = setup["flow"]
	for purpose in [FlowProfile.WORK, FlowProfile.COMMERCIAL, FlowProfile.SOCIAL]:
		var expected: Array[PackedFloat32Array] = []
		for _region_id in region.region_ids:
			var row := PackedFloat32Array()
			row.resize(region.region_ids.size())
			expected.append(row)
		var city_matrix: Array = profile.compact_city_od[purpose]
		for origin_city in range(region.cities.size()):
			var from_region: int = region.cities[origin_city]["region_id"]
			for destination_city in range(region.cities.size()):
				var to_region: int = region.cities[destination_city]["region_id"]
				expected[from_region][to_region] += city_matrix[origin_city][destination_city]
		for region_id in range(expected.size()):
			for destination_id in range(expected[region_id].size()):
				if absf(expected[region_id][destination_id] - profile.compact_region_od[purpose][region_id][destination_id]) > 0.01:
					push_error("Sparse region trip aggregation differs from the full city matrix")
					quit(1)
					return
	print("Sparse region trip totals match full city-pair aggregation.")
	quit(0)
