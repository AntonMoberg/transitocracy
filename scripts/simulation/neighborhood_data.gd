extends RefCounted

var id: int = -1
var city_id: int = -1
var county_id: int = -1
var region_id: int = -1
var jurisdiction_id: int = -1
var name: String = ""
var position_km: Vector2 = Vector2.ZERO
var cell_grid: Vector2i = Vector2i.ZERO
var land_area_ha: float = 0.0
var developable_area_ha: float = 0.0

# Percent of developable land and density level (0=low, 1=medium, 2=high).
var zone_shares: Dictionary = {}
var zone_density: Dictionary = {}

var housing_capacity: int = 0
var job_capacity: int = 0
var households: int = 0
var population: int = 0
var jobs: int = 0
var jobs_by_skill: Dictionary = {"Entry": 0, "Skilled": 0, "Professional": 0}
var shopping_attraction: float = 0.0 # Retail-equivalent occupied jobs in Commercial and Mixed zones.
var monthly_rent: int = 0
var assessed_home_value: float = 0.0

# Aggregate household finances and migration state; no individual households are simulated.
var average_monthly_income: int = 0
var average_household_wealth: float = 0.0
var desirability: float = 0.0
var people_per_household: float = 0.0
var baseline_monthly_rent: int = 0
var baseline_occupancy: float = 0.0
var rent_level: float = 0.0
var migration_remainder: float = 0.0
var last_household_change: int = 0
var last_population_change: int = 0
var initially_developed: bool = false
var development_approved: bool = false
var development_state: String = "Established"
var development_jobs_by_skill: Dictionary = {}
var development_retail_share: float = 0.0
var development_income: int = 0
var job_growth_remainder: float = 0.0
