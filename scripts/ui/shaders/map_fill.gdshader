shader_type canvas_item;
render_mode unshaded;
uniform float pixels_per_km = 1.0;
uniform bool zoning = false;
instance uniform int fill_role = 0;
void fragment() {
	if (fill_role == 5) COLOR.a *= smoothstep(500.0,550.0,pixels_per_km);
	// Clearance is land reserved beside a road, not a second asphalt bed.
	if (fill_role == 3) COLOR.rgb = vec3(0.89,0.91,0.90);
	if (!zoning && fill_role == 2 && COLOR.a > 0.9) COLOR.rgb = vec3(0.86,0.86,0.84);
}
