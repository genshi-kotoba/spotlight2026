extends Node
## AudioService：程序侧唯一的音频入口（Autoload）。
##
## 用法（程序只需要这三行）：
##   AudioService.play("SFX_002_UI_Click")              # 2D/UI 音，挂在全局对象上
##   AudioService.play("SFX_025_Foot_Wood", player_node) # 挂在某个节点上（带位置）
##   AudioService.play_id(AK.EVENTS.SFX_002_UI_CLICK)    # 用 Wwise/resources/wwise_ids.gd 里的 ID 常量
##
## Switch / State / RTPC 由音频侧调试，程序一般不直接调，但接口已备好：
##   AudioService.set_switch("Foot_Material", "Wood", player_node)
##   AudioService.set_state("Combat", "Battle")
##   AudioService.set_rtpc("Volume_Music", 80.0)         # game_object 省略 = 全局
##
## 依赖：addons/Wwise（GDExtension）＋ project.godot [wwise] 配置。
## Init.bnk 由集成自动加载；本服务负责加载 SFX / Music 两个用户自定义 bank。

signal banks_loaded ## 全部 bank 加载完成后发出；此前 play() 会被拒绝并告警

const BANKS_TO_LOAD: Array[String] = ["SFX", "Music"]
const SETUP_TIMEOUT_SEC := 5.0
const INVALID_PLAYING_ID := -1

var is_ready := false
var listener: AkListener2D
var default_game_object: Node2D ## 全局 2D 发声点（UI 音、无位置事件都挂这里）

var _loaded_banks: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup.call_deferred()


func _setup() -> void:
	# 等 WwiseRuntimeManager 完成 Wwise.init()（同为 autoload，按顺序本应已就绪，兜底轮询）
	var waited := 0.0
	while not Wwise.is_initialized() and waited < SETUP_TIMEOUT_SEC:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if not Wwise.is_initialized():
		push_error("AudioService: Wwise 初始化超时（%.1fs），音频服务不可用" % SETUP_TIMEOUT_SEC)
		return

	# 默认 Listener：没有它，任何事件都不会出声
	listener = AkListener2D.new()
	listener.name = "AudioListener2D"
	add_child(listener)

	# 全局 2D 发声对象：UI 音与无位置事件的默认挂载点
	default_game_object = Node2D.new()
	default_game_object.name = "AudioGlobal2D"
	add_child(default_game_object)
	Wwise.register_game_obj(default_game_object, "AudioGlobal2D")

	for bank_name in BANKS_TO_LOAD:
		var result: int = Wwise.load_bank(bank_name)
		_loaded_banks[bank_name] = result
		if result == 1: # AK_Success
			print("AudioService: bank 加载成功 %s.bnk" % bank_name)
		else:
			push_warning("AudioService: bank 加载失败 %s.bnk（AKRESULT=%d）——检查 wwise_soundbanks 是否已重新生成" % [bank_name, result])

	is_ready = true
	banks_loaded.emit()


## 播放事件。game_object 省略时挂到全局 2D 对象（UI/无位置音都走这里）。
## 返回 playing_id；失败返回 -1 并告警（不会打断游戏逻辑）。
func play(event_name: StringName, game_object: Node = null) -> int:
	if not _can_play(event_name):
		return INVALID_PLAYING_ID
	var target := game_object if game_object != null else default_game_object
	var playing_id: int = Wwise.post_event(String(event_name), target)
	if playing_id <= 0:
		push_warning("AudioService: post_event 失败 %s（事件不存在或 bank 未加载）" % event_name)
	return playing_id


## 用 ID 常量播放（AK.EVENTS.SFX_001_UI_HOVER，来自 Wwise/resources/wwise_ids.gd），编译期防打错字，推荐程序使用。
func play_id(event_id: int, game_object: Node = null) -> int:
	if not _can_play(event_id):
		return INVALID_PLAYING_ID
	var target := game_object if game_object != null else default_game_object
	var playing_id: int = Wwise.post_event_id(event_id, target)
	if playing_id <= 0:
		push_warning("AudioService: post_event_id 失败 id=%d（事件不存在或 bank 未加载）" % event_id)
	return playing_id


## UI 音快捷方式（语义上等价于 play，但方便以后统一改 UI 路由/ducking）。
func play_ui(event_name: StringName) -> int:
	return play(event_name)


## 停止该对象上的所有声音；game_object 省略 = 全局对象。
func stop_all(game_object: Node = null) -> void:
	if not is_ready:
		return
	Wwise.stop_all(game_object if game_object != null else default_game_object)


## 按 playing_id 停止单个事件（比如循环呼吸、环境声）。
func stop_event(playing_id: int, fade_ms: int = 200) -> void:
	if not is_ready or playing_id <= 0:
		return
	Wwise.stop_event(playing_id, fade_ms, AkUtils.AK_CURVE_LINEAR)


## Switch 是 game object 作用域：game_object 省略 = 全局对象。
## 返回 Wwise SDK 的调用结果（false = 组/值名在已加载 bank 里没解析到）。
func set_switch(switch_group: StringName, value: StringName, game_object: Node = null) -> bool:
	if not is_ready:
		return false
	var target := game_object if game_object != null else default_game_object
	var ok: bool = Wwise.set_switch(String(switch_group), String(value), target)
	if not ok:
		push_warning("AudioService: set_switch 失败 %s=%s（组/值不在已加载 bank 里？）" % [switch_group, value])
	return ok


## State 是全局作用域（音乐/混音状态切换走这里）。
func set_state(state_group: StringName, value: StringName) -> bool:
	if not is_ready:
		return false
	var ok: bool = Wwise.set_state(String(state_group), String(value))
	if not ok:
		push_warning("AudioService: set_state 失败 %s=%s" % [state_group, value])
	return ok


## RTPC。game_object 省略 = 全局 RTPC（音量类参数 Volume_* 就这么用）。
func set_rtpc(rtpc_name: StringName, value: float, game_object: Node = null) -> bool:
	if not is_ready:
		return false
	return Wwise.set_rtpc_value(String(rtpc_name), value, game_object)


func get_rtpc(rtpc_name: StringName, game_object: Node = null) -> float:
	if not is_ready:
		return 0.0
	return Wwise.get_rtpc_value(String(rtpc_name), game_object)


## bank 是否加载成功（按名字查，如 AudioService.bank_ok("SFX")）。
func bank_ok(bank_name: String) -> bool:
	return _loaded_banks.get(bank_name, 0) == 1


func _can_play(event: Variant) -> bool:
	if not is_ready:
		push_warning("AudioService: bank 尚未加载完，事件被拒绝：%s" % str(event))
		return false
	return true
