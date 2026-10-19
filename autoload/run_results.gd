extends Node
## 只在规则终局已保存、战斗表现队列收尾后接管画面。
const VIEW := preload("res://ui/results/run_settlement_view.gd")
var pending_record: Dictionary = {}
var overlay: CanvasLayer
var view: Control
var _presenting := false
var _confirming := false

func _ready() -> void:
	GlobalState.run_finished.connect(_on_run_finished)
	GlobalState.run_started.connect(func(_run: RunStateMachine): pending_record = {})
	SaveGateway.save_reloaded.connect(func(): pending_record = {})

func _on_run_finished(result: Dictionary) -> void:
	if result.get("status") not in ["defeat", "victory"]: return
	pending_record = GlobalState.run_history.back().duplicate(true)
	_auto_present.call_deferred()

func _auto_present() -> void:
	var scene := get_tree().current_scene
	# 单元测试和编辑器独立状态机不自动切走自己的宿主场景。
	if scene == null or not scene.scene_file_path.begins_with("res://ui/"): return
	present(scene)

func complete_if_ready() -> bool:
	var run := SaveGateway.current_run()
	if not is_instance_valid(run) or not run.active or not bool(run.inventory_state.get("pending_run_victory", false)) or not RunRewards.pending(run).is_empty(): return false
	return run.finish_victory() == OK

func present(source: Node) -> void:
	if pending_record.is_empty() or _presenting: return
	_presenting = true
	while is_instance_valid(source) and ((source.has_method("_presentation_pending") and source._presentation_pending()) or SceneTransition.is_loading()):
		await get_tree().process_frame
	if not is_instance_valid(source):
		_presenting = false
		return
	source.process_mode = Node.PROCESS_MODE_DISABLED
	var frame: Texture2D
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		frame = ImageTexture.create_from_image(get_viewport().get_texture().get_image())
	overlay = CanvasLayer.new()
	overlay.name = "RunSettlement"
	overlay.layer = 1800
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(overlay)
	view = VIEW.new()
	overlay.add_child(view)
	view.confirmed.connect(_confirm, CONNECT_DEFERRED)
	view.show_record(pending_record, true, frame)

func _confirm() -> void:
	if not is_instance_valid(view) or _confirming or not view.detail_ready: return
	_confirming = true
	view.confirm_button.disabled = true
	if SaveGateway.save_current() != OK:
		_confirming = false
		view.show_error("记录保存失败，请重试。原存档已保留。")
		return
	var error := SceneTransition.change_scene_to_file("res://ui/main_menu/main_menu.tscn")
	if error != OK:
		_confirming = false
		view.show_error("返回开始界面失败：%d，请重试。" % error)
		return
	SceneTransition.transition_finished.connect(_on_returned, CONNECT_ONE_SHOT)
	SceneTransition.transition_failed.connect(_on_return_failed, CONNECT_ONE_SHOT)

func _on_return_failed(_path: String, error: Error) -> void:
	if SceneTransition.transition_finished.is_connected(_on_returned):
		SceneTransition.transition_finished.disconnect(_on_returned)
	_confirming = false
	if is_instance_valid(view): view.show_error("开始界面载入失败：%d，请重试。记录已保存。" % error)

func _on_returned(_path: String) -> void:
	if SceneTransition.transition_failed.is_connected(_on_return_failed):
		SceneTransition.transition_failed.disconnect(_on_return_failed)
	pending_record.clear()
	if is_instance_valid(overlay): overlay.queue_free()
	view = null
	_presenting = false
	_confirming = false
