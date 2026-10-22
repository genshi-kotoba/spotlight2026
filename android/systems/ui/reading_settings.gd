class_name ReadingSettings
extends RefCounted
## 阅读偏好独立于对局存档；两平台共用实现，仅平台默认值不同。
const PATH := "user://reading_settings.cfg"
const ALLOWED_SIZES := [22, 28, 32, 36, 40, 48]
static var _loaded := false
static var _body_size := 22
static var _listeners: Array[Callable] = []

static func body_size() -> int:
	if not _loaded:
		_loaded = true
		_body_size = 32 if OS.has_feature("android") or ProjectSettings.has_setting("autoload/MobileInput") else 22
		var config := ConfigFile.new()
		if config.load(PATH) == OK:
			var value: Variant = config.get_value("reading", "body_size", _body_size)
			if value is int and value in ALLOWED_SIZES: _body_size = value
	return _body_size

static func set_body_size(value: int) -> void:
	if value not in ALLOWED_SIZES or value == body_size(): return
	var config := ConfigFile.new()
	config.set_value("reading", "body_size", value)
	var error := config.save(PATH)
	if error != OK:
		push_warning("ReadingSettings: reading preference was not saved (%d)." % error)
		return
	_body_size = value
	for listener: Callable in _listeners.duplicate():
		if listener.is_valid(): listener.call()
		else: _listeners.erase(listener)

static func connect_changed(listener: Callable) -> void:
	if listener.is_valid() and listener not in _listeners: _listeners.append(listener)

static func disconnect_changed(listener: Callable) -> void:
	_listeners.erase(listener)
