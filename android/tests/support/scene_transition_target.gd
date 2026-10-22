extends Control
## 小型、无存档副作用的慢准备/跳转/失败夹具。
@export var prepare_frames := 12
@export var redirect_path := ""
@export var error_message := ""
var prepared := false
var process_count := 0
var input_count := 0
var clicks := 0

func _ready() -> void:
	$Button.pressed.connect(func(): clicks += 1)
	for index in prepare_frames:
		await get_tree().process_frame
	if not redirect_path.is_empty():
		SceneTransition.change_scene_to_file(redirect_path)
	prepared = true

func _process(_delta: float) -> void:
	process_count += 1

func _input(_event: InputEvent) -> void:
	input_count += 1

func is_scene_transition_ready() -> bool:
	return prepared

func scene_transition_error() -> String:
	return error_message
