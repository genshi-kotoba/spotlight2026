extends Node
## 地区首次入场框架。关闭或没有配置/映射时不创建 UI、不推进处理、不写存档。
signal title_started(region_id: String)
signal title_finished(region_id: String)
signal title_skipped(region_id: String, reason: String)
const CONFIG_PATH := "res://data/config/region_titles.json"
const OVERLAY := preload("res://ui/components/region_title_overlay.gd")
const WAIT_LIMIT_MS := 120000
var _configuration: Dictionary = {}
var _enabled := false
var _owner: WeakRef
var _identity := ""
var _region_id := ""
var _waiting := false
var _started_ms := 0
var _claiming := false
var _generation := 0
var _layer: CanvasLayer
var _overlay: RegionTitleOverlay

func _ready() -> void:
	set_process(false)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not parsed is Dictionary or configure(parsed) != OK:
		push_warning("RegionTitles: 地区标题配置无效，保持关闭。")

## 只供装配与独立预览使用；没有设置页或命令行隐式启用入口。
func configure(configuration: Dictionary) -> Error:
	_disable()
	if not _valid_configuration(configuration):
		_configuration = {}
		return ERR_INVALID_DATA
	_configuration = configuration.duplicate(true)
	_enabled = configuration.enabled
	return OK

func is_enabled() -> bool:
	return _enabled

static func _valid_configuration(configuration: Dictionary) -> bool:
	if configuration.get("version") != 1 or not configuration.get("enabled") is bool \
			or not configuration.get("map_regions") is Dictionary or not configuration.get("regions") is Dictionary:
		return false
	for region: Variant in configuration.regions:
		var entry: Variant = configuration.regions[region]
		if not GlobalStateMachine.valid_region_title_id(region) or not entry is Dictionary:
			return false
		if not entry.get("title") is String or entry.title.strip_edges().is_empty() or entry.title.length() > 128:
			return false
		for field in ["eyebrow", "subtitle"]:
			if not entry.get(field, "") is String or str(entry.get(field, "")).length() > 128:
				return false
	for map_id: Variant in configuration.map_regions:
		if not map_id is String or map_id.strip_edges().is_empty() or map_id.length() > 128:
			return false
		var region: Variant = configuration.map_regions[map_id]
		if not region is String or not configuration.regions.has(region):
			return false
	var style: Variant = configuration.get("style", {})
	if not style is Dictionary:
		return false
	for key in style:
		if key not in ["duration", "font_size", "reduced_motion"]:
			return false
	for key in ["duration", "font_size"]:
		var value: Variant = style.get(key, 4.3 if key == "duration" else 68)
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
	if float(style.get("duration", 4.3)) < 2.5 or float(style.get("duration", 4.3)) > 8.0:
		return false
	if float(style.get("font_size", 68)) < 32 or float(style.get("font_size", 68)) > 96 \
			or float(style.get("font_size", 68)) != floorf(float(style.get("font_size", 68))):
		return false
	return style.get("reduced_motion", false) is bool

## 正式地图 load_map 成功后仅提交候选，不在加载回调里消费首次记录。
func track_map(host: Node) -> void:
	if not _enabled:
		return
	if not is_instance_valid(host) or not host.has_method("region_title_context") or not host.has_method("is_region_title_ready"):
		return
	var context: Dictionary = host.region_title_context()
	var region := str(_configuration.map_regions.get(context.get("map_id", ""), ""))
	if region.is_empty():
		_cancel_candidate()
		return
	var identity := str(context.get("seed", "")) + "|" + str(context.get("map_id", ""))
	if _owner != null and _owner.get_ref() == host and identity == _identity:
		return
	_cancel_candidate()
	if GlobalState.has_seen_region_title(region):
		return
	_owner = weakref(host)
	_identity = identity
	_region_id = region
	_started_ms = Time.get_ticks_msec()
	_waiting = true
	var leaving := Callable(self, "_on_owner_exiting").bind(host.get_instance_id())
	if not host.tree_exiting.is_connected(leaving):
		host.tree_exiting.connect(leaving, CONNECT_ONE_SHOT)
	set_process(true)

func _process(_delta: float) -> void:
	if not _enabled or _owner == null:
		_cancel_candidate()
		return
	var host: Node = _owner.get_ref()
	if not is_instance_valid(host) or not host.is_inside_tree() or get_tree().current_scene != host:
		_cancel_candidate()
		return
	var context: Dictionary = host.region_title_context()
	if str(context.get("seed", "")) + "|" + str(context.get("map_id", "")) != _identity:
		_cancel_candidate()
		return
	if not _waiting:
		# 新的业务弹窗、转场或暂停出现时立即移除标题，不穿透到下一场景。
		if not host.is_region_title_ready():
			_cancel_candidate()
		return
	if Time.get_ticks_msec() - _started_ms > WAIT_LIMIT_MS:
		title_skipped.emit(_region_id, "地图入场未就绪")
		_cancel_candidate()
		return
	if _claiming or not host.is_region_title_ready():
		return
	_waiting = false
	_claiming = true
	var generation := _generation
	var region := _region_id
	var error := GlobalState.remember_region_title(region)
	_claiming = false
	if generation != _generation or not _enabled:
		return
	if error != OK:
		title_skipped.emit(region, "首次记录未保存，暂不播放")
		_cancel_candidate()
		return
	# 仅在成功持久化首次记录后分配离屏文字纹理和表现节点。
	_layer = CanvasLayer.new()
	_layer.name = "RegionTitleLayer"
	_layer.layer = 20
	add_child(_layer)
	_overlay = OVERLAY.new()
	_overlay.name = "RegionTitleOverlay"
	_layer.add_child(_overlay)
	_overlay.finished.connect(_on_title_finished.bind(region), CONNECT_ONE_SHOT)
	if not _overlay.play(_configuration.regions[region], _configuration.get("style", {})):
		_cancel_candidate()
		return
	title_started.emit(region)

func _on_title_finished(region: String) -> void:
	_cancel_candidate()
	title_finished.emit(region)

func _on_owner_exiting(instance_id: int) -> void:
	if _owner != null and is_instance_valid(_owner.get_ref()) and _owner.get_ref().get_instance_id() == instance_id:
		_cancel_candidate()

func _cancel_candidate() -> void:
	_generation += 1
	_waiting = false
	_owner = null
	_identity = ""
	_region_id = ""
	if is_instance_valid(_overlay):
		_overlay.cancel()
	_overlay = null
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	set_process(false)

func _disable() -> void:
	_enabled = false
	_cancel_candidate()

func _exit_tree() -> void:
	_disable()
