extends Node2D
## Exploration remains authoritative upstream. Actor light can brighten the
## opaque fog, but never authorize new geometry or nodes.
const VeilShader = preload("res://systems/map/relief_2d/fog_veil.gdshader")
const BoundaryShader = preload("res://systems/map/relief_2d/fog_boundary_distance.gdshader")
const TRANSITION_SECONDS := 0.18
## 进入新图时角色光从全暗拉到目标强度的时长。
const FOCUS_FADE_SECONDS := 0.35
const TARGET_TEXEL_SIZE := 3.0
const MAX_MASK_AXIS := 1536
const BOUNDARY_DISTANCE := 24.0
const CLOUD_PATH := "res://assets/environment/env005/atmosphere-cloud.png"
var _views: Array[SubViewport] = []
var _masks: Array[MeshInstance2D] = []
var _distance_views: Array = []
var _distance_rects: Array = []
var _bounds: Array[Rect2] = [Rect2(-1,-1,2,2),Rect2(-1,-1,2,2)]
var _active := -1
var _elapsed := TRANSITION_SECONDS
var _material: ShaderMaterial
var _view_rectangle := Rect2(-10000,-10000,20000,20000)
var sync_count := 0
var build_ms := 0.0
var polygon_count := 0
var _cloud_texture: ImageTexture
var _focus_position := Vector2(INF, INF)
var _focus_strength := -1.0
## 焦点强度的入场渐变进度，1 表示已经到位。
var _focus_fade := 1.0
var _focus_radius := 340.0
var _atmosphere_enabled := true

func _init() -> void:
 z_index=200
 set_process(false)

func _ready() -> void:
 _material=ShaderMaterial.new();_material.shader=VeilShader;material=_material
 _material.set_shader_parameter("focus_radius",_focus_radius)
 var cloud:=Image.new()
 if cloud.load_png_from_buffer(FileAccess.get_file_as_bytes(CLOUD_PATH))==OK:
  cloud.generate_mipmaps()
  _cloud_texture=ImageTexture.create_from_image(cloud)
  _material.set_shader_parameter("cloud_texture",_cloud_texture)
 for i in 2:
  var viewport:=SubViewport.new()
  viewport.disable_3d=true;viewport.transparent_bg=false
  viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
  viewport.render_target_clear_mode=SubViewport.CLEAR_MODE_ALWAYS
  viewport.size=Vector2i(2,2)
  add_child(viewport);_views.append(viewport)
  var black:=Polygon2D.new();black.polygon=PackedVector2Array([Vector2.ZERO,Vector2(2048,0),Vector2(2048,2048),Vector2(0,2048)]);black.color=Color.BLACK
  viewport.add_child(black)
  var mesh:=MeshInstance2D.new();viewport.add_child(mesh);_masks.append(mesh)
  var pair=[];var rects=[];var input_view:SubViewport=viewport
  for axis in 2:
   var distance_view:=SubViewport.new();distance_view.disable_3d=true;distance_view.size=Vector2i(2,2)
   distance_view.render_target_update_mode=SubViewport.UPDATE_DISABLED
   add_child(distance_view);pair.append(distance_view)
   var rect:=ColorRect.new();rect.mouse_filter=Control.MOUSE_FILTER_IGNORE;rect.size=Vector2(2,2)
   var distance_material:=ShaderMaterial.new();distance_material.shader=BoundaryShader
   distance_material.set_shader_parameter("vertical_pass",axis==1)
   distance_material.set_shader_parameter("source_mask",input_view.get_texture());rect.material=distance_material
   distance_view.add_child(rect);rects.append(rect);input_view=distance_view
  _distance_views.append(pair);_distance_rects.append(rects)
 hide()

func sync(source, animate: bool = true) -> void:
 if not is_inside_tree(): return
 var start:=Time.get_ticks_usec()
 var vertices:=PackedVector2Array();var indices:=PackedInt32Array()
 var bounds:=Rect2();var have_bounds:=false;polygon_count=0
 for face: Dictionary in source._faces:
  if not face.get("known",false) or face.has("rock") or face.get("node_marker",false): continue
  # Internal steps are visible known surfaces, not discovery holes. Keep
  # exterior/unknown-facing cliffs out so the deep slab still fades away.
  if face.get("category","")=="terrain_side" and not _known_step(source,face): continue
  # The deep site slab should disappear into fog, not extend the discovery
  # silhouette down to its distant base. Authorized buildings remain visible.
  if face.get("scenery",false) and face.get("scene_role","")=="site": continue
  for polygon: PackedVector2Array in source._fog_surface_regions(face,face.polygon):
   if polygon.size()<3:continue
   var first:=vertices.size();vertices.append_array(polygon)
   for point in polygon:
    bounds=bounds.expand(point) if have_bounds else Rect2(point,Vector2.ZERO);have_bounds=true
   for i in range(1,polygon.size()-1): indices.append_array(PackedInt32Array([first,first+i,first+i+1]))
   polygon_count+=1
 if not have_bounds: hide();return
 bounds=bounds.grow(96.0)
 var previous:=_active;_active=(_active+1)%2;_bounds[_active]=bounds
 var size:=Vector2i(maxi(2,ceili(bounds.size.x/TARGET_TEXEL_SIZE)),maxi(2,ceili(bounds.size.y/TARGET_TEXEL_SIZE)))
 var shrink:=minf(1.0,float(MAX_MASK_AXIS)/maxi(size.x,size.y));size=Vector2i(Vector2(size)*shrink)
 _views[_active].size=size
 var scale:=Vector2(size)/bounds.size
 for i in vertices.size(): vertices[i]=(vertices[i]-bounds.position)*scale
 var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_INDEX]=indices
 var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
 _masks[_active].mesh=mesh
 _views[_active].render_target_update_mode=SubViewport.UPDATE_ONCE
 for axis in 2:
  _distance_views[_active][axis].size=size
  _distance_rects[_active][axis].size=Vector2(size)
  _distance_rects[_active][axis].material.set_shader_parameter("texel_world",bounds.size/Vector2(size))
  _distance_views[_active][axis].render_target_update_mode=SubViewport.UPDATE_ONCE
 _material.set_shader_parameter("current_mask",_distance_views[_active][1].get_texture())
 _material.set_shader_parameter("current_guard",_views[_active].get_texture())
 _material.set_shader_parameter("current_bounds",Vector4(bounds.position.x,bounds.position.y,bounds.size.x,bounds.size.y))
 _elapsed=0.0 if animate and previous>=0 else TRANSITION_SECONDS
 var before:=previous if previous>=0 else _active
 var old:=_bounds[before]
 _material.set_shader_parameter("previous_mask",_distance_views[before][1].get_texture())
 _material.set_shader_parameter("previous_bounds",Vector4(old.position.x,old.position.y,old.size.x,old.size.y))
 _material.set_shader_parameter("transition",_elapsed/TRANSITION_SECONDS)
 set_process(_elapsed<TRANSITION_SECONDS or _focus_fade<1.0);show();queue_redraw();sync_count+=1
 build_ms=(Time.get_ticks_usec()-start)/1000.0

func _known_step(source, face: Dictionary) -> bool:
 # Support and outward normal survive scenery clipping; polygon centroids
 # do not. A hex edge normal points at the neighboring cell's center.
 var normal: Vector3=face.normal
 var direction:=Vector2(normal.x,normal.z).normalized()
 var neighbor: Vector2i=source._plane_coord(Vector2(face.support)+direction*sqrt(3.0)*source._radius)
 var key: String=source._key(neighbor)
 return source._cells.has(key) and bool(source._known.get(key,false))

func set_view(rectangle: Rect2) -> void:
 var expanded:=rectangle.grow(4.0)
 if _view_rectangle==expanded:return
 _view_rectangle=expanded;queue_redraw()
  # Camera zoom only changes overlay coverage, never the visibility range.

func set_focus(position: Vector2, strength: float) -> void:
 if _material==null:return
 if not position.is_equal_approx(_focus_position):
  _focus_position=position
  _material.set_shader_parameter("actor_position",position)
 if not is_equal_approx(strength,_focus_strength):
  _focus_strength=clampf(strength,0.0,1.0)
  _apply_focus()

## 进入新图时把角色光从全暗拉起，免得光圈硬切上来。
func fade_focus_in() -> void:
 if _material==null:return
 _focus_fade=0.0
 _apply_focus()
 set_process(true)

func _apply_focus() -> void:
 _material.set_shader_parameter("light_strength",clampf(_focus_strength,0.0,1.0)*_focus_fade)

func set_visibility_radius(radius: float) -> void:
 _focus_radius=clampf(radius,180.0,420.0)
 if _material!=null:_material.set_shader_parameter("focus_radius",_focus_radius)

func set_atmosphere_enabled(enabled: bool) -> void:
 if _material==null or enabled==_atmosphere_enabled:return
 _atmosphere_enabled=enabled
 _material.set_shader_parameter("atmosphere_enabled",enabled)

func _process(delta: float) -> void:
 if _elapsed<TRANSITION_SECONDS:
  _elapsed=minf(TRANSITION_SECONDS,_elapsed+delta)
  _material.set_shader_parameter("transition",smoothstep(0.0,1.0,_elapsed/TRANSITION_SECONDS))
 if _focus_fade<1.0:
  _focus_fade=minf(1.0,_focus_fade+delta/FOCUS_FADE_SECONDS)
  _apply_focus()
 if _elapsed>=TRANSITION_SECONDS and _focus_fade>=1.0:set_process(false)

func _draw() -> void:
 draw_rect(_view_rectangle,Color.WHITE)

func report() -> Dictionary:
 return {"sync_count":sync_count,"build_ms":build_ms,"polygons":polygon_count,"mask_size":_views[_active].size if _active>=0 else Vector2i.ZERO,"transition_seconds":TRANSITION_SECONDS,"method":"raw current guard; bounded distance-field and range extinction","boundary_distance":BOUNDARY_DISTANCE,"atmosphere_enabled":_atmosphere_enabled,"focus_radius":_focus_radius,"maximum_visibility_radius":_focus_radius*1.685,"light_strength":_focus_strength,"cloud_texture_size":Vector2i(256,256),"unknown_geometry_drawn":false,"mask_updates_on_movement":false}
