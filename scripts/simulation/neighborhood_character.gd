extends RefCounted

const AUTO = "Auto"
const FINE_GRAIN = "Fine Grain"
const COURTYARD = "Courtyard"
const GARDEN = "Garden"
const LARGE_PLOT = "Large Plot"
const PROFILES = [FINE_GRAIN, COURTYARD, GARDEN, LARGE_PLOT]


static func resolve(region, city_id: int, center: Vector2, street_style: String, shares: Dictionary, densities: Dictionary, override_name: String = AUTO) -> String:
	if PROFILES.has(override_name):
		return override_name
	var industrial: int = int(shares.get("Industry", 0))
	var residential: int = int(shares.get("Residential", 0))
	var mixed: int = int(shares.get("Mixed", 0))
	var weighted_density := 0.0
	for zone in shares:
		weighted_density += float(shares[zone]) * float(densities.get(zone, 0)) / 100.0
	if industrial >= 35:
		return LARGE_PLOT
	if street_style == "Organic" and residential >= 35:
		return GARDEN
	if weighted_density >= 1.3:
		return COURTYARD
	# A city-wide field keeps several adjoining districts in the same family.
	var district_band := Vector2i(floori(center.x / 4.8), floori(center.y / 4.8))
	var value: int = posmod(hash("%d:character:%d:%d:%d" % [region.generation_seed, city_id, district_band.x, district_band.y]), 100)
	if residential >= 45 and weighted_density < 0.65 and value < 60:
		return GARDEN
	if mixed + int(shares.get("Commercial", 0)) >= 45 and value < 25:
		return COURTYARD
	return FINE_GRAIN


static func frontage_km(profile: String) -> float:
	match profile:
		COURTYARD:
			return 0.040
		GARDEN:
			return 0.031
		LARGE_PLOT:
			return 0.075
		_:
			return 0.017


static func margins_km(profile: String, density: int) -> Vector3:
	# Front, side and rear distances in kilometres.
	match profile:
		COURTYARD:
			return Vector3(0.004, 0.003, 0.011)
		GARDEN:
			return Vector3(0.008, 0.004, 0.012)
		LARGE_PLOT:
			return Vector3(0.006, 0.006, 0.010)
		_:
			return Vector3(0.002, 0.001 if density >= 1 else 0.002, 0.008)
