extends RefCounted

# A bounded handoff queue between the seven-day producer and the UI thread.
var mutex := Mutex.new()
var ready_days: Array[Dictionary] = []
var cancelled: bool = false
var produced_days: int = 0
var produced_at_msec: int = 0
var work_started_at_msec: int = Time.get_ticks_msec()
var production_rate: float = 1.0


func begin_day() -> void:
	mutex.lock()
	work_started_at_msec = Time.get_ticks_msec()
	mutex.unlock()


func publish(result: Dictionary) -> bool:
	mutex.lock()
	if cancelled:
		mutex.unlock()
		return false
	var now: int = Time.get_ticks_msec()
	var interval: int = now - work_started_at_msec
	var sample_rate: float = 1000.0 / maxf(1.0, float(interval))
	production_rate = lerpf(production_rate, sample_rate, 0.35 if produced_days > 0 else 0.7)
	produced_at_msec = now
	produced_days += 1
	ready_days.append(result)
	mutex.unlock()
	return true


func take(day_key: int) -> Dictionary:
	mutex.lock()
	var result: Dictionary = {}
	if not ready_days.is_empty() and ready_days[0]["traffic_state"].day_key == day_key:
		result = ready_days.pop_front()
	mutex.unlock()
	return result


func status() -> Dictionary:
	mutex.lock()
	var result := {"ready": ready_days.size(), "rate": production_rate, "cancelled": cancelled}
	mutex.unlock()
	return result


func snapshot_flows() -> Dictionary:
	# Published flow profiles are immutable. Retain references while the UI
	# reads daily totals, without holding the producer's mutex for that work.
	mutex.lock()
	var flows := {}
	for result in ready_days:
		flows[result["traffic_state"].day_key] = result["flow"]
	mutex.unlock()
	return flows


func cancel() -> void:
	mutex.lock()
	cancelled = true
	mutex.unlock()


func discard_ready_on_worker() -> void:
	mutex.lock()
	ready_days.clear()
	mutex.unlock()
