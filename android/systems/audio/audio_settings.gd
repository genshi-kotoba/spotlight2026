## 音量设置的程序侧落地点：界面写这里，音频侧从这里取值。
##
## 键名沿用跑图设置页已有的 music_volume / sfx_volume，值域 0..1（界面按百分比显示）。
## 落地方式是 Wwise 的两个全局 RTPC：Volume_Music / Volume_SFX，值域 0..100。
## 这两个名字取自 wwise_soundbanks/*/Init.json，不是这里编的。
##
## 工程里没有任何 autoload 会替我们应用设置，所以这个脚本自己负责两件事：
##   1. install() 登记一次：settings_changed 触发即时生效；AudioService.banks_loaded
##      触发冷启动读档生效（RTPC 必须在 Wwise 初始化之后才设得上）。
##   2. 给界面 volume() / set_volume()，界面不直接碰存档字段。
##
## 全是静态方法，install() 幂等。Wwise 原生模块缺席（无头运行、未打包平台）时整条
## 链路静默跳过，不报错也不阻断界面。

const KEY_MUSIC := "music_volume"
const KEY_SFX := "sfx_volume"
const RTPC_MUSIC := "Volume_Music"
const RTPC_SFX := "Volume_SFX"
const ROW_KEYS: Array[String] = [KEY_MUSIC, KEY_SFX]
const DEFAULT_VOLUME := 0.7
## 界面滑块是 0..1，Wwise RTPC 是 0..100。
const RTPC_SCALE := 100.0

static var _installed := false


static func install() -> void:
	if _installed:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var global := tree.root.get_node_or_null("GlobalState")
	if global == null:
		return
	_installed = true
	global.settings_changed.connect(_on_setting_changed)
	var audio := tree.root.get_node_or_null("AudioService")
	if audio != null and audio.has_signal("banks_loaded"):
		audio.banks_loaded.connect(apply_all)
	apply_all()


## 当前音量，0..1。没登记存档时回默认值，界面照样能用。
static func volume(key: String) -> float:
	var global := _global_state()
	if global == null:
		return DEFAULT_VOLUME
	return clampf(float(global.settings.get(key, DEFAULT_VOLUME)), 0.0, 1.0)


static func set_volume(key: String, value: float) -> Error:
	var global := _global_state()
	if global == null:
		return ERR_UNAVAILABLE
	return global.set_setting(key, clampf(value, 0.0, 1.0))


## 把两个键当前的存档值推给 Wwise，冷启动与换场景都可以重复调。
static func apply_all() -> void:
	for key: String in ROW_KEYS:
		_apply(key, volume(key))


static func _apply(key: String, value: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var audio := tree.root.get_node_or_null("AudioService")
	if audio == null:
		return
	audio.set_rtpc(RTPC_MUSIC if key == KEY_MUSIC else RTPC_SFX, value * RTPC_SCALE)


static func _on_setting_changed(key: String, value: Variant) -> void:
	if key not in ROW_KEYS:
		return
	_apply(key, clampf(float(value), 0.0, 1.0))


static func _global_state() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("GlobalState")
