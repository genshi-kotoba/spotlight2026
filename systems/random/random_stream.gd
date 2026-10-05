class_name RandomStream
extends RefCounted

## 单条持续推进的玩法随机流。只能通过 SeedService / SeedRegistry 取得。
var last_error: Error = OK

var _rng := RandomNumberGenerator.new()
var _generation: RefCounted
var _epoch: int
var _address: Dictionary
var _seed: int


func _init(p_seed: int, generation: RefCounted, epoch: int,
		address: Dictionary, saved_state: Variant = null) -> void:
	_seed = p_seed
	_generation = generation
	_epoch = epoch
	_address = address.duplicate(true)
	_rng.seed = p_seed
	if saved_state != null:
		_rng.state = saved_state


## 左闭右开区间 [min_inclusive, max_exclusive]。失败不消费随机数。
func int_range(min_inclusive: int, max_exclusive: int) -> Variant:
	if not _check_current():
		return null
	if min_inclusive < -2147483648 or max_exclusive > 2147483648 \
			or min_inclusive >= max_exclusive:
		_fail("Expected a nonempty signed-32-bit half-open range")
		return null
	last_error = OK
	return _rng.randi_range(min_inclusive, max_exclusive - 1)


## 等概率有放回抽取，不修改输入数组；数组不能为空或包含 null。
func pick(items: Array) -> Variant:
	if not _check_current():
		return null
	if items.is_empty() or items.has(null):
		_fail("Expected a nonempty pool without null items")
		return null
	last_error = OK
	return items[_rng.randi_range(0, items.size() - 1)]


## 元素格式：{"value": 非 null 值, "weight": 有限非负数}。
func weighted_pick(entries: Array) -> Variant:
	if not _check_current():
		return null
	var weights := PackedFloat64Array()
	var total := 0.0
	var last_positive := -1
	for index in entries.size():
		var entry: Variant = entries[index]
		if not entry is Dictionary or not entry.has("value") or entry["value"] == null \
				or not entry.has("weight"):
			_fail("Each weighted entry needs a non-null value and a weight")
			return null
		var raw: Variant = entry["weight"]
		if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
			_fail("Weight must be a number")
			return null
		var weight := float(raw)
		if not is_finite(weight) or weight < 0.0:
			_fail("Weight must be finite and nonnegative")
			return null
		weights.append(weight)
		total += weight
		if weight > 0.0:
			last_positive = index
	if not is_finite(total) or total <= 0.0:
		_fail("Total weight must be finite and positive")
		return null

	var target := float(_rng.randi()) / 4294967296.0
	var cumulative := 0.0
	last_error = OK
	for index in weights.size():
		cumulative += weights[index]
		if weights[index] > 0.0 and target < cumulative / total:
			return entries[index]["value"]
	return entries[last_positive]["value"]


## 使用本流执行 Fisher-Yates 洗牌；空数组和单元素数组不推进随机流。
func shuffle_in_place(items: Array) -> Error:
	if not _check_current():
		return last_error
	if items.is_read_only():
		return _fail("Cannot shuffle a read-only array")
	for index in range(items.size() - 1, 0, -1):
		var other := _rng.randi_range(0, index)
		var item: Variant = items[index]
		items[index] = items[other]
		items[other] = item
	last_error = OK
	return OK


## 仅供 SeedRegistry 捕获状态；业务侧使用 SeedService.capture_snapshot()。
func _capture_snapshot() -> Dictionary:
	var result := _address.duplicate(true)
	result["seed"] = str(_seed)
	result["state"] = str(_rng.state)
	return result


func _check_current() -> bool:
	if _generation == null or _generation.get("value") != _epoch:
		_fail("Handle belongs to an ended or replaced run; reacquire it", ERR_UNCONFIGURED)
		return false
	return true


func _fail(message: String, error: Error = ERR_INVALID_PARAMETER) -> Error:
	last_error = error
	push_error("RandomStream %s: %s" % [str(_address), message])
	return error
