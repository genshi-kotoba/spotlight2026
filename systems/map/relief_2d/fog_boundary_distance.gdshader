shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D source_mask : filter_nearest, repeat_disable;
uniform vec2 texel_world = vec2(3.0);
uniform bool vertical_pass = false;
// A bounded separable Euclidean distance transform. Horizontal pass stores
// squared distance to a zero texel; vertical pass minimizes dx² + dy².
// Raster texels are at least 2.95 world pixels after size rounding. ±12
// covers the visible fade band (at most .94 * 36px). The outer distance cap
// is approximate; no field work runs during movement.
const float LIMIT = 36.0;
void fragment() {
 vec2 pixel_uv = 1.0 / vec2(textureSize(source_mask, 0));
 float closest = LIMIT * LIMIT;
 for (int i = -12; i <= 12; i++) {
  float offset = float(i);
  vec2 step_uv = vertical_pass ? vec2(0.0, offset * pixel_uv.y) : vec2(offset * pixel_uv.x, 0.0);
  float value = texture(source_mask, UV + step_uv).r;
  if (vertical_pass) {
   float dy = offset * texel_world.y;
   closest = min(closest, value * LIMIT * LIMIT + dy * dy);
  } else if (value < .5) {
   float dx = offset * texel_world.x;
   closest = min(closest, dx * dx);
  }
 }
 float result = vertical_pass ? sqrt(closest) / LIMIT : closest / (LIMIT * LIMIT);
 COLOR = vec4(vec3(result), 1.0);
}
