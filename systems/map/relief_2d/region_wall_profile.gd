extends RefCounted
## Existing opaque full-hex walls, with a terrain-dependent structural fill.
const Hex=preload("res://systems/map/hex_coord.gd")
const Citadel=preload("res://systems/map/relief_2d/citadel_height.gd")
const VERSION:="readable-wall-crown-v2"
const READABLE_CROWN_HEIGHT:=0.8
const MASONRY_CROWN_VERSION:="seeded-wall-run-crowns-v1"
const MASONRY_CROWN_STEP:=0.2
const MASONRY_CROWN_COURSES:=3

## Apply only after the walkable levels have been accepted. Candidate scoring
## deliberately keeps using profile(), including its original wall-run metrics.
static func final_profile(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary,seed_value:int,side:Dictionary={},selected:Dictionary={})->Dictionary:
	if side.is_empty():side=sides(planar,data)
	var result:Dictionary=profile(planar,data,levels,c,side,selected)
	if c.wall_height<READABLE_CROWN_HEIGHT or result.cells.is_empty():return result
	var patches:Dictionary=_crown_patches(result.cells,seed_value)
	var summaries:Array=[]
	for anchor:Vector2i in patches:
		var members:Array=patches[anchor]
		var contrast:=0;var thick:=0;var retaining:=0
		for coord:Vector2i in members:
			var record:Dictionary=result.cells[coord]
			contrast+=int(record.wall_high_level)-int(record.wall_low_level)
			if int(side[coord].wall_neighbors)>=4:thick+=1
			if selected.has(coord):retaining+=1
		# A patch shares one surviving masonry course. Actual retaining relief
		# and thicker structural masses may retain one additional course, but
		# the crown stays within .8..1.4 above the adjacent high floor.
		var courses:int=_crown_hash(anchor,seed_value,19)%(MASONRY_CROWN_COURSES+1)
		if contrast>=members.size()*3 or thick*2>members.size() or retaining*2>members.size():courses=mini(MASONRY_CROWN_COURSES,courses+1)
		var crown:float=READABLE_CROWN_HEIGHT+courses*MASONRY_CROWN_STEP
		for coord:Vector2i in members:
			var record:Dictionary=result.cells[coord]
			var top:float=float(record.wall_high_level)*c.quantum+crown
			record.wall_height=top-float(record.level)*c.quantum
			record.wall_top=top;record.declared_top=top
			record.wall_crown_height=crown;record.wall_crown_patch=[anchor.x,anchor.y]
			record.decorative_cap_limited=false
		summaries.append({"anchor":[anchor.x,anchor.y],"cells":members.size(),"crown":crown})
	# These diagnostics describe the final wall geometry. Raising a crown never
	# silently claims that the old static visibility cap is still fulfilled.
	result.counts={};result.limited=0;result.visibility_conflicts=[]
	var minimum:=INF;var maximum:=0.0
	for coord:Vector2i in result.cells:
		var record:Dictionary=result.cells[coord]
		var role:String=str(record.wall_role).trim_suffix("_cap_conflict")
		if record.wall_cap!=null and float(record.wall_top)>float(record.wall_cap)+0.000001:
			role+="_cap_conflict";result.limited+=1
			result.visibility_conflicts.append({"coord":[coord.x,coord.y],"high_floor":float(record.wall_high_level)*c.quantum,"wall_top":record.wall_top,"cap":record.wall_cap,"excess":float(record.wall_top)-float(record.wall_cap)})
		record.wall_role=role;result.counts[role]=int(result.counts.get(role,0))+1
		minimum=minf(minimum,float(record.wall_crown_height));maximum=maxf(maximum,float(record.wall_crown_height))
	var jumps:=0;var maximum_delta:=0.0
	for coord:Vector2i in result.cells:
		for neighbor:Vector2i in Hex.neighbors(coord):
			if not result.cells.has(neighbor):continue
			var delta:float=absf(float(result.cells[coord].wall_top)-float(result.cells[neighbor].wall_top))
			maximum_delta=maxf(maximum_delta,delta)
			if delta>2.0*c.quantum+0.000001:jumps+=1
	result.wall_run_jumps=jumps/2;result.max_wall_run_top_delta=maximum_delta
	result.masonry_crowns={"version":MASONRY_CROWN_VERSION,"seed":seed_value,"min":minimum,"max":maximum,"patches":summaries,"source":"connected-original-wall-graph; accepted-ground-levels"}
	return result

## Geodesic patches follow real wall runs, including their turns and branches.
## Seed anchors are at least four wall edges apart; a multi-source flood gives
## each a connected patch instead of independently varying neighboring hexes.
static func _crown_patches(cells:Dictionary,seed_value:int)->Dictionary:
	var ranked:Array=cells.keys();var priority:Dictionary={}
	for coord:Vector2i in ranked:priority[coord]=_crown_hash(coord,seed_value,7)
	ranked.sort_custom(func(a:Vector2i,b:Vector2i):
		if priority[a]!=priority[b]:return priority[a]<priority[b]
		return a.x<b.x if a.x!=b.x else a.y<b.y)
	var excluded:Dictionary={};var anchors:Array=[]
	for coord:Vector2i in ranked:
		if excluded.has(coord):continue
		anchors.append(coord)
		var queue:Array=[coord];var distance:Dictionary={coord:0};var index:=0
		var radius:int=3+_crown_hash(coord,seed_value,11)%2
		while index<queue.size():
			var current:Vector2i=queue[index];index+=1;excluded[current]=true
			if int(distance[current])>=radius:continue
			for neighbor:Vector2i in Hex.neighbors(current):
				if not cells.has(neighbor) or distance.has(neighbor):continue
				distance[neighbor]=int(distance[current])+1;queue.append(neighbor)
	var owner:Dictionary={};var result:Dictionary={};var queue:Array=[]
	for anchor:Vector2i in anchors:
		owner[anchor]=anchor;result[anchor]=[];queue.append(anchor)
	var index:=0
	while index<queue.size():
		var current:Vector2i=queue[index];index+=1
		var anchor:Vector2i=owner[current];result[anchor].append(current)
		for neighbor:Vector2i in Hex.neighbors(current):
			if not cells.has(neighbor) or owner.has(neighbor):continue
			owner[neighbor]=anchor;queue.append(neighbor)
	return result

static func _crown_hash(coord:Vector2i,seed_value:int,salt:int)->int:
	# Explicit integer arithmetic avoids mutable gameplay RNG and dictionary
	# iteration order. Products remain inside signed 64-bit for map coordinates.
	var value:int=posmod(posmod(seed_value,2147483647)*48271+coord.x*73856093+coord.y*19349663+salt*83492791,2147483647)
	return posmod(value*48271+12820163,2147483647)

static func sides(planar:Dictionary,data:Dictionary)->Dictionary:
	var wall:Dictionary={}
	for cell:Dictionary in planar.cells:
		if cell.terrain=="wall":wall[Vector2i(int(cell.q),int(cell.r))]=true
	var result:Dictionary={}
	for coord:Vector2i in wall:
		var groups:Dictionary={};var coords:Dictionary={}
		var direct:Dictionary={};var direct_coords:Array=[]
		for n:Vector2i in Hex.neighbors(coord):
			if data.owner.has(n):direct[data.owner[n]]=true;direct_coords.append(n)
		var visit:Array=[coord]
		for n:Vector2i in Hex.neighbors(coord):
			if wall.has(n):visit.append(n)
		for w:Vector2i in visit:
			for n:Vector2i in Hex.neighbors(w):
				if data.owner.has(n):groups[data.owner[n]]=true;coords[n]=true
		result[coord]={"groups":groups.keys(),"ground":coords.keys(),"direct_groups":direct.keys(),"direct_ground":direct_coords,"wall_neighbors":visit.size()-1}
	return result

static func geometry(planar:Dictionary,data:Dictionary,c:Dictionary,budget:int,side:Dictionary,selected:Dictionary={},base_geometry:Dictionary={})->Dictionary:
	var result:Dictionary=Citadel._geometry(planar,data,c,budget) if base_geometry.is_empty() else base_geometry.duplicate(true)
	result.wall_arcs=0
	if c.wall_height==0 or selected.is_empty():return result
	var parapet:float=minf(0.20,c.wall_height)
	var clear:float=0.55-c.quantum-0.05
	var reach:float=(2.0*budget*c.quantum+parapet-clear)/Citadel.TAN_PITCH+Citadel.PLANAR_MARGIN
	var bins:Dictionary={}
	for coord:Vector2i in data.owner:
		var p:Vector2=Hex.to_plane(coord,1)
		var row:Dictionary={"group":data.owner[coord],"l":p.dot(Citadel.L),"d":p.dot(Citadel.C)}
		var key:=Vector2i(floori(row.l/Citadel.LATERAL_MARGIN),floori(row.d/3.0))
		if not bins.has(key):bins[key]=[]
		bins[key].append(row)
	for coord:Vector2i in side:
		if not selected.has(coord):continue
		var p:Vector2=Hex.to_plane(coord,1);var l:float=p.dot(Citadel.L);var d:float=p.dot(Citadel.C)
		for viewer:Dictionary in Citadel._near_rows(bins,l,d-reach,d):
			var delta:float=d-float(viewer.d)
			if delta<=0 or absf(l-float(viewer.l))>Citadel.LATERAL_MARGIN:continue
			var cost:int=maxi(0,floori((clear+Citadel.TAN_PITCH*maxf(0,delta-Citadel.PLANAR_MARGIN)-parapet)/c.quantum+0.00000001))
			for high:int in side[coord].direct_groups:
				Citadel._arc(result.forward,result.reverse,int(viewer.group),high,cost)
				result.wall_arcs+=1
	return result

static func profile(planar:Dictionary,data:Dictionary,levels:Array,c:Dictionary,side:Dictionary={},selected:Dictionary={})->Dictionary:
	if side.is_empty():side=sides(planar,data)
	var clear:float=0.55-c.quantum-0.05
	var result:Dictionary={};var counts:Dictionary={};var limited:=0;var low_side_rows:Array=[]
	var visibility_conflicts:Array=[]
	# Only static viewer geometry is cached, scoped to this generation's side
	# table. Keep the original floating-point addition order for exact output.
	var rows:Array=[]
	for coord:Vector2i in data.owner:
		var p:Vector2=Hex.to_plane(coord,1)
		rows.append({"l":p.dot(Citadel.L),"d":p.dot(Citadel.C),"group":data.owner[coord]})
	for coord:Vector2i in side:
		var info:Dictionary=side[coord];var low:int=c.baseline_level;var high:int=low
		if not info.direct_groups.is_empty():
			low=100000;high=-100000
			for group:int in info.direct_groups:low=mini(low,int(levels[group]));high=maxi(high,int(levels[group]))
		var role:String="retaining" if selected.has(coord) else ("outer" if info.wall_neighbors<4 else "court")
		# The highest directly adjacent walkable surface is the visible datum.
		# Keep a finite crown above it; lowering to the old viewer cap made a
		# wall read as another uphill step. The low-side foundation still fills
		# the entire retaining body. Geometry/height fitting remains unchanged.
		var crown:float=minf(READABLE_CROWN_HEIGHT,maxf(.1,c.wall_height))
		var desired_top:float=high*c.quantum+crown
		var top:float=desired_top
		var cap:float=INF;var p:Vector2=Hex.to_plane(coord,1)
		if not info.has("_profile_viewers"):
			var viewers:Array=[]
			for viewer:Dictionary in rows:
				var delta:float=p.dot(Citadel.C)-float(viewer.d)
				if delta<=0 or absf(p.dot(Citadel.L)-float(viewer.l))>Citadel.LATERAL_MARGIN:continue
				viewers.append({"group":viewer.group,"depth_term":Citadel.TAN_PITCH*maxf(0,delta-Citadel.PLANAR_MARGIN)})
			info._profile_viewers=viewers
		for viewer:Dictionary in info._profile_viewers:
			cap=minf(cap,float(levels[viewer.group])*c.quantum+clear+float(viewer.depth_term))
		var fulfilled:bool=true
		var base:int=low;var extra:float=0.0
		if c.wall_height==0:
			base=mini(low,floori((cap-.1)/c.quantum+0.00000001)) if is_finite(cap) else low
			top=base*c.quantum;role="zero_config_min_visible";fulfilled=top+.1>=high*c.quantum
		else:
			# A visibility cap below the required crown is an incompatible visual
			# constraint. Keep the finite wall and expose the conflict instead of
			# changing walkable heights, navigation, fog, or hiding the diagnosis.
			extra=top-base*c.quantum
			if top>cap+0.000001:
				visibility_conflicts.append({"coord":[coord.x,coord.y],"high_floor":high*c.quantum,"wall_top":top,"cap":cap,"excess":top-cap})
				role+="_cap_conflict";limited+=1
		result[coord]={"level":base,"wall_height":extra,"wall_role":role,"wall_high_level":high,"wall_low_level":low,"wall_cap":cap if is_finite(cap) else null,"wall_top":base*c.quantum+maxf(.1,extra),"declared_top":top,"structural_fill_complete":fulfilled,"decorative_cap_limited":top<desired_top-0.000001}
		counts[role]=int(counts.get(role,0))+1
	var jumps:=0;var maximum:=0.0
	for coord:Vector2i in result:
		for neighbor:Vector2i in Hex.neighbors(coord):
			if not result.has(neighbor):continue
			var delta:float=absf(result[coord].wall_top-result[neighbor].wall_top)
			maximum=maxf(maximum,delta)
			if delta>2.0*c.quantum+0.000001:jumps+=1
	return {"cells":result,"counts":counts,"limited":limited,"low_side_boundaries":low_side_rows,"wall_run_jumps":jumps/2,"max_wall_run_top_delta":maximum,"readable_crown_height":READABLE_CROWN_HEIGHT,"visibility_conflicts":visibility_conflicts}
