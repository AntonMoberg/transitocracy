extends RefCounted

var day_key: int = -1
var next_bin: int = 0
var first_recorded_bin: int = 0
var link_ids: PackedInt32Array = PackedInt32Array()
var queues: Array = [] # Two FIFO cohort arrays per road link.
var scheduled: Dictionary = {} # Absolute quarter-hour tick -> cohorts arriving at a link or destination.
var stranded: Array = []
var revenue_by_bin: Dictionary = {} # Local bin -> jurisdiction -> revenue category -> dollars.
var checkpoints: Dictionary = {} # End of bin -> enough state to invalidate later forecasts.
var route_hour: int = -1
var route_paths: Array = []
var departure_templates: Array = []
var noncar_sales: Dictionary = {}
var profile
var departed_cars: float = 0.0
var completed_cars: float = 0.0


func queued_cars() -> float:
	var total := 0.0
	for lane_queue in queues:
		for cohort in lane_queue:
			total += float(cohort["count"])
	return total


func scheduled_cars() -> float:
	var total := 0.0
	for arrivals in scheduled.values():
		for cohort in arrivals:
			total += float(cohort["count"])
	return total


func stranded_cars() -> float:
	var total := 0.0
	for cohort in stranded:
		total += float(cohort["count"])
	return total
