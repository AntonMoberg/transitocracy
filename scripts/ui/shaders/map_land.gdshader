shader_type canvas_item;
render_mode unshaded;

uniform vec4 land_color : source_color;
uniform vec4 woods_color : source_color;
uniform vec4 open_color : source_color;
uniform vec4 rock_color : source_color;

// Coverage fields, not preblended display colors. Classifying after filtering
// keeps even a retained parent tile crisp, with a screen-pixel AA fringe.
float boundary(float value, float threshold) {
	float width = max(fwidth(value), 0.00001);
	return smoothstep(threshold - width * 0.5, threshold + width * 0.5, value);
}

void fragment() {
	vec2 size = vec2(textureSize(TEXTURE, 0));
	vec2 uv = (UV * (size - 2.0) + 1.0) / size;
	vec4 field = texture(TEXTURE, uv);
	vec3 color = mix(land_color.rgb, open_color.rgb, boundary(field.g, 0.38));
	color = mix(color, woods_color.rgb, boundary(field.r, 0.30));
	color = mix(color, rock_color.rgb, boundary(field.b, 0.35));
	COLOR = vec4(color * mix(0.94, 1.06, field.a), 1.0);
}
