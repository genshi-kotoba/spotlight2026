shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
uniform sampler2D current_mask : filter_linear, repeat_disable;
uniform sampler2D previous_mask : filter_linear, repeat_disable;
// Current unblurred known-surface coverage is a strict guard. Only the
// visual field transitions; old coverage cannot authorize a removed surface.
uniform sampler2D current_guard : filter_linear, repeat_disable;
uniform sampler2D cloud_texture : filter_linear_mipmap, repeat_enable;
uniform vec4 current_bounds = vec4(-1.0, -1.0, 2.0, 2.0);
uniform vec4 previous_bounds = vec4(-1.0, -1.0, 2.0, 2.0);
uniform float transition = 1.0;
uniform vec2 actor_position = vec2(0.0);
uniform float focus_radius = 340.0;
uniform float light_radius = 165.0;
uniform float light_strength = 0.6;
uniform bool atmosphere_enabled = true;
// A still reference can freeze cloud motion without changing exploration.
uniform bool animate_clouds = true;
varying vec2 world_position;
void vertex() { world_position = VERTEX; }
float mask_at(sampler2D tex, vec2 p, vec4 bounds) {
 vec2 uv=(p-bounds.xy)/bounds.zw;
 if (any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) return 0.0;
 return texture(tex,uv).r;
}
void fragment() {
 vec2 p=world_position;
 float time=animate_clouds && atmosphere_enabled ? TIME : 0.0;
 // Density belongs to the map, never to the moving actor or screen. Large
 // stationary patches shape visibility; only their faint color detail drifts.
 vec2 warp=texture(cloud_texture,p/2200.0+vec2(.17,.63)).rg;
 vec2 warped=p+(warp-.5)*180.0;
 vec2 layers=texture(cloud_texture,warped/1500.0).rg;
 float broad=smoothstep(.25,.76,layers.r*.85+warp.g*.15);
 float density=mix(.55,2.4,broad);
 float detail=texture(cloud_texture,p/510.0+vec2(-time*.0012,time*.0008)).g;
 float cloud=clamp(broad*.80+detail*.20,0.0,1.0);
 // Exploration is independent of density, animation and illumination. Never
 // warp the authorization mask: upstream still omits all unknown geometry.
 float current=mask_at(current_mask,p,current_bounds);
 float previous=current;
 if (transition<.999) previous=mask_at(previous_mask,p,previous_bounds);
 float coverage=mix(previous,current,transition);
 float authorized=smoothstep(.08,.94,mask_at(current_guard,p,current_bounds));
 vec2 offset=p-actor_position;
 float distance=length(offset);
 float body_light=exp2(-3.2*dot(offset,offset)/(light_radius*light_radius))*light_strength;
 // Optical thickness approximation, not 3D ray marching. Nearby support is
 // clear. Beyond it, density controls BOTH gradual extinction and complete
 // closure. A radial clamp here would recreate the discarded circular rim.
 float reach=max(distance/focus_radius-.32,0.0)/.64;
 float distance_thickness=1.8*reach*reach*density;
 // Coverage is now normalized inward distance, not blurred occupancy.
 // Thus concave corners close at the same distance as straight edges.
 float edge_open=smoothstep(.06,mix(.72,.94,broad),coverage);
 float edge_thickness=4.5*(1.0-edge_open)*(1.0-edge_open);
 // One extinction field and one color: avoid piling two dark rims on top of
 // each other where range fog meets the exploration boundary.
 float thickness=length(vec2(distance_thickness,edge_thickness));
 float transmission=exp(-thickness)*(1.0-smoothstep(2.6,4.5,thickness));
 // density >= .55: thickness >= 4.5 by 1.685 * focus_radius. The invisible
 // safety bound follows from that lower limit; it is not a visible circle.
 float alpha=1.0-authorized*transmission;
 vec3 fog_color=mix(vec3(.074,.067,.058),vec3(.135,.120,.098),cloud);
 float daylight=.5+.5*sin(p.x/670.0+p.y/970.0+layers.g*.8);
 fog_color+=vec3(.010,.009,.008)*daylight;
 vec3 scatter=vec3(.34,.30,.24)*body_light*(.65+.35*cloud);
 if (!atmosphere_enabled) scatter=vec3(0.0);
 // Premultiplied scattering stays visible in thin, clear air as well as fog.
 // This brightens the veil only; it never subtracts unknown-space opacity.
 COLOR=vec4(fog_color*alpha+scatter*(.10+.90*alpha),alpha);
}
