extends RefCounted
## Render-only curves. Simulation centerlines, water levels and crossings stay fixed.
const MAX_DEPTH = 12

static func prepare(feature: Dictionary) -> void:
	var points := PackedVector2Array()
	var widths := PackedFloat32Array()
	var supplied = feature.get("widths", [])
	var fallback: float = float(feature.get("meters", 1.0)) * .001
	for i in range(feature.points.size()):
		var width: float = maxf(.000001, float(supplied[i]) if supplied.size() == feature.points.size() else fallback)
		if not points.is_empty() and points[-1].distance_squared_to(feature.points[i]) < .000000000001:
			widths[-1] = maxf(widths[-1], width)
			continue
		points.append(feature.points[i])
		widths.append(width)
	var corners: Array[Dictionary] = []
	for i in range(points.size()):
		var before: Vector2 = points[i] - points[maxi(0, i-1)]
		var after: Vector2 = points[mini(points.size()-1, i+1)] - points[i]
		if i == 0: before = after
		if i == points.size()-1: after = before
		var incoming := before.normalized()
		var outgoing := after.normalized()
		var sine: float = sqrt(maxf(0.0,(1.0-incoming.dot(outgoing))*.5))
		# A tangent fillet avoids the tiny-radius cusps caused by clamping
		# cubic handles at a sharp vertex. Limit movement to 35% of the width.
		var trim := 0.0
		if i>0 and i<points.size()-1 and sine>.00001:
			trim = minf(minf(before.length(),after.length())*.35,widths[i]*.7/sine)
		corners.append({"entry":points[i]-incoming*trim,"exit":points[i]+outgoing*trim,"incoming":incoming.orthogonal(),"outgoing":outgoing.orthogonal(),"wa":lerpf(widths[maxi(0,i-1)],widths[i],1.0-trim/maxf(.000001,before.length())),"wb":lerpf(widths[i],widths[mini(points.size()-1,i+1)],trim/maxf(.000001,after.length())),"trim":trim})
	feature.points = points
	feature["widths"] = widths
	feature["river_corners"] = corners

static func coverage_margin(feature: Dictionary) -> float:
	var width := 0.0
	for value in feature.widths: width = maxf(width, value)
	return width * .85 + .04

static func segments(feature: Dictionary, rect: Rect2, ppk: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var points: PackedVector2Array = feature.points
	var corners: Array = feature.river_corners
	var tolerance: float = .25 / maxf(.001, ppk)
	for i in range(points.size()):
		var corner: Dictionary = corners[i]
		if i>0:
			var previous: Dictionary = corners[i-1]
			var a: Vector2 = previous.exit
			var b: Vector2 = corner.entry
			var margin: float = maxf(previous.wb,corner.wa)*.5+1.5/maxf(.001,ppk)
			if a.distance_squared_to(b)>.000000000001 and Rect2(a,Vector2.ZERO).expand(b).grow(margin).intersects(rect):
				result.append({"a":a,"b":b,"na":previous.outgoing,"nb":corner.incoming,"wa":previous.wb,"wb":corner.wa})
		if corner.trim>0.0:
			var a: Vector2 = corner.entry
			var b: Vector2 = corner.exit
			var p: Vector2 = a+(points[i]-a)*(2.0/3.0)
			var q: Vector2 = b+(points[i]-b)*(2.0/3.0)
			var margin: float = maxf(corner.wa,corner.wb)*.5+1.5/maxf(.001,ppk)
			_subdivide(result,[a,p,q,b],corner.wa,corner.wb,corner.incoming,corner.outgoing,rect,tolerance,margin,0)
	return result

static func _subdivide(result: Array[Dictionary], curve: Array, wa: float, wb: float, na: Vector2, nb: Vector2, rect: Rect2, tolerance: float, margin: float, depth: int) -> void:
	var a: Vector2 = curve[0]
	var p: Vector2 = curve[1]
	var q: Vector2 = curve[2]
	var b: Vector2 = curve[3]
	if not Rect2(a,Vector2.ZERO).expand(p).expand(q).expand(b).grow(margin).intersects(rect): return
	var error: float = maxf(p.distance_to(Geometry2D.get_closest_point_to_segment(p,a,b)), q.distance_to(Geometry2D.get_closest_point_to_segment(q,a,b)))
	var ap := a.lerp(p,.5)
	var pq := p.lerp(q,.5)
	var qb := q.lerp(b,.5)
	var left := ap.lerp(pq,.5)
	var right := pq.lerp(qb,.5)
	var middle := left.lerp(right,.5)
	var normal := (right-left).normalized().orthogonal()
	if normal == Vector2.ZERO: normal = na
	var width := (wa+wb)*.5
	for side in [-1.0,1.0]:
		var edge: Vector2 = middle + normal*width*.5*side
		error = maxf(error, edge.distance_to(Geometry2D.get_closest_point_to_segment(edge,a+na*wa*.5*side,b+nb*wb*.5*side)))
	if depth >= MAX_DEPTH or error <= tolerance:
		result.append({"a":a,"b":b,"na":na,"nb":nb,"wa":wa,"wb":wb})
		return
	_subdivide(result,[a,ap,left,middle],wa,width,na,normal,rect,tolerance,margin,depth+1)
	_subdivide(result,[middle,right,qb,b],width,wb,normal,nb,rect,tolerance,margin,depth+1)
