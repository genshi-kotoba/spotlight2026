// Affine depth plus map coordinates reconstruct the same 3D position used
// by CPU solar baking. No screen-distance approximation across raised walls.
uniform vec3 light_basis_x;
uniform vec3 light_basis_y;
uniform vec3 light_basis_depth;
uniform vec3 surface_light_position;
uniform float surface_light_range = 2.2;
uniform float surface_light_strength = 0.0;
uniform float light_cell_radius = 1.0;
uniform int light_column_count = 0;
uniform vec4 light_columns[19];

vec2 light_slab(vec2 interval, float origin, float ray, float low, float high) {
 if (abs(ray)<0.00001) {
  if (origin<low || origin>high) return vec2(1.0,0.0);
  return interval;
 }
 vec2 hit=vec2(low-origin,high-origin)/ray;
 return vec2(max(interval.x,min(hit.x,hit.y)),min(interval.y,max(hit.x,hit.y)));
}
bool light_blocked(vec3 receiver) {
 vec3 origin=surface_light_position;
 vec3 ray=receiver-origin;
 for(int i=0;i<19;i++) {
  if(i>=light_column_count)break;
  vec4 column=light_columns[i];
  // End point inset prevents a receiver's own face from self-shadowing.
  vec2 hit=light_slab(vec2(0.001,0.999),origin.y,ray.y,column.z,column.w);
  if(hit.x>hit.y)continue;
  vec2 o=origin.xz-column.xy;
  vec3 a=vec3(o.x+o.y*0.577350269,o.x-o.y*0.577350269,o.y*1.154700538);
  vec3 d=vec3(ray.x+ray.z*0.577350269,ray.x-ray.z*0.577350269,ray.z*1.154700538);
  float r=light_cell_radius;
  hit=light_slab(hit,a.x,d.x,-r,r);
  hit=light_slab(hit,a.y,d.y,-r,r);
  hit=light_slab(hit,a.z,d.z,-r,r);
  if(hit.x<=hit.y)return true;
 }
 return false;
}
vec3 actor_surface_radiance(vec2 point,float depth,vec4 normal_data,vec3 albedo) {
 if(surface_light_strength<=0.0 || normal_data.w<0.5)return vec3(0.0);
 vec3 receiver=light_basis_x*point.x+light_basis_y*point.y+light_basis_depth*depth;
 vec3 light_ray=surface_light_position-receiver;
 float d=length(light_ray);
 if(d>=surface_light_range || d<0.0001)return vec3(0.0);
 float incidence=max(0.0,dot(normalize(normal_data.xyz),light_ray/d));
 if(incidence<0.001 || light_blocked(receiver+normalize(normal_data.xyz)*0.003))return vec3(0.0);
 float falloff=1.0-smoothstep(0.18,surface_light_range,d);
 return albedo*vec3(0.96,0.82,0.62)*surface_light_strength*1.2*falloff*incidence;
}
