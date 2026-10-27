extends RefCounted
## World-space dimensions shared by buildings and cartography, in metres.
static func carriageway(road_class:String, lanes:int=1) -> float:
	return lanes*2.0*(3.6 if road_class=="Highway" else 3.25)+(3.0 if road_class=="Highway" else .7)

static func sidewalk(road_class:String) -> float:
	return 0.0 if road_class=="Highway" else 2.0

static func exclusion(points:PackedVector2Array,road_class:String,lanes:int=1) -> Array[PackedVector2Array]:
	return Geometry2D.offset_polyline(points,(carriageway(road_class,lanes)*.5+sidewalk(road_class)+.5)*.001,Geometry2D.JOIN_ROUND,Geometry2D.END_ROUND)
