extends Node
const Pool := preload("res://systems/map/relief_2d/floor_render_data.gd")
var checks:=0
var failures:=0
func check(label: String,ok: bool) -> void:
	checks+=1
	if not ok:failures+=1;push_error("FAIL "+label)
	else:print("PASS ",label)
func _ready() -> void:
	var pool=Pool.new({"cells":[],"nodes":[]})
	var context: int=pool.material_context_id(["projection",Vector3.UP,Basis.IDENTITY,60.0])
	var caster: int=pool.caster_geometry_id(["wall",PackedVector3Array([Vector3.ZERO,Vector3.ONE]),[Vector2i(0,1)]])
	var signature: Array=[context,caster,var_to_bytes([Vector3.UP,0.0])]
	var polygon:=PackedVector2Array([Vector2.ZERO,Vector2.RIGHT,Vector2.ONE])
	var bounds:=Rect2(0,0,1,1)
	check("uncached projection misses",pool.find_projection(signature)==null)
	pool.store_projection(signature,polygon,bounds)
	var found: Dictionary=pool.find_projection(signature)
	check("exact projection and bounds retained",found.polygon==polygon and found.bounds==bounds)
	check("shared result dictionary read-only",found.is_read_only())
	var private_polygon: PackedVector2Array=found.polygon
	private_polygon[0]=Vector2(900,900)
	check("packed polygon mutation does not alter shared result",pool.find_projection(signature).polygon==polygon)
	check("nearby receiver plane remains a distinct key",pool.find_projection([context,caster,var_to_bytes([Vector3.UP,0.0000001])])==null)
	check("different projection context misses",pool.find_projection([context+1,caster,signature[2]])==null)
	pool.store_projection([context,caster,"empty"],PackedVector2Array(),Rect2())
	check("empty projection is a cache hit",pool.find_projection([context,caster,"empty"])!=null)
	var release:=Semaphore.new()
	var late:=Thread.new()
	late.start(func():release.wait();pool.store_projection(signature,polygon,bounds))
	pool.clear_packets()
	var next_context: int=pool.material_context_id(["projection",Vector3.UP,Basis.IDENTITY,60.0])
	var next_caster: int=pool.caster_geometry_id(["wall",PackedVector3Array([Vector3.ZERO,Vector3.ONE]),[Vector2i(0,1)]])
	check("clearing never recycles context/caster identities",next_context>context and next_caster>caster)
	release.post();late.wait_to_finish()
	check("late old worker cannot satisfy a fresh signature",pool.find_projection([next_context,next_caster,signature[2]])==null)
	check("late worker stays under normal cache ownership",pool.find_projection(signature)!=null)
	pool.clear_packets()
	var workers: Array[Thread]=[]
	for _worker_id in 4:
		var worker:=Thread.new()
		worker.start(func():
			for index in 64:pool.store_projection([index],polygon,bounds))
		workers.append(worker)
	for worker in workers:worker.wait_to_finish()
	check("concurrent duplicate stores create one row per signature",pool.report().projection_rows==64)
	var concurrent_outputs_ok := true
	for index in 64:concurrent_outputs_ok = concurrent_outputs_ok and pool.find_projection([index]).polygon==polygon
	check("all concurrent results preserved",concurrent_outputs_ok)
	pool.clear_packets()
	var too_large:=PackedVector2Array();too_large.resize(128001)
	pool.store_projection(["too-large"],too_large,Rect2())
	check("vertex budget rejects oversized cache entry without truncation",pool.find_projection(["too-large"])==null and pool.report().projection_vertices==0)
	for index in 20001:pool.store_projection([index],PackedVector2Array(),Rect2())
	check("row budget bounded with exact fallback miss",pool.report().projection_rows==20000 and pool.find_projection([20000])==null)
	pool.clear_packets()
	check("clear releases all projection rows and vertices",pool.report().projection_rows==0 and pool.report().projection_vertices==0)
	print("SOLAR_PROJECTION_CACHE_RESULT checks=",checks," failures=",failures)
	get_tree().quit(1 if failures else 0)
