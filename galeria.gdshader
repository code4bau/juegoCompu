shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D tex_albedo : source_color, filter_nearest;
uniform float pixel_size : hint_range(1.0, 128.0) = 1.0;

void fragment() {
	vec2 uv = UV;

	if (pixel_size > 1.0) {
		vec2 size = vec2(textureSize(tex_albedo, 0));
		if (size.x > 1.0 && size.y > 1.0) {
			vec2 target_res = size / pixel_size;
			uv = floor(UV * target_res) / target_res;
		}
	}

	ALBEDO = texture(tex_albedo, uv).rgb;
}