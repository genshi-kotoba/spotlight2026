shader_type canvas_item;
render_mode unshaded;
#include "res://systems/map/relief_2d/wall_cutaway.gdshaderinc"
#include "res://systems/map/relief_2d/actor_surface_light.gdshaderinc"
#include "res://systems/map/relief_2d/masonry_finish.gdshaderinc"
varying vec4 vertex_tint;
varying vec4 light_normal;
varying vec2 map_point;
varying vec3 surface_data;
void vertex() {
 vertex_tint = COLOR;
 map_point = VERTEX;
 surface_data = CUSTOM0.xyz;
 light_normal = CUSTOM1;
}
void fragment() {
 vec4 texel = UV.x < 0.0 ? vec4(1.0) : texture(TEXTURE, UV);
 vec3 world=light_basis_x*map_point.x+light_basis_y*map_point.y+light_basis_depth*surface_data.y;
 // Evaluate derivatives outside the per-surface branch. Only actual textured
 // wall columns receive the finish; ground, cliffs and props keep their art.
 float wall_material=step(0.5,surface_data.x)*step(0.0,UV.x);
 vec3 albedo=masonry_albedo(texel.rgb,world,light_normal.xyz,light_cell_radius,wall_material);
 COLOR = vec4(albedo,texel.a) * vertex_tint;
 // A shallow material-colored root cue keeps the physical edge readable.
 // Apply it before local light so the actor can illuminate this receiver;
 // baked solar tint/shadows and the point light's occlusion stay intact.
 if (surface_data.z > 0.5) COLOR.rgb *= 1.0 - 0.24 * wall_contact(map_point, surface_data.y);
 // Bounded response keeps painted detail at maximum strength.
 COLOR.rgb += (vec3(1.0)-COLOR.rgb)*actor_surface_radiance(map_point,surface_data.y,light_normal,albedo);
 if (surface_data.x > 0.5) {
  COLOR.a *= mix(1.0, cut_opacity, wall_cut_coverage(map_point, surface_data.y));
 }
}
