extends RefCounted

var id: int = -1
var city_id: int = -1
var name: String = ""
var position_km: Vector2 = Vector2.ZERO
var land_area_ha: float = 0.0

# Percent of developable land and density level (0=low, 1=medium, 2=high).
var zone_shares: Dictionary = {}
var zone_density: Dictionary = {}

var housing_capacity: int = 0
var job_capacity: int = 0
var households: int = 0
var population: int = 0
var jobs: int = 0
var jobs_by_skill: Dictionary = {"Entry": 0, "Skilled": 0, "Professional": 0}
var monthly_rent: int = 0
