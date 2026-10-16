extends RefCounted

const ASSESSED_VALUE_RENT_MULTIPLIER = 120.0
const SHOPPING_SPEND_INCOME_SHARE = 0.01
const DAYS_PER_YEAR = 365.0


static func assess_homes(region) -> void:
	for neighborhood in region.neighborhoods:
		neighborhood.assessed_home_value = float(neighborhood.monthly_rent) * ASSESSED_VALUE_RENT_MULTIPLIER


static func after_income_tax(region, neighborhood) -> float:
	var state = region.jurisdictions[0]
	var county = region.jurisdictions[region.county_ids[neighborhood.county_id]]
	return float(neighborhood.average_monthly_income) * (1.0 - state.income_tax_rate - county.income_tax_rate)


static func property_cost_monthly(region, neighborhood) -> float:
	var county = region.jurisdictions[region.county_ids[neighborhood.county_id]]
	return neighborhood.assessed_home_value * county.property_tax_rate / 12.0


static func shopping_spend(region, origin_id: int) -> float:
	return maxf(10.0, float(region.neighborhoods[origin_id].average_monthly_income) * SHOPPING_SPEND_INCOME_SHARE)


static func refresh_tax_estimates(region) -> void:
	for area in region.jurisdictions:
		area.daily_income_revenue = 0.0
		area.daily_property_revenue = 0.0
	for neighborhood in region.neighborhoods:
		var county = region.jurisdictions[region.county_ids[neighborhood.county_id]]
		var annual_income: float = float(neighborhood.households * neighborhood.average_monthly_income) * 12.0
		region.jurisdictions[0].daily_income_revenue += annual_income * region.jurisdictions[0].income_tax_rate / DAYS_PER_YEAR
		county.daily_income_revenue += annual_income * county.income_tax_rate / DAYS_PER_YEAR
		county.daily_property_revenue += float(neighborhood.households) * neighborhood.assessed_home_value * county.property_tax_rate / DAYS_PER_YEAR


static func collect_sales(region, origin_id: int, destination_id: int, visits: float) -> void:
	var county = region.jurisdiction_for_neighborhood(destination_id, "County")
	county.daily_sales_revenue += visits * shopping_spend(region, origin_id) * county.sales_tax_rate


static func collect_arrival_fees(region, origin_id: int, destination_id: int, cars: float) -> void:
	if cars <= 0.0 or origin_id == destination_id:
		return
	var city = region.jurisdiction_for_neighborhood(destination_id, "City")
	var district = region.jurisdiction_for_neighborhood(destination_id, "Neighborhood")
	city.daily_fee_revenue += cars * city.parking_fee
	district.daily_fee_revenue += cars * district.parking_fee


static func collect_congestion(region, destination_city_id: int, cars: float, hour: int) -> void:
	var city = region.jurisdictions[region.city_jurisdiction_ids[destination_city_id]]
	if city.is_congestion_hour(hour):
		city.daily_fee_revenue += cars * city.congestion_fee


static func queue_policy(region, jurisdiction_id: int, property_name: String, value: float, current_unix_seconds: int) -> int:
	var tax_policy: bool = property_name in ["income_tax_rate", "property_tax_rate", "sales_tax_rate"]
	var effective_seconds: int = ((current_unix_seconds / 86400) + 1) * 86400 if tax_policy else ((current_unix_seconds / 900) + 1) * 900
	for index in range(region.pending_policy_changes.size() - 1, -1, -1):
		var pending: Dictionary = region.pending_policy_changes[index]
		if int(pending.get("jurisdiction_id", -1)) == jurisdiction_id and pending["property"] == property_name:
			region.pending_policy_changes.remove_at(index)
	region.pending_policy_changes.append({"jurisdiction_id": jurisdiction_id, "property": property_name, "value": value, "effective_seconds": effective_seconds})
	return effective_seconds


static func queue_toll(region, link_id: int, property_name: String, value: float, current_unix_seconds: int) -> int:
	var effective_seconds: int = ((current_unix_seconds / 900) + 1) * 900
	for index in range(region.pending_policy_changes.size() - 1, -1, -1):
		var pending: Dictionary = region.pending_policy_changes[index]
		if int(pending.get("link_id", -1)) == link_id and pending["property"] == property_name:
			region.pending_policy_changes.remove_at(index)
	region.pending_policy_changes.append({"link_id": link_id, "property": property_name, "value": value, "effective_seconds": effective_seconds})
	return effective_seconds


static func apply_due_policies(region, unix_seconds: int) -> bool:
	var changed := false
	var remaining: Array[Dictionary] = []
	for policy in region.pending_policy_changes:
		if int(policy["effective_seconds"]) <= unix_seconds:
			var property_name: String = str(policy["property"])
			var policy_value = int(policy["value"]) if property_name in ["congestion_start_hour", "congestion_end_hour"] else float(policy["value"])
			if policy.has("link_id"):
				for link in region.road_links:
					if link.id == int(policy["link_id"]):
						link.set(property_name, policy_value)
						break
			else:
				region.jurisdictions[int(policy["jurisdiction_id"])].set(property_name, policy_value)
			changed = true
		else:
			remaining.append(policy)
	region.pending_policy_changes = remaining
	return changed
