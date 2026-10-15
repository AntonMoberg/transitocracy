extends RefCounted

const START_DATE = {"year": 2030, "month": 1, "day": 1, "hour": 7, "minute": 0, "second": 0}
const WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var unix_seconds: int = 0
var fractional_second: float = 0.0


func _init() -> void:
	reset()


func reset() -> void:
	unix_seconds = Time.get_unix_time_from_datetime_dict(START_DATE)
	fractional_second = 0.0


func advance_simulation_seconds(seconds: float) -> void:
	var elapsed: float = fractional_second + maxf(0.0, seconds)
	var whole_seconds := floori(elapsed)
	unix_seconds += whole_seconds
	fractional_second = elapsed - whole_seconds


func advance_hour() -> void:
	unix_seconds += 3600


func set_hour(hour: int) -> void:
	set_time(hour, 0)


func set_time(hour: int, minute: int) -> void:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(unix_seconds)
	unix_seconds += (clampi(hour, 0, 23) - int(date["hour"])) * 3600
	unix_seconds += (clampi(minute, 0, 59) - int(date["minute"])) * 60
	unix_seconds -= int(date["second"])
	fractional_second = 0.0


func get_hour() -> int:
	return int(Time.get_datetime_dict_from_unix_time(unix_seconds)["hour"])


func get_minute() -> int:
	return int(Time.get_datetime_dict_from_unix_time(unix_seconds)["minute"])


func get_hour_fraction() -> float:
	return (float(unix_seconds % 3600) + fractional_second) / 3600.0


func is_weekend() -> bool:
	return is_weekend_unix(unix_seconds)


static func is_weekend_unix(seconds: int) -> bool:
	var weekday: int = Time.get_datetime_dict_from_unix_time(seconds)["weekday"]
	return weekday == 0 or weekday == 6


func get_display_text() -> String:
	var date: Dictionary = Time.get_datetime_dict_from_unix_time(unix_seconds)
	return "%s %d %s %d  •  %02d:%02d" % [
		WEEKDAY_NAMES[date["weekday"]], date["day"], MONTH_NAMES[date["month"] - 1], date["year"], date["hour"], date["minute"]
	]
