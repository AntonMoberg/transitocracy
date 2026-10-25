shader_type canvas_item;
render_mode unshaded;
uniform bool satellite = false;
uniform bool zoning = false;
instance uniform int fill_role = 0;
void fragment() {
	if (satellite && fill_role == 0) COLOR.rgb = vec3(0.28, 0.49, 0.55);
	if (satellite && fill_role == 1) COLOR.rgb *= vec3(0.54, 0.65, 0.52);
	if (!zoning && fill_role == 2 && COLOR.a > 0.9) COLOR.rgb = mix(COLOR.rgb, vec3(0.68,0.69,0.63), 0.2);
}
