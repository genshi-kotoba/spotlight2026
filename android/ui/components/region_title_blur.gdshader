shader_type canvas_item;
render_mode unshaded;
uniform float radius_px : hint_range(0.0, 8.0) = 0.0;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	// 对独立标题纹理采样，避免在字体图集上模糊而串入邻近字形。
	vec2 step_uv = TEXTURE_PIXEL_SIZE * radius_px;
	float alpha = texture(TEXTURE, UV).a * 0.25;
	alpha += texture(TEXTURE, UV + vec2(step_uv.x, 0.0)).a * 0.125;
	alpha += texture(TEXTURE, UV - vec2(step_uv.x, 0.0)).a * 0.125;
	alpha += texture(TEXTURE, UV + vec2(0.0, step_uv.y)).a * 0.125;
	alpha += texture(TEXTURE, UV - vec2(0.0, step_uv.y)).a * 0.125;
	alpha += texture(TEXTURE, UV + step_uv).a * 0.0625;
	alpha += texture(TEXTURE, UV - step_uv).a * 0.0625;
	alpha += texture(TEXTURE, UV + vec2(step_uv.x, -step_uv.y)).a * 0.0625;
	alpha += texture(TEXTURE, UV + vec2(-step_uv.x, step_uv.y)).a * 0.0625;
	COLOR = vec4(tint.rgb, alpha * tint.a);
}
