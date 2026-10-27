shader_type canvas_item;
render_mode unshaded;
uniform float pixels_per_km = 1.0;
uniform bool zoning = false;
uniform bool traffic_enabled = false;
varying flat int fill_role;
void vertex() {
	fill_role = int(UV.x);
}
void fragment() {
	if (fill_role == 5) COLOR.a *= traffic_enabled ? smoothstep(500.0,550.0,pixels_per_km) : 0.0;
	if (fill_role == 6) COLOR.a *= smoothstep(500.0,650.0,pixels_per_km);
	if (fill_role == 7) COLOR.a *= smoothstep(2000.0,2400.0,pixels_per_km);
	// Clearance is land reserved beside a road, not a second asphalt bed.
	if (fill_role == 3) COLOR.rgb = vec3(0.89,0.91,0.90);
	if (fill_role == 2) {
		if (!zoning && COLOR.a > 0.9) COLOR.rgb = vec3(0.906,0.910,0.929);
		COLOR.a *= smoothstep(160.0,220.0,pixels_per_km);
	}
}
