extends Control
const VIEW := preload("res://ui/results/run_settlement_view.gd")
var entries: Array[Dictionary] = []
var _list: VBoxContainer
var _detail_layer: CanvasLayer
var _detail: Control

func _ready() -> void:
	var body := CatalogUi.shell(self, "记录", "按结束时间从新到旧 · 点击记录查看最终背包")
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 14)
	scroll.add_child(_list)
	entries = RunHistory.records(GlobalState.run_history)
	if entries.is_empty(): _list.add_child(CatalogUi.label("还没有已结束的对局记录。", 28))
	for index in entries.size():
		var entry: Dictionary = entries[index]
		var outcome := "胜利" if entry.get("result") == "victory" else "死亡"
		var text := "%s    %s\n累计银币 %s    战斗 %d 场" % [str(entry.get("ended_at", "时间未记录")).replace("T", " ") + " UTC", outcome, RunHistory.silver_text(entry), int(entry.get("battles_fought", 0))]
		var button := CatalogUi.button(text, "Record_%d" % index)
		button.custom_minimum_size.y = 110
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_color_override("font_color", Color("e9b85e") if outcome == "胜利" else Color("ff7878"))
		button.pressed.connect(_open_detail.bind(index), CONNECT_DEFERRED)
		_list.add_child(button)

func _open_detail(index: int) -> void:
	if is_instance_valid(_detail_layer) or index < 0 or index >= entries.size(): return
	_detail_layer = CanvasLayer.new()
	_detail_layer.layer = 1800
	add_child(_detail_layer)
	_detail = VIEW.new()
	_detail_layer.add_child(_detail)
	_detail.confirmed.connect(_close_detail, CONNECT_DEFERRED)
	_detail.show_record(entries[index], false)

func _close_detail() -> void:
	if is_instance_valid(_detail_layer): _detail_layer.queue_free()
	_detail_layer = null
	_detail = null
