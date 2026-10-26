extends RefCounted

# Actual generated urban street fabric, distinct from a city jurisdiction.
var is_urban_street: bool = false

var id: int = -1
var position_km: Vector2 = Vector2.ZERO
var kind: String = "Junction"
var neighborhood_id: int = -1
var city_id: int = -1
var is_interchange: bool = false
var interchange_owner_jurisdiction_id: int = -1
var managed_neighborhood_id: int = -1


func display_name() -> String:
	if kind == "City":
		return "City interchange" if is_interchange else "City junction"
	if kind == "Neighborhood":
		return "Neighborhood gateway"
	return "Interchange" if is_interchange else "Junction"
