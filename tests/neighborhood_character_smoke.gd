extends SceneTree

const Setup = preload("res://scripts/simulation/region_setup.gd")
const Planner = preload("res://scripts/simulation/development_planner.gd")
const Character = preload("res://scripts/simulation/neighborhood_character.gd")
const ParcelGeometry = preload("res://scripts/simulation/parcel_geometry.gd")
const Geography = preload("res://scripts/simulation/state_geography.gd")
const Snapshot = preload("res://scripts/simulation/region_snapshot.gd")

var errors := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var block := {"polygon": PackedVector2Array([Vector2.ZERO, Vector2(0.16, 0), Vector2(0.16, 0.11), Vector2(0, 0.11)]), "seed": 42, "park": false}
	var fine: Array[Dictionary] = ParcelGeometry.parcels(block, "Residential", 1, Character.FINE_GRAIN)
	var courtyard: Array[Dictionary] = ParcelGeometry.parcels(block, "Residential", 1, Character.COURTYARD)
	var garden: Array[Dictionary] = ParcelGeometry.parcels(block, "Residential", 1, Character.GARDEN)
	var large: Array[Dictionary] = ParcelGeometry.parcels(block, "Residential", 1, Character.LARGE_PLOT)
	_check(fine.size() > garden.size() and garden.size() > courtyard.size() and courtyard.size() > large.size(), "character profiles must produce distinct parcel frontage")
	var fine_coverage := _coverage(fine)
	var garden_coverage := _coverage(garden)
	_check(garden_coverage < fine_coverage, "garden plots must leave more open land than fine-grain plots")
	var courtyard_buildings := 0
	for parcel in courtyard:
		courtyard_buildings += parcel["buildings"].size()
	_check(courtyard_buildings > courtyard.size(), "courtyard parcels must form several wings around open space")
	_check(ParcelGeometry.parcels(block, "Residential", 1, Character.COURTYARD) == courtyard, "parcel geometry must be deterministic")
	var region = Setup.build(42, 32, 0.1)["region"]
	var candidate_id := -1
	for candidate in region.development_candidates:
		if int(candidate["neighborhood_id"]) < 0 and int(candidate["frontage_link_id"]) >= 0:
			candidate_id = candidate["id"]
			break
	_check(candidate_id >= 0, "a road-frontage district must be available")
	if candidate_id >= 0:
		var key: String = region.development_candidates[candidate_id]["key"]
		_check(Planner.set_candidate_character(region, candidate_id, Character.COURTYARD), "character override should be selectable")
		Planner.refresh_candidates(region)
		_check(region.development_candidate_keys.has(key), "character override district should survive a refresh")
		if region.development_candidate_keys.has(key):
			candidate_id = region.development_candidate_keys[key]
			_check(region.development_candidates[candidate_id]["character_profile"] == Character.COURTYARD, "character override must survive candidate refresh")
			var approval: Dictionary = Planner.set_approval(region, candidate_id, true)
			_check(approval.get("ok", false), "character district should approve")
			if approval.get("ok", false):
				var neighborhood_id: int = region.development_candidates[candidate_id]["neighborhood_id"]
				_check(region.neighborhoods[neighborhood_id].character_profile == Character.COURTYARD, "approved layout must retain the chosen character")
				_check(Snapshot.copy_region(region).neighborhoods[neighborhood_id].character_profile == Character.COURTYARD, "worker snapshots must retain the chosen character")
	if errors.is_empty():
		print("Neighborhood character and parcel smoke checks passed.")
	else:
		for error in errors:
			push_error(error)
	quit(1 if not errors.is_empty() else 0)


func _coverage(parcels: Array[Dictionary]) -> float:
	var area := 0.0
	for parcel in parcels:
		for footprint in parcel["buildings"]:
			area += Geography.polygon_area(footprint)
	return area


func _check(condition: bool, message: String) -> void:
	if not condition:
		errors.append(message)
