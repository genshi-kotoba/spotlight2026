extends RefCounted
## One bounded local point light in the existing surface shader. Exploration
## never changes. Only uniforms move; retained geometry remains immutable.
const CAPACITY := 19
const RANGE := 2.2
var _signature := ""
var _coord := Vector2i(2147483647,2147483647)
var _known_ref: Dictionary = {}
var _known_size := -1
var _position := Vector3(INF,INF,INF)
var _strength := -1.0
var _material: ShaderMaterial
var blocker_count := 0
var rebuilds := 0
var update_ms := 0.0

func refresh(source) -> void:
 if source._wall_cutaway==null:return
 var start:=Time.get_ticks_usec()
 var material:ShaderMaterial=source._wall_cutaway.material
 if _material!=material:
  _material=material;_signature="";_coord=Vector2i(2147483647,2147483647)
  _position=Vector3(INF,INF,INF);_strength=-1.0
  material.set_shader_parameter("light_basis_x",source._basis.x/source.PIXELS_PER_WORLD)
  material.set_shader_parameter("light_basis_y",-source._basis.y/source.PIXELS_PER_WORLD)
  material.set_shader_parameter("light_basis_depth",source._basis.z)
  material.set_shader_parameter("surface_light_range",RANGE*source._radius)
  material.set_shader_parameter("light_cell_radius",source._radius)
 var strength:float=source._actor_emission_strength if source._actor_valid else 0.0
 if not is_equal_approx(strength,_strength):
  _strength=strength;material.set_shader_parameter("surface_light_strength",strength)
 if strength<=0.0:return
 var position:=Vector3(source._actor_plane.x,source._actor_height+source.ACTOR_HEIGHT*.68,source._actor_plane.y)
 if not position.is_equal_approx(_position):
  _position=position;material.set_shader_parameter("surface_light_position",position)
 var coord:Vector2i=source._plane_coord(source._actor_plane)
 if coord!=_coord or _signature!=source._presentation_cache_current or not is_same(_known_ref,source._known) or _known_size!=source._known.size():
  _coord=coord;_signature=source._presentation_cache_current;_known_ref=source._known;_known_size=source._known.size()
  var blockers:=PackedVector4Array()
  for q in range(-2,3):
   for t in range(-2,3):
    if maxi(absi(q),maxi(absi(t),absi(q+t)))>2:continue
    var cell_coord:=coord+Vector2i(q,t)
    var key:String=source._key(cell_coord)
    var cell:Dictionary=source._cells.get(key,{})
    var center:=Vector2(1.5*source._radius*cell_coord.x,sqrt(3.0)*source._radius*(cell_coord.y+cell_coord.x*.5))
    # Unknown/void is conservatively opaque; never consult hidden elevation.
    var top:=100000.0
    if source._known.get(key,false) and not cell.is_empty():
     top=source._cell_height(key)
     if cell.get("terrain","")=="wall":top+=maxf(.1,float(cell.get("wall_height",1.3)))
    blockers.append(Vector4(center.x,center.y,-100000.0,top))
  blocker_count=blockers.size();blockers.resize(CAPACITY)
  material.set_shader_parameter("light_columns",blockers)
  material.set_shader_parameter("light_column_count",blocker_count)
  rebuilds+=1
 update_ms=(Time.get_ticks_usec()-start)/1000.0

func report() -> Dictionary:
 return {"method":"normal-aware point light with bounded hex-column occlusion","range_world":RANGE,"blockers":blocker_count,"rebuilds":rebuilds,"last_update_ms":update_ms,"strength":_strength,"geometry_rebuilds":0}
