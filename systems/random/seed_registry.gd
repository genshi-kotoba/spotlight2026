class_name SeedRegistry
extends RefCounted

## 纯随机上下文：稳定地址派生、流缓存、快照与恢复。
## 不持有地图等业务数据，也不访问界面或文件。
const SNAPSHOT_VERSION := 1
const RNG_PROTOCOL_VERSION := 1
const _PREFIX := "spotlight-rng-v1"

class Generation extends RefCounted:
	var value := 0

var last_error: Error = OK
var _generation := Generation.new()
var _streams: Dictionary = {}
var _main_seed := ""
var _content_version: String
var _engine_build: String


func _init(content_version: String) -> void:
	_content_version = content_version
	var version := Engine.get_version_info()
	_engine_build = "%s|%s" % [version["string"], version["hash"]]


func begin_run(seed_text: String = "") -> String:
	if _content_version.is_empty():
		_fail("Content version must be configured", ERR_UNCONFIGURED)
		return ""
	var chosen := seed_text.strip_edges()
	if chosen.is_empty():
		var bytes := Crypto.new().generate_random_bytes(16)
		if bytes.size() != 16:
			_fail("Could not generate a new main seed", ERR_CANT_CREATE)
			return ""
		chosen = bytes.hex_encode()
	_generation.value += 1
	_streams.clear()
	_main_seed = chosen
	last_error = OK
	return chosen


func get_main_seed() -> String:
	return _main_seed


func get_stream(domain: StringName, ids: Array, occurrence: int = 0) -> RandomStream:
	if _main_seed.is_empty():
		_fail("Call begin_run or restore_snapshot before requesting a stream", ERR_UNCONFIGURED)
		return null
	var name := String(domain)
	if not _valid_domain(name) or occurrence < 0:
		_fail("Invalid domain or negative occurrence: %s / %d" % [name, occurrence])
		return null
	var normalized: Array = []
	for id: Variant in ids:
		if typeof(id) == TYPE_INT:
			normalized.append(id)
		elif typeof(id) == TYPE_STRING or typeof(id) == TYPE_STRING_NAME:
			normalized.append(String(id))
		else:
			_fail("IDs must be int or String/StringName: %s" % name)
			return null
	var bytes := _encode_address(_main_seed, name, normalized, occurrence)
	var key := bytes.hex_encode()
	if not _streams.has(key):
		var address := _snapshot_address(name, normalized, occurrence)
		_streams[key] = RandomStream.new(_derive_seed(bytes), _generation,
			_generation.value, address)
	last_error = OK
	return _streams[key]


func capture_snapshot() -> Dictionary:
	if _main_seed.is_empty():
		_fail("No initialized run to capture", ERR_UNCONFIGURED)
		return {}
	var saved: Array = []
	var keys := _streams.keys()
	keys.sort()
	for key: String in keys:
		saved.append(_streams[key]._capture_snapshot())
	last_error = OK
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"rng_protocol_version": RNG_PROTOCOL_VERSION,
		"engine_build": _engine_build,
		"content_version": _content_version,
		"main_seed": _main_seed,
		"streams": saved,
	}


## 完整验证成功后才整体替换；失败不会破坏当前上下文。
func restore_snapshot(snapshot: Dictionary) -> Error:
	if not _version_matches(snapshot.get("snapshot_version"), SNAPSHOT_VERSION) \
			or not _version_matches(snapshot.get("rng_protocol_version"), RNG_PROTOCOL_VERSION) \
			or snapshot.get("engine_build") != _engine_build \
			or _content_version.is_empty() or snapshot.get("content_version") != _content_version:
		return _fail("Snapshot protocol, engine build or content version is incompatible", ERR_INVALID_DATA)
	var master: Variant = snapshot.get("main_seed")
	var entries: Variant = snapshot.get("streams")
	if not master is String or master.is_empty() or master != master.strip_edges() \
			or not entries is Array:
		return _fail("Invalid snapshot main seed or stream list", ERR_INVALID_DATA)

	var prepared: Dictionary = {}
	for entry: Variant in entries:
		if not entry is Dictionary:
			return _fail("Invalid stream record", ERR_INVALID_DATA)
		var name: Variant = entry.get("domain")
		var encoded_ids: Variant = entry.get("ids")
		var occurrence: Variant = _parse_i64(entry.get("occurrence"))
		var saved_seed: Variant = _parse_i64(entry.get("seed"))
		var state: Variant = _parse_i64(entry.get("state"))
		if not name is String or not _valid_domain(name) or not encoded_ids is Array \
				or occurrence == null or occurrence < 0 or saved_seed == null or state == null:
			return _fail("Malformed stream address, seed or state", ERR_INVALID_DATA)
		var ids: Array = []
		for encoded: Variant in encoded_ids:
			if not encoded is Dictionary:
				return _fail("Malformed ID record", ERR_INVALID_DATA)
			if encoded.get("type") == "string" and encoded.get("value") is String:
				ids.append(encoded["value"])
			elif encoded.get("type") == "int":
				var id: Variant = _parse_i64(encoded.get("value"))
				if id == null:
					return _fail("Malformed integer ID", ERR_INVALID_DATA)
				ids.append(id)
			else:
				return _fail("Unsupported ID type", ERR_INVALID_DATA)
		var bytes := _encode_address(master, name, ids, occurrence)
		var key := bytes.hex_encode()
		if prepared.has(key) or saved_seed != _derive_seed(bytes):
			return _fail("Duplicate address or mismatched derived seed", ERR_INVALID_DATA)
		prepared[key] = {
			"address": _snapshot_address(name, ids, occurrence),
			"seed": saved_seed, "state": state,
		}

	var replacement: Dictionary = {}
	var next_epoch := _generation.value + 1
	for key: String in prepared:
		var record: Dictionary = prepared[key]
		replacement[key] = RandomStream.new(record["seed"], _generation, next_epoch,
			record["address"], record["state"])
	_generation.value = next_epoch
	_main_seed = master
	_streams = replacement
	last_error = OK
	return OK


static func _encode_address(master: String, domain: String, ids: Array,
		occurrence: int) -> PackedByteArray:
	var bytes := _PREFIX.to_utf8_buffer()
	bytes.append(0)
	_append_field(bytes, "s", master)
	_append_field(bytes, "s", domain)
	_append_field(bytes, "i", str(ids.size()))
	for id: Variant in ids:
		_append_field(bytes, "i" if typeof(id) == TYPE_INT else "s", str(id))
	_append_field(bytes, "i", str(occurrence))
	return bytes


static func _append_field(bytes: PackedByteArray, tag: String, value: String) -> void:
	var data := value.to_utf8_buffer()
	bytes.append_array((tag + str(data.size()) + ":").to_utf8_buffer())
	bytes.append_array(data)


static func _derive_seed(bytes: PackedByteArray) -> int:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	var digest := context.finish()
	var result := 0
	for index in 8:
		result = result | (int(digest[index]) << (8 * index))
	return result


static func _snapshot_address(domain: String, ids: Array, occurrence: int) -> Dictionary:
	var encoded: Array = []
	for id: Variant in ids:
		encoded.append({"type": "int" if typeof(id) == TYPE_INT else "string", "value": str(id)})
	return {"domain": domain, "ids": encoded, "occurrence": str(occurrence)}


static func _valid_domain(domain: String) -> bool:
	if domain.is_empty():
		return false
	for part: String in domain.split(".", true):
		if part.is_empty() or not _lowercase(part.unicode_at(0)):
			return false
		for index in part.length():
			var code := part.unicode_at(index)
			if not _lowercase(code) and not (code >= 48 and code <= 57) and code != 95:
				return false
	return true


static func _lowercase(code: int) -> bool:
	return code >= 97 and code <= 122


static func _version_matches(value: Variant, expected: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and value == expected


## 严格解析有符号 64 位十进制文本，不把格式错误或溢出默认为零。
static func _parse_i64(value: Variant) -> Variant:
	if not value is String or value.is_empty():
		return null
	var negative: bool = value.begins_with("-")
	var digits: String = value.substr(1) if negative else value
	if digits.is_empty() or (digits.length() > 1 and digits.begins_with("0")) \
			or (negative and digits == "0"):
		return null
	for index in digits.length():
		var code := digits.unicode_at(index)
		if code < 48 or code > 57:
			return null
	var limit := "9223372036854775808" if negative else "9223372036854775807"
	if digits.length() > limit.length() or (digits.length() == limit.length() and digits > limit):
		return null
	return value.to_int()


func _fail(message: String, error: Error = ERR_INVALID_PARAMETER) -> Error:
	last_error = error
	push_error("SeedRegistry: " + message)
	return error
