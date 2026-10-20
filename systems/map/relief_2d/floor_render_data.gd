extends RefCounted
## Instance-owned floor input. Only immutable source records and CPU material
## packets are shared; known, mutable face wrappers and lighting stay per state.
var _base: Dictionary = {}
var cells: Dictionary = {}
var duplicate_cells: Array[String] = []
var _nodes: Dictionary = {}
var _packets: Dictionary = {}
var _mutex := Mutex.new()
var packet_hits := 0
var packet_misses := 0
var packet_peak := 0
var _packet_count := 0
var _node_count := 0
var _shadow_packets: Dictionary = {}
var _shadow_count := 0
# Immutable CPU projections shared by exact caster geometry and receiver plane.
# Bounds cover both entries and vertices; empty results are useful cache hits.
var _projection_packets: Dictionary = {}
var _projection_count := 0
var _projection_vertices := 0
var projection_hits := 0
var projection_misses := 0
var projection_peak := 0
var shadow_hits := 0
var shadow_misses := 0
var _caster_geometry: Dictionary = {}
var _next_caster_id := 0
var _material_contexts: Dictionary = {}
var _next_context_id := 0

func _init(snapshot: Dictionary) -> void:
	_base=snapshot.duplicate(true)
	_base.erase("nodes")
	for cell: Dictionary in _base.get("cells",[]):
		var coord:=Vector2i(int(cell.get("q",0)),int(cell.get("r",0)))
		var key:="%d,%d"%[coord.x,coord.y]
		if cells.has(key):duplicate_cells.append(key);continue
		var row:=cell.duplicate(false)
		row["coord"]=coord
		cells[key]=row

func matches(snapshot: Dictionary) -> bool:
	if snapshot.size()!=_base.size()+int(snapshot.has("nodes")):return false
	for field in _base:
		if not snapshot.has(field) or _base[field]!=snapshot[field]:return false
	return true

func snapshot_for(snapshot: Dictionary) -> Dictionary:
	# Caller input is never retained. Equal visible node records are interned;
	# metadata variants under an existing id remain distinct records.
	var result:=_base.duplicate(false)
	var visible: Array=[]
	_mutex.lock()
	for node: Dictionary in snapshot.get("nodes",[]):
		var identity=hash(node)
		var found: Dictionary={}
		for candidate: Dictionary in _nodes.get(identity,[]):
			if candidate==node:found=candidate;break
		if found.is_empty():
			found=node.duplicate(true)
			if _node_count<256:
				if not _nodes.has(identity):_nodes[identity]=[]
				_nodes[identity].append(found);_node_count+=1
		visible.append(found)
	_mutex.unlock()
	result["nodes"]=visible
	return result

func find_packet(signature: Array) -> Variant:
	var identity:=hash(signature)
	_mutex.lock()
	for row: Dictionary in _packets.get(identity,[]):
		if row.signature==signature:
			packet_hits+=1
			var commands: Array=row.commands
			_mutex.unlock()
			return commands
	packet_misses+=1
	_mutex.unlock()
	return null

func store_packet(signature: Array, commands: Array) -> void:
	_mutex.lock()
	if _packet_count<20000:
		var identity:=hash(signature)
		if not _packets.has(identity):_packets[identity]=[]
		for row: Dictionary in _packets[identity]:
			if row.signature==signature:
				_mutex.unlock();return
		# Signatures own their mutable nested configs. Packets are read-only
		# thereafter; append_commands copies into a private batch buffer.
		_packets[identity].append({"signature":signature.duplicate(true),"commands":commands})
		_packet_count+=1;packet_peak=maxi(packet_peak,_packet_count)
	_mutex.unlock()

func clear_packets() -> void:
	_mutex.lock()
	_packets.clear();_packet_count=0
	_shadow_packets.clear();_shadow_count=0
	_projection_packets.clear();_projection_count=0;_projection_vertices=0
	_caster_geometry.clear()
	_material_contexts.clear()
	# Do not recycle ids: a cancelled worker may still own ids from before
	# this clear. Monotonic identities make those late packets harmless misses.
	_mutex.unlock()

func caster_geometry_id(signature: Array) -> int:
	var identity:=hash(signature)
	_mutex.lock()
	for row: Dictionary in _caster_geometry.get(identity,[]):
		if row.signature==signature:
			var id: int=row.id
			_mutex.unlock();return id
	_next_caster_id+=1
	var id:=_next_caster_id
	if not _caster_geometry.has(identity):_caster_geometry[identity]=[]
	_caster_geometry[identity].append({"signature":signature.duplicate(true),"id":id})
	_mutex.unlock();return id

func find_shadows(signature: Array) -> Variant:
	var identity:=hash(signature)
	_mutex.lock()
	for row: Dictionary in _shadow_packets.get(identity,[]):
		if row.signature==signature:
			shadow_hits+=1
			var shadows: Array=row.shadows
			_mutex.unlock();return shadows
	shadow_misses+=1
	_mutex.unlock();return null

func store_shadows(signature: Array, shadows: Array[PackedVector2Array]) -> void:
	_mutex.lock()
	if _shadow_count<10000:
		var identity:=hash(signature)
		if not _shadow_packets.has(identity):_shadow_packets[identity]=[]
		for row: Dictionary in _shadow_packets[identity]:
			if row.signature==signature:
				_mutex.unlock();return
		# Keep the result container immutable. Packed polygon values use COW;
		# neither actor queries nor individual face wrappers may edit the pool.
		var immutable:=shadows.duplicate(false)
		immutable.make_read_only()
		_shadow_packets[identity].append({"signature":signature.duplicate(true),"shadows":immutable})
		_shadow_count+=1
	_mutex.unlock()

func report() -> Dictionary:
	_mutex.lock()
	var result:={"packet_rows":_packet_count,"packet_peak":packet_peak,"packet_hits":packet_hits,"packet_misses":packet_misses,"shadow_rows":_shadow_count,"projection_rows":_projection_count,"projection_vertices":_projection_vertices,"projection_hits":projection_hits,"projection_misses":projection_misses,"projection_peak":projection_peak,"shadow_hits":shadow_hits,"shadow_misses":shadow_misses,"input_copies":1,"shared_floor_cells":cells.size()}
	_mutex.unlock()
	return result


func material_context_id(signature: Array) -> int:
	# One immutable copy per material revision, not a deep config copy per face.
	var identity:=hash(signature)
	_mutex.lock()
	for row: Dictionary in _material_contexts.get(identity,[]):
		if row.signature==signature:
			var id: int=row.id
			_mutex.unlock();return id
	_next_context_id+=1
	var id:=_next_context_id
	if not _material_contexts.has(identity):_material_contexts[identity]=[]
	_material_contexts[identity].append({"signature":signature.duplicate(true),"id":id})
	_mutex.unlock();return id

func find_projection(signature: Array) -> Variant:
	var identity := hash(signature)
	_mutex.lock()
	for row: Dictionary in _projection_packets.get(identity, []):
		if row.signature == signature:
			projection_hits += 1
			var result: Dictionary = row.result
			_mutex.unlock()
			return result
	projection_misses += 1
	_mutex.unlock()
	return null

func store_projection(signature: Array, polygon: PackedVector2Array, bounds: Rect2) -> void:
	var identity := hash(signature)
	_mutex.lock()
	if _projection_count < 20000 and _projection_vertices + polygon.size() <= 128000:
		for row: Dictionary in _projection_packets.get(identity, []):
			if row.signature == signature:
				_mutex.unlock()
				return
		if not _projection_packets.has(identity): _projection_packets[identity] = []
		var result := {"polygon": polygon, "bounds": bounds}
		result.make_read_only()
		_projection_packets[identity].append({"signature": signature.duplicate(true), "result": result})
		_projection_count += 1
		_projection_vertices += polygon.size()
		projection_peak = maxi(projection_peak, _projection_count)
	_mutex.unlock()
