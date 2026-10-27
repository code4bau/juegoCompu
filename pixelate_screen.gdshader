shader_type canvas_item;

uniform float pixel_size : hint_range(1.0, 15.0) = 15.0;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D ca_texture : repeat_disable, filter_nearest;

void fragment() {
	float ca_state = texture(ca_texture, SCREEN_UV).r;
	float active_front = step(0.15, ca_state);

	if (active_front < 0.5) {
		COLOR = texture(screen_texture, SCREEN_UV);
	} else {
		vec2 text_size = vec2(textureSize(screen_texture, 0));
		vec2 target_res = text_size / pixel_size;
		
		vec2 block_index = floor(SCREEN_UV * target_res);
		vec2 grid_uv = (block_index + 0.5) / target_res;
		
		vec4 col = texture(screen_texture, grid_uv);
		
		// Coordenadas locales [0,1] dentro del bloque para generar relieve de celda opaca
		vec2 block_uv = fract(SCREEN_UV * target_res);
		float border = step(0.05, block_uv.x) * step(0.05, block_uv.y) * step(block_uv.x, 0.95) * step(block_uv.y, 0.95);
		
		// Bloque sólido con bisel oscuro que marca el límite físico de cada píxel
		vec3 color_solido = mix(col.rgb * 0.65, col.rgb, border);
		
		COLOR = vec4(color_solido, 1.0);
	}
}