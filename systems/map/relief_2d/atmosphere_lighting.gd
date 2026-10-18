extends RefCounted
## Pure CPU material adapter. Never owns geometry, discovery, or random streams.
## Colors are retained in the existing vector batches, not a camera-size image.

const DEFAULTS := {"enabled": false, "preset": "dusk_castle", "fog_enabled": true, "local_lights_enabled": true, "strength": 1.0}
const LEGACY_BACKGROUND := Color("222b2a")
const BACKGROUND := Color("293746")
const HAZE := Color("647d91")
const FILL := Color("91a9cb")
const KEY := Color("f4cda0")
const WARM := Color("ffb85e")
const DAY_BACKGROUND := Color("2c3b43")
const DAY_FILL := Color("b5c8d8")
const DAY_KEY := Color("fff0d6")
const DAY_HAZE := Color("849da5")
const GLOOM_BACKGROUND := Color("1d1815")
const GLOOM_FILL := Color("b9ad9c")
const GLOOM_KEY := Color("f2d3a4")
const GLOOM_HAZE := Color("766653")
const GLOOM_LAMP := Color("d9b98d")
const DIRS := [Vector2i(1,0), Vector2i(1,-1), Vector2i(0,-1), Vector2i(-1,0), Vector2i(-1,1), Vector2i(0,1)]
var config: Dictionary = DEFAULTS.duplicate()
var lamps: Array[Dictionary] = []
var _cell_lamps: Dictionary = {}
var _known_cells: Dictionary = {}
var _anchor := Vector3.ZERO
var _radius := 1.0
var _quantum := .2
var cache_ms := 0.0

static func merged(current: Dictionary, patch: Dictionary) -> Dictionary:
	var next := current.duplicate(true)
	for field in patch:
		if not DEFAULTS.has(field): return {}
		var value: Variant = patch[field]
		if field in ["enabled", "fog_enabled", "local_lights_enabled"]:
			if not value is bool: return {}
		elif field == "preset":
			if not value is String or value not in ["dusk_castle","alchemical_daylight","alchemical_gloom"]: return {}
		elif field == "strength":
			if (not value is float and not value is int) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > 1.0: return {}
			value = float(value)
		next[field] = value
	return next

func active() -> bool:
	return bool(config.enabled) and float(config.strength) > 0.0

func background() -> Color:
	var target := DAY_BACKGROUND if config.preset=="alchemical_daylight" else BACKGROUND
	if config.preset=="alchemical_gloom": target=GLOOM_BACKGROUND
	return LEGACY_BACKGROUND.lerp(target, float(config.strength)) if active() else LEGACY_BACKGROUND

func unknown_color(original: Color) -> Color:
	# A uniform shell never samples its synthetic height, hidden cells, or lamps.
	return original.lerp(background().lightened(.065), float(config.strength)) if active() else original

func configure(next: Dictionary, snapshot: Dictionary, known: Dictionary) -> void:
	var start := Time.get_ticks_usec()
	config = next.duplicate(true)
	lamps.clear(); _cell_lamps.clear(); _known_cells.clear()
	_radius = maxf(.01, float(snapshot.get("outer_radius",1.0)))
	_quantum = maxf(.001,float(snapshot.get("height_quantum",.2)))
	for cell: Dictionary in snapshot.get("cells",[]):
		var key := _key(Vector2i(int(cell.q),int(cell.r)))
		if bool(known.get(key,false)): _known_cells[key] = cell
	var spawn: Vector2i = _pair(snapshot.get("spawn",[0,0]))
	var spawn_key := _key(spawn)
	var spawn_height := float(_known_cells.get(spawn_key,{}).get("level",0)) * _quantum
	var plane := _plane(spawn)
	_anchor = Vector3(plane.x,spawn_height,plane.y)
	if active() and bool(config.local_lights_enabled):
		var address := "%s/%s/%s" % [snapshot.get("seed",""),snapshot.get("map_id",""),snapshot.get("floor_index",0)]
		var nodes: Array = snapshot.get("nodes",[]).duplicate()
		nodes.sort_custom(func(a,b): return str(a.get("id","")) < str(b.get("id","")))
		for node: Dictionary in nodes:
			# Test visibility before type or procedural decoration is considered.
			var footprint: Array = node.get("footprint",[])
			if footprint.is_empty(): continue
			var visible := true
			for point in footprint:
				if not _known_cells.has(_key(_pair(point))): visible = false; break
			if not visible: continue
			var kind := str(node.get("type",""))
			var hash_value := _address_hash(address + "/" + str(node.get("id","")))
			if kind != "shop" and not (kind == "event" and hash_value % 4 == 0): continue
			var coord: Vector2i = _pair(node.get("coord",footprint[0]))
			var key := _key(coord)
			if not _known_cells.has(key) or str(_known_cells[key].get("terrain","ground")) == "wall": continue
			var p := _plane(coord)
			var offset := Vector2(.28,.16) * _radius
			var lamp := {"address":address+"/"+str(node.get("id","")),"node_id":str(node.get("id","")),"key":key,"position":Vector3(p.x+offset.x,float(_known_cells[key].level)*_quantum+.025,p.y+offset.y),"cells":{}}
			_build_light_domain(lamp,coord)
			var index := lamps.size()
			lamps.append(lamp)
			for target in lamp.cells:
				if not _cell_lamps.has(target): _cell_lamps[target] = []
				_cell_lamps[target].append(index)
	cache_ms = (Time.get_ticks_usec()-start)/1000.0

func _build_light_domain(lamp: Dictionary, origin: Vector2i) -> void:
	# Known traversable cells only, with legal one-level transitions. A wall,
	# unknown tile, or nonwalkable cliff cannot transmit a ground light pool.
	var queue: Array[Vector2i] = [origin]
	lamp.cells[_key(origin)] = 0
	var cursor := 0
	while cursor < queue.size():
		var coord := queue[cursor]; cursor += 1
		var key := _key(coord)
		var distance: int = lamp.cells[key]
		if distance >= 2: continue
		for direction: Vector2i in DIRS:
			var neighbor := coord+direction
			var next := _key(neighbor)
			if lamp.cells.has(next) or not _known_cells.has(next): continue
			var cell: Dictionary = _known_cells[next]
			if str(cell.get("terrain","ground")) == "wall" or absf(float(cell.level)-float(_known_cells[key].level)) > 1.001: continue
			lamp.cells[next] = distance+1
			queue.append(neighbor)

func tint(albedo: Color, point: Vector3, normal: Vector3, key: String, solar_factor: float, sun: Dictionary, shadowed: bool = false, actor: bool = false) -> Color:
	var legacy_factor := float(sun.get("ambient",.3)) if shadowed and bool(sun.get("enabled",true)) else solar_factor
	var legacy := albedo * Color(legacy_factor,legacy_factor,legacy_factor,1)
	if not active(): return legacy
	var incidence := 0.0
	if bool(sun.get("enabled",true)) and not shadowed:
		incidence = clampf((solar_factor-float(sun.get("ambient",.3)))/maxf(.001,float(sun.get("direct",.7))),0,1)
	var sky := clampf(normal.y,0,1)
	var illumination := FILL * (.28 + .08*sky) + KEY * (.50*incidence)
	var daylight: bool = config.preset=="alchemical_daylight"
	var gloom: bool = config.preset=="alchemical_gloom"
	if daylight:
		# Warm directional key plus cool broad sky fill; retain real cast shadows.
		# Art already carries painted values, so avoid a second very dark ambient.
		illumination = DAY_FILL*(.47+.09*sky) + DAY_KEY*(.57*incidence)
	if gloom:
		# Low umber fill and a soft warm key preserve directional values. The
		# material remains matte; broad ambient brightness cannot flatten walls.
		illumination = GLOOM_FILL*(.26+.055*sky) + GLOOM_KEY*(.50*incidence)
	# Color arithmetic must not multiply material alpha.
	illumination.a = 1.0
	var local := _local_energy(point,key)
	var lamp_color := GLOOM_LAMP if gloom else WARM
	if gloom: local *= .32
	illumination.r += lamp_color.r*local; illumination.g += lamp_color.g*local; illumination.b += lamp_color.b*local
	if actor:
		illumination.r = maxf(.78,illumination.r)
		illumination.g = maxf(.78,illumination.g)
		illumination.b = maxf(.78,illumination.b)
	var result := albedo * illumination
	var fog := fog_amount(point)
	if actor: fog = minf(fog,.16)
	var haze := DAY_HAZE if daylight else HAZE
	if gloom: haze=GLOOM_HAZE
	result = result.lerp(Color(haze.r,haze.g,haze.b,albedo.a),fog)
	result.a = albedo.a
	return legacy.lerp(result,float(config.strength))

func _local_energy(point: Vector3, key: String) -> float:
	var energy := 0.0
	for index: int in _cell_lamps.get(key,[]):
		var lamp: Dictionary = lamps[index]
		var p: Vector3 = lamp.position
		var distance := Vector2(point.x-p.x,point.z-p.z).length() / (_radius*3.1)
		var vertical := clampf(1.0-absf(point.y-p.y)/(_radius*.85),0,1)
		var path_fade := 1.0-float(lamp.cells[key])*.18
		energy = maxf(energy,.80*pow(maxf(0.0,1.0-distance),2.0)*vertical*path_fade)
	return energy

func fog_amount(point: Vector3) -> float:
	if not active() or not bool(config.fog_enabled): return 0.0
	# Fixed spawn anchor and widths prevent discovery-driven normalization jumps.
	var low := smoothstep(.15,2.4,_anchor.y-point.y)
	var outer := smoothstep(5.0*_radius,19.0*_radius,Vector2(point.x-_anchor.x,point.z-_anchor.z).length())
	if config.preset in ["alchemical_daylight","alchemical_gloom"]:
		# Most haze now lives in the single view veil. Do not grey the art twice.
		return clampf(.006+.035*low+.012*outer,0,.06)
	return clampf(.015 + .10*low + .045*outer,0,.16)

func markers(face: Dictionary) -> Array[Dictionary]:
	if not active() or not bool(face.get("known",false)) or not bool(face.get("top",false)) or face.has("scene_role"): return []
	var result: Array[Dictionary] = []
	for lamp: Dictionary in lamps:
		if str(face.get("key","")) != lamp.key: continue
		# Attach the inlay to the node stamp; it never creates an upright solid.
		if str(face.get("node_id","")) != lamp.node_id: continue
		result.append(lamp)
	return result

func report() -> Dictionary:
	return {"enabled":bool(config.enabled),"active":active(),"preset":config.preset,"strength":config.strength,"fog_enabled":config.fog_enabled,"local_lights_enabled":config.local_lights_enabled,"lamp_count":lamps.size(),"cache_ms":cache_ms,"background_hex":background().to_html(false),"layout":"stateless-fnv1a-seed-floor-node-v1","fog_anchor":"known-spawn-fixed-world-width","lamp_addresses":lamps.map(func(lamp):return lamp.address),"known_only":true,"backend":"retained-vector-colors"}

static func _address_hash(value: String) -> int:
	# Explicit bounded arithmetic, independent from map/gameplay RNG state.
	var result: int = 2166136261
	for byte in value.to_utf8_buffer(): result = ((result ^ int(byte))*16777619) & 0xffffffff
	return result

func _plane(coord: Vector2i) -> Vector2:
	return Vector2(1.5*coord.x,sqrt(3.0)*(coord.y+coord.x*.5))*_radius

static func _key(coord: Vector2i) -> String:
	return "%d,%d" % [coord.x,coord.y]

static func _pair(value: Variant) -> Vector2i:
	return value if value is Vector2i else Vector2i(int(value[0]),int(value[1]))
