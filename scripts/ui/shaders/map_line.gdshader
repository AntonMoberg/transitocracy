shader_type canvas_item;
render_mode unshaded;

uniform float pixels_per_km = 1.0;
uniform bool satellite = false;
uniform bool traffic_enabled = false;
uniform bool trips = false;
uniform sampler2D traffic_previous : filter_nearest, repeat_disable;
uniform sampler2D traffic_current : filter_nearest, repeat_disable;
uniform float traffic_mix = 1.0;
uniform float traffic_height = 2.0;
instance uniform vec4 clip_rect;
uniform int selected_slot = -1;
varying vec2 world_position;
varying flat vec4 attributes;
varying float side;
varying flat float half_width;

// UV is the miter normal. CUSTOM0 stores width in meters, minimum pixel width,
// traffic slot + 1, and pass (0 border/water, 1 casing, 2 forward, 3 reverse, 4 road bed).
void vertex() {
	attributes = CUSTOM0;
	side = CUSTOM1.x;
	half_width = max(CUSTOM0.r * pixels_per_km * 0.001, CUSTOM0.g);
	VERTEX += UV * (half_width + 0.75) / pixels_per_km;
	world_position = VERTEX;
	COLOR = vec4(1.0);
}

void fragment() {
	if (world_position.x < clip_rect.x || world_position.y < clip_rect.y ||
		world_position.x >= clip_rect.z || world_position.y >= clip_rect.w) discard;
	float pass = attributes.a;
	int slot = int(attributes.b) - 1;
	vec4 color = vec4(0.64, 0.68, 0.70, 1.0);
	if (pass < 0.5) {
		// Negative slots encode water / administrative borders / bridge decks.
		color = slot == -2 ? (satellite ? vec4(0.29,0.51,0.56,1.0) : vec4(0.42,0.76,0.86,1.0)) : vec4(0.60,0.67,0.62,0.24);
		if (slot == -3) color = vec4(0.72,0.79,0.82,1.0);
		if (slot == -4) color = vec4(0.66,0.85,0.89,0.82);
		if (slot == -5) color = vec4(0.71,0.64,0.80,0.72);
	} else if (pass < 1.5) {
		color = satellite ? vec4(0.09,0.15,0.17,1.0) : vec4(0.77,0.80,0.76,1.0);
	} else {
		if (traffic_enabled && slot >= 0) {
			vec2 uv = vec2((float(slot % 256) + 0.5) / 256.0, (float(slot / 256) * 2.0 + (pass < 2.5 ? 0.5 : 1.5)) / traffic_height);
			color = mix(texture(traffic_previous, uv), texture(traffic_current, uv), traffic_mix);
			if (pass > 3.5) {
				vec2 other_uv = vec2(uv.x, (float(slot / 256) * 2.0 + 0.5) / traffic_height);
				color = mix(color, mix(texture(traffic_previous, other_uv), texture(traffic_current, other_uv), traffic_mix), 0.5);
			}
		} else {
			color = satellite ? vec4(0.65,0.70,0.67,1.0) : vec4(0.51,0.58,0.69,1.0);
		}
		if (slot == selected_slot && slot >= 0) color = vec4(0.97,0.89,0.63,1.0);
	}
	if (trips) color.a *= 0.23;
	color.a *= 1.0 - smoothstep(max(0.0, half_width - 0.5), half_width + 0.5, abs(side) * (half_width + 0.75));
	COLOR = color;
}
