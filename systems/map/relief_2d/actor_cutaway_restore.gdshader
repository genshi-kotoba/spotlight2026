shader_type canvas_item;
render_mode unshaded, blend_mix;
#include "res://systems/map/relief_2d/wall_cutaway.gdshaderinc"
uniform sampler2D actor_texture : filter_linear_mipmap, repeat_disable;
uniform vec4 frame_uv = vec4(0, 0, 1, 1);
uniform vec2 foot_origin;
uniform vec4 actor_tint : source_color = vec4(1);
varying vec2 map_point;
void vertex() { map_point = VERTEX + foot_origin; }
void fragment() {
 vec4 texel = texture(actor_texture, UV);
 if (any(lessThan(UV, frame_uv.xy)) || any(greaterThanEqual(UV, frame_uv.xy + frame_uv.zw))) texel.a = 0.0;
 COLOR = texel * actor_tint;
 COLOR.a *= (1.0 - cut_opacity) * cut_coverage(map_point, 1000000.0);
}
