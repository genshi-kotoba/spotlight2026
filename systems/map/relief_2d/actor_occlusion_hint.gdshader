shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D actor_texture : filter_linear_mipmap, repeat_disable;
uniform vec4 frame_uv = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 hint_color : source_color = vec4(0.55, 0.88, 0.96, 1.0);

float frame_alpha(vec2 uv) {
	// Atlas neighbours must never contribute another animation's outline.
	if (any(lessThan(uv, frame_uv.xy)) || any(greaterThanEqual(uv, frame_uv.xy + frame_uv.zw))) {
		return 0.0;
	}
	return texture(actor_texture, uv).a;
}

void fragment() {
	float a = frame_alpha(UV);
	// Inner contour: never grow into empty pixels or outside the true blocker.
	// Screen derivatives keep the cue narrow while scrolling the camera zoom.
	vec2 step_uv = min(TEXTURE_PIXEL_SIZE * 1.25, (abs(dFdx(UV)) + abs(dFdy(UV))) * 1.35);
	float inside = a;
	inside = min(inside, frame_alpha(UV + vec2(step_uv.x, 0.0)));
	inside = min(inside, frame_alpha(UV - vec2(step_uv.x, 0.0)));
	inside = min(inside, frame_alpha(UV + vec2(0.0, step_uv.y)));
	inside = min(inside, frame_alpha(UV - vec2(0.0, step_uv.y)));
	inside = min(inside, frame_alpha(UV + step_uv));
	inside = min(inside, frame_alpha(UV - step_uv));
	inside = min(inside, frame_alpha(UV + vec2(step_uv.x, -step_uv.y)));
	inside = min(inside, frame_alpha(UV + vec2(-step_uv.x, step_uv.y)));
	float edge = clamp(a - inside, 0.0, 1.0);
	// A faint interior keeps very small feet readable, without restoring the
	// original sprite's solid colours over the opaque wall.
	COLOR = vec4(hint_color.rgb, a * 0.10 + edge * 0.68);
}
