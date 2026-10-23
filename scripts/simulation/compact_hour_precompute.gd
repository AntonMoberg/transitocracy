extends RefCounted

const RegionSnapshot = preload("res://scripts/simulation/region_snapshot.gd")
const CompactTrafficCalculator = preload("res://scripts/simulation/compact_traffic_calculator.gd")
const FiscalCalculator = preload("res://scripts/simulation/fiscal_calculator.gd")

var mutex := Mutex.new()
var snapshot_ready: bool = false
var cancelled: bool = false
var source_region
var source_flow
var source_day_key: int = -1
var ready_count: int = 0
var ready_links: Array[PackedVector2Array] = []
var ready_revenue: Array[Dictionary] = []


func bind_source(region, flow, day_key: int) -> void:
	source_region = region
	source_flow = flow
	source_day_key = day_key
	for _hour in range(24):
		ready_links.append(PackedVector2Array())
		ready_revenue.append({})


func mark_snapshot_ready() -> void:
	mutex.lock()
	snapshot_ready = true
	mutex.unlock()


func cancel() -> void:
	mutex.lock()
	cancelled = true
	mutex.unlock()


func status() -> Dictionary:
	mutex.lock()
	var result := {"snapshot_ready": snapshot_ready, "cancelled": cancelled, "ready_count": ready_count}
	mutex.unlock()
	return result


func publish_hour(hour: int, links: PackedVector2Array, revenue: Dictionary) -> void:
	mutex.lock()
	ready_links[hour] = links
	ready_revenue[hour] = revenue
	ready_count += 1
	mutex.unlock()


func snapshot_hours() -> Dictionary:
	mutex.lock()
	var result := {"count": ready_count, "links": ready_links.duplicate(), "revenue": ready_revenue.duplicate()}
	mutex.unlock()
	return result


static func prepare(region, flow, traffic_state, buffer) -> Dictionary:
	# Copy mutable region data before reading it on the worker. Edits wait only
	# for this short snapshot, while route work continues off the UI thread.
	var snapshot = RegionSnapshot.copy_region(region)
	buffer.mark_snapshot_ready()
	if buffer.status()["cancelled"]:
		return {}
	var first_hour: int = (traffic_state.unix_seconds % 86400) / 3600
	for hour in range(first_hour, 24):
		if buffer.status()["cancelled"]:
			return {}
		FiscalCalculator.apply_due_policies(snapshot, traffic_state.day_key * 86400 + hour * 3600)
		CompactTrafficCalculator.build_hour(snapshot, flow, traffic_state, 2, hour)
		buffer.publish_hour(hour, traffic_state.cached_links, traffic_state.cached_revenue)
	return {"region": region, "flow": flow, "day_key": traffic_state.day_key, "link_ids": traffic_state.link_ids}
