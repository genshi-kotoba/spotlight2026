extends CanvasLayer
## 原地重建地图（换层等）的黑场节拍：淡出 → 重建 → 淡入。
## 只负责画面：不锁输入、不碰暂停、不走 SceneTransition——那个是跨场景切换的
## 唯一入口，会暂停整棵树并换场景，用在原地重建上会连玩法状态一起冻住。
const FADE_OUT_SECONDS := 0.12
const FADE_IN_SECONDS := 0.18
var _veil: ColorRect
var _playing := false

func _ready() -> void:
	# 高于 HUD 的 CanvasLayer，低于 SceneTransition 的 2048。
	layer = 2000
	# 玩法即便被暂停，黑场也要把这一拍走完。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_veil = ColorRect.new()
	_veil.name = "MapEntryVeil"
	_veil.color = Color(0.0, 0.0, 0.0, 0.0)
	# 重建由节拍驱动，不需要拦住鼠标事件。
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_veil)
	_veil.hide()

func is_playing() -> bool:
	return _playing

## 返回是否受理。重建排在淡出结束的那一拍，所以 OK 只表示节拍已开始。
func play(build: Callable) -> bool:
	if _playing:
		return false
	_playing = true
	_veil.show()
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_method(_set_alpha, 0.0, 1.0, FADE_OUT_SECONDS)
	tween.tween_callback(build)
	tween.tween_method(_set_alpha, 1.0, 0.0, FADE_IN_SECONDS)
	tween.tween_callback(_finish)
	return true

func _set_alpha(value: float) -> void:
	_veil.color.a = value

func _finish() -> void:
	_playing = false
	_veil.color.a = 0.0
	_veil.hide()
