shader_type canvas_item;
render_mode unshaded;
uniform sampler2D source_mask : filter_linear, repeat_disable;
uniform vec2 step_uv;
void fragment() {
 float v=texture(source_mask,UV).r*.227027;
 v+=(texture(source_mask,UV+step_uv).r+texture(source_mask,UV-step_uv).r)*.1945946;
 v+=(texture(source_mask,UV+step_uv*2.0).r+texture(source_mask,UV-step_uv*2.0).r)*.1216216;
 v+=(texture(source_mask,UV+step_uv*3.0).r+texture(source_mask,UV-step_uv*3.0).r)*.054054;
 v+=(texture(source_mask,UV+step_uv*4.0).r+texture(source_mask,UV-step_uv*4.0).r)*.016216;
 COLOR=vec4(v,v,v,1.0);
}
