extends Control

var visible_entries: Array[Dictionary] = []
var _list: VBoxContainer
var _status: Label


func _ready() -> void:
	var body := CatalogUi.shell(self, "成就", "当前档案的成就 · 要求与奖励由 CSV 提供")
	_status = CatalogUi.label("")
	_status.name = "Status"
	body.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.name = "Entries"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 18)
	scroll.add_child(_list)
	TextCatalog.catalog_changed.connect(refresh)
	TextCatalog.progress_changed.connect(refresh)
	refresh()


func refresh() -> void:
	if not is_node_ready():
		return
	visible_entries = TextCatalog.entries("achievements")
	CatalogUi.clear(_list)
	var completed := 0
	for record: Dictionary in visible_entries:
		var done := TextCatalog.is_unlocked("achievements", record.id)
		completed += int(done)
		# 用背景区分完成状态，不展示编号/内部状态，不添加详情入口。
		var panel := PanelContainer.new()
		panel.name = "Achievement_" + record.id
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := CatalogUi.panel_style(Color("30483e") if done else Color("252b37"))
		style.content_margin_left = 28
		style.content_margin_right = 28
		style.content_margin_top = 20
		style.content_margin_bottom = 20
		panel.add_theme_stylebox_override("panel", style)
		_list.add_child(panel)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 12)
		panel.add_child(box)
		box.add_child(CatalogUi.label(record.name, 32))
		box.add_child(CatalogUi.label("要求：" + record.requirement, 24))
		box.add_child(CatalogUi.label("奖励：" + record.reward, 24))
	var error := TextCatalog.error_message("achievements")
	_status.text = "已完成 %d / %d（绿色底色表示已完成）" % [completed, visible_entries.size()]
	if not error.is_empty():
		_status.text = "数据读取失败：" + error
	elif visible_entries.is_empty():
		_status.text = "暂无成就。请在成就 CSV 中填写条目。"
