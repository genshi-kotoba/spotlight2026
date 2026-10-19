// Matte stone finish. All scales use the reconstructed fixed world position,
// so neither the wall texture bands nor the camera restart the surface detail.
float masonry_hash(vec2 p) {
 vec3 h=fract(vec3(p.xyx)*0.1031);
 h+=dot(h,h.yzx+33.33);
 return fract((h.x+h.y)*h.z);
}
float masonry_facets(vec2 p) {
 vec2 cell=floor(p);
 vec2 f=fract(p);
 float a=masonry_hash(cell);
 float b=masonry_hash(cell+vec2(1.0,0.0));
 float c=masonry_hash(cell+vec2(0.0,1.0));
 float d=masonry_hash(cell+vec2(1.0));
 // Continuous triangular planes make broad chisel facets, without a mortar
 // grid, isolated dark dots, or a new texture/geometry allocation.
 float lower=a+(b-a)*f.x+(c-a)*f.y;
 float upper=d+(c-d)*(1.0-f.x)+(b-d)*(1.0-f.y);
 return mix(lower,upper,step(1.0,f.x+f.y));
}
float masonry_grain(vec2 p) {
 vec2 cell=floor(p);
 vec2 f=fract(p);
 f=f*f*(3.0-2.0*f);
 return mix(mix(masonry_hash(cell),masonry_hash(cell+vec2(1.0,0.0)),f.x),
            mix(masonry_hash(cell+vec2(0.0,1.0)),masonry_hash(cell+vec2(1.0)),f.x),f.y);
}
float masonry_chips(vec2 p,float pixel_width) {
 // A second, rotated field cuts broad polygonal flakes into the stone. The
 // two levels form recessed and raised planes rather than isolated speckles.
 // Continuous world phase crosses texture bands and shadow/cutaway packets.
 vec2 chipped=vec2(p.x*0.93-p.y*0.38,p.x*0.38+p.y*0.93)*4.5+vec2(17.3,-8.1);
 float field=masonry_facets(chipped);
 float aa=clamp(pixel_width*1.8,0.005,0.15);
 float face=smoothstep(0.34-aa,0.34+aa,field);
 float raised=smoothstep(0.66-aa,0.66+aa,field);
 return 0.78+0.25*face+0.17*raised;
}
vec3 masonry_albedo(vec3 painted,vec3 world,vec3 normal,float radius,float wall_material) {
 vec3 p=world/max(radius,0.001);
 vec2 tangent=vec2(normal.z,-normal.x);
 vec2 face=vec2(dot(p.xz,tangent),p.y);
 vec2 top=vec2(p.x+p.z*0.21,p.z-p.x*0.17);
 vec2 uv=mix(face*vec2(1.35,1.85),top*1.55,clamp(abs(normal.y),0.0,1.0));
 vec2 grain_uv=uv*96.0;
 // Derivatives are evaluated for every fragment by the caller. Let grain
 // disappear below pixel scale instead of flickering during movement/zoom.
 vec2 surface_footprint=fwidth(uv);
 vec2 footprint=surface_footprint*96.0;
 if (wall_material<0.5) return painted;
 float facets=masonry_facets(uv);
 float chips=masonry_chips(uv,max(surface_footprint.x,surface_footprint.y));
 float grain_weight=1.0-smoothstep(0.35,1.15,max(footprint.x,footprint.y));
 float grain=(masonry_grain(grain_uv)-0.5)*0.025*grain_weight;
 float value=dot(painted,vec3(0.2126,0.7152,0.0722));
 vec3 stone=mix(painted,vec3(value),0.60)*vec3(0.79,0.75,0.69);
 // Stronger broad planes plus middle-scale chips carry the finish even in
 // actor light, which receives this same albedo. Grain stays subordinate.
 float finish=(0.76+0.48*facets)*chips*0.95+grain;
 float strength=mix(0.42,0.20,clamp(abs(normal.y),0.0,1.0));
 return stone*mix(1.0,finish,strength);
}
