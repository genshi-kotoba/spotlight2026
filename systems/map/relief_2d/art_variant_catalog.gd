extends RefCounted
## Immutable CPU catalog. No RandomStream consumption and no GPU resources.
## IDs are persistent content IDs, not array indices. Sorting makes JSON order irrelevant.
const MANIFEST := "res://assets/environment/env005/manifest.json"
const NAMESPACE := "map.art-variants.v1"
var size := Vector2(2048,1024)
var scale := .5
var repeat_height := .6
var signature := ""
var regions: Dictionary = {}
var pools: Dictionary = {}
var decoration_probability := 1.0/47.0
var errors: Array[String] = []
var source_path := MANIFEST

func _init(data: Dictionary = {}, manifest_path: String = MANIFEST) -> void:
	source_path = manifest_path
	if data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(source_path))
		if parsed is Dictionary: data=parsed
		else: errors.append("Invalid manifest: " + source_path)
	signature=JSON.stringify(data).sha256_text()
	var dimensions: Array = data.get("size",[2048,1024])
	if dimensions.size()==2: size=Vector2(dimensions[0],dimensions[1])
	if size.x<=0 or size.y<=0: errors.append("Invalid atlas size");size=Vector2(2048,1024)
	scale=float(data.get("scale",.5))
	repeat_height=float(data.get("wall_world_repeat",.6))
	if scale<=0: errors.append("Invalid scale");scale=.5
	if repeat_height<=0: errors.append("Invalid wall repeat");repeat_height=.6
	for layer: Dictionary in data.get("layers",[]):
		var id := str(layer.get("name",""))
		var crop: Array = layer.get("crop",[])
		var rect: Array = layer.get("atlas",[])
		if id.is_empty() or regions.has(id) or crop.size()!=4 or rect.size()!=4:
			errors.append("Invalid or duplicate layer: "+id);continue
		if rect[0]<0 or rect[1]<0 or rect[2]<=0 or rect[3]<=0 or rect[0]+rect[2]>size.x or rect[1]+rect[3]>size.y:
			errors.append("Atlas bounds: "+id);continue
		regions[id]={"crop":Vector2(crop[0],crop[1]),"origin":Vector2(rect[0],rect[1]),"dimensions":Vector2(rect[2],rect[3]),"outline":layer.get("outline",[[0,0],[1,0],[1,1],[0,1]])}
	var definitions: Dictionary = data.get("pools",{})
	# Original v1 data remains a valid one-variant catalog.
	if not data.has("pools"):
		definitions={"ground":[{"id":"legacy","regions":{"top":"top"}}],"wall":[{"id":"legacy","regions":{"wall1":"wall1","wall2":"wall2","wall3":"wall3"}}],"decoration":[{"id":"glass","region":"glass"},{"id":"paper","region":"paper"}]}
	decoration_probability=clampf(float(data.get("decoration_probability",1.0/47.0)),0,1)
	for pool in ["ground","wall","decoration"]:
		var valid: Array = []
		var seen: Dictionary = {}
		for item: Dictionary in definitions.get(pool,[]):
			var id := str(item.get("id",""))
			var weight := float(item.get("weight",1.0))
			if id.is_empty() or seen.has(id) or not is_finite(weight) or weight<0:
				errors.append("Invalid variant: "+pool+"/"+id);continue
			seen[id]=true
			if weight==0: continue
			var variant: Dictionary = item.duplicate(true)
			variant["weight"]=weight
			var valid_regions := true
			if pool=="decoration":
				valid_regions=regions.has(str(item.get("region","")))
				variant["width"]=clampf(float(item.get("width",.48)),.05,2.0)
			else:
				for role in (["top"] if pool=="ground" else ["wall1","wall2","wall3"]):
					valid_regions=valid_regions and regions.has(str(item.get("regions",{}).get(role,"")))
			if not valid_regions: errors.append("Missing region: "+pool+"/"+id);continue
			valid.append(variant)
		valid.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return str(a.id)<str(b.id))
		pools[pool]=valid

func choose(pool: String, address: String, cell: String) -> Dictionary:
	var options: Array = pools.get(pool,[])
	if options.is_empty(): return {}
	var total := 0.0
	for option: Dictionary in options: total+=float(option.weight)
	var pick := fraction([NAMESPACE,address,cell,pool,"variant"])*total
	for option: Dictionary in options:
		pick-=float(option.weight)
		if pick<0: return option
	return options.back()

func places_decoration(address: String, cell: String) -> bool:
	return fraction([NAMESPACE,address,cell,"decoration","placement"])<decoration_probability

static func fraction(parts: Array) -> float:
	# Canonical array encoding avoids ambiguous slash-joined addresses.
	var value: int = 2166136261
	for byte in JSON.stringify(parts).to_utf8_buffer(): value=((value^int(byte))*16777619)&0xffffffff
	# Avalanche the coordinate hash, so neighboring cells do not form stripes.
	value=((value^(value>>16))*0x45d9f3b)&0xffffffff
	value=((value^(value>>16))*0x45d9f3b)&0xffffffff
	value=value^(value>>16)
	return float(value)/4294967296.0
