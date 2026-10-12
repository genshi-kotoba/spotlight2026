extends Control
## Audio Test 场景：全事件试听 + Switch/State/RTPC 调试台。
##
## 事件清单运行时解析自 res://Wwise/resources/WwiseProjectData.tres
## （集成插件扫描 Wwise 工程生成），Wwise 侧新增事件后，
## 在编辑器里让集成重扫一次，再点场景里的 [Refresh] 即可。
##
## 没有填音频文件的事件：post 成功但不出声，属正常，做好后直接来点。
## 操作：点按钮播事件；Esc 返回主菜单。

const PROJECT_DATA_PATH := "res://Wwise/resources/WwiseProjectData.tres"
const MAIN_MENU_PATH := "res://ui/main_menu/main_menu.tscn"

## Switch 调试项（名称须与 Wwise 工程一致）
const SWITCH_GROUPS := {
	"Foot_Material": ["Wood", "Mud", "Stone"],
	"Enemy_Tier": ["Normal", "Elite", "Boss"],
}
## State 调试项（全局作用域）
const STATE_GROUPS := {
	"Combat": ["Explore", "Battle"],
	"Scene": ["Workshop", "Slum", "Church", "ChurchTop"],
}
## RTPC 调试滑条：name -> [min, max, default]
const RTPC_ITEMS := {
	"Volume_Music": [0.0, 100.0, 100.0],
	"Volume_SFX": [0.0, 100.0, 100.0],
	"Volume_UI": [0.0, 100.0, 100.0],
	"Volume_Ambience": [0.0, 100.0, 100.0],
	"Volume_Voice": [0.0, 100.0, 100.0],
	"Tension": [0.0, 100.0, 0.0],
	"Player_Health": [0.0, 100.0, 100.0],
}

var _audio: Node
var _events: Array[Dictionary] = [] # {name, id, group}
var _status_label: Label
var _last_label: Label
var _list_box: VBoxContainer
var _filter_edit: LineEdit
var _panel: PanelContainer
var _panel_slider_cooldown_ms := 0

## UI 音效批次（面板交互路径）
const UI_SFX := {
	"hover": "SFX_001_UI_Hover",
	"click": "SFX_002_UI_Click",
	"back": "SFX_003_UI_Back",
	"panel_open": "SFX_004_UI_Panel_Open",
	"panel_close": "SFX_005_UI_Panel_Close",
	"slider": "SFX_028_UI_Slider",
	"error": "SFX_029_UI_Error",
	"win": "SFX_030_UI_Result_Win",
	"lose": "SFX_031_UI_Result_Lose",
}
const SLIDER_SFX_INTERVAL_MS := 90 ## 滑条音最短触发间隔（连拖防糊）


func _ready() -> void:
	_audio = get_node_or_null("/root/AudioService")
	_build_ui()
	_load_events()
	_rebuild_list()
	_refresh_status()
	if _audio and not _audio.is_ready:
		_audio.banks_loaded.connect(_on_banks_loaded)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _panel and _panel.visible:
			_toggle_panel(false) # 面板开着时 Esc = 关闭面板（003+005）
		else:
			get_tree().change_scene_to_file(MAIN_MENU_PATH)


func _on_banks_loaded() -> void:
	_refresh_status()


# ---------------------------------------------------------------- UI 构建

func _build_ui() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	# ---- 左栏：状态 + 调试台 ----
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 340
	left.add_theme_constant_override("separation", 8)
	root.add_child(left)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status_label)

	var stop_btn := Button.new()
	stop_btn.text = "STOP ALL"
	stop_btn.pressed.connect(_on_stop_all)
	left.add_child(stop_btn)

	var panel_btn := Button.new()
	panel_btn.text = "Open UI Panel (SFX_004)"
	panel_btn.pressed.connect(_toggle_panel.bind(true))
	left.add_child(panel_btn)

	left.add_child(HSeparator.new())
	left.add_child(_make_header("Switches (game object)"))
	for group_name in SWITCH_GROUPS:
		left.add_child(_make_button_row(group_name, SWITCH_GROUPS[group_name], _on_switch_pressed.bind(group_name)))

	left.add_child(HSeparator.new())
	left.add_child(_make_header("States (global)"))
	for group_name in STATE_GROUPS:
		left.add_child(_make_button_row(group_name, STATE_GROUPS[group_name], _on_state_pressed.bind(group_name)))

	left.add_child(HSeparator.new())
	left.add_child(_make_header("RTPCs"))
	for rtpc_name in RTPC_ITEMS:
		left.add_child(_make_rtpc_row(rtpc_name, RTPC_ITEMS[rtpc_name]))

	# ---- 右栏：事件列表 ----
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	root.add_child(right)

	var top_bar := HBoxContainer.new()
	right.add_child(top_bar)
	top_bar.add_child(_make_header("Events"))
	top_bar.add_child(_make_spacer())
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "filter..."
	_filter_edit.custom_minimum_size.x = 180
	_filter_edit.text_changed.connect(func(_t: String) -> void: _rebuild_list())
	top_bar.add_child(_filter_edit)
	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_on_refresh)
	top_bar.add_child(refresh_btn)

	_last_label = Label.new()
	_last_label.text = "last: -"
	right.add_child(_last_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)

	_build_ui_panel()


## 仿真 UI 面板：按真实交互路径试 UI 音效批次。
## 开=004 关=005 悬停=001 点击=002 返回=003 滑条=028 错误=029 胜/负=030/031
func _build_ui_panel() -> void:
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(420, 0)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.visible = false
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_panel.add_child(box)

	var title := _make_header("Test Panel")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(HSeparator.new())

	# 按钮区：点击类音效
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	_add_panel_button(grid, "OK (002 Click)", UI_SFX["click"])
	_add_panel_button(grid, "Back (003+005)", "", true)
	_add_panel_button(grid, "Error (029)", UI_SFX["error"])
	_add_panel_button(grid, "Win (030)", UI_SFX["win"])
	_add_panel_button(grid, "Lose (031)", UI_SFX["lose"])

	box.add_child(HSeparator.new())

	# 滑条区：028 连拖节流
	var slider_label := Label.new()
	slider_label.text = "Volume (028 Slider): 50"
	box.add_child(slider_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = 50.0
	slider.value_changed.connect(_on_panel_slider_changed.bind(slider_label))
	_hook_hover(slider)
	box.add_child(slider)

	var hint := Label.new()
	hint.text = "Esc = Back"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


func _add_panel_button(parent: Control, text: String, sfx: String, closes := false) -> void:
	var btn := Button.new()
	btn.text = text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(_on_panel_button.bind(sfx, closes))
	_hook_hover(btn)
	parent.add_child(btn)


## 悬停音（001）：面板内所有可交互控件统一挂
func _hook_hover(control: Control) -> void:
	control.mouse_entered.connect(func() -> void: _play_ui(UI_SFX["hover"]))


func _on_panel_button(sfx: String, closes: bool) -> void:
	if closes:
		_play_ui(UI_SFX["back"])
		_toggle_panel(false)
		return
	_play_ui(sfx)


func _on_panel_slider_changed(value: float, label: Label) -> void:
	label.text = "Volume (028 Slider): %.0f" % value
	# 连拖节流：028 必须极短，触发间隔也限一下，否则糊成一片
	var now := Time.get_ticks_msec()
	if now - _panel_slider_cooldown_ms < SLIDER_SFX_INTERVAL_MS:
		return
	_panel_slider_cooldown_ms = now
	_play_ui(UI_SFX["slider"])


func _toggle_panel(show: bool) -> void:
	if not _panel or _panel.visible == show:
		return
	_panel.visible = show
	_play_ui(UI_SFX["panel_open"] if show else UI_SFX["panel_close"])


func _play_ui(sfx: String) -> void:
	if not _audio or not _audio.is_ready:
		_last_label.text = "last: AudioService 未就绪，无法播放 " + sfx
		return
	var playing_id: int = _audio.play(sfx)
	_last_label.text = "last: %s  (playing_id=%d)" % [sfx, playing_id]


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	return label


func _make_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer


func _make_button_row(title: String, values: Array, callback: Callable) -> VBoxContainer:
	var box := VBoxContainer.new()
	var title_label := Label.new()
	title_label.text = title
	box.add_child(title_label)
	var row := HBoxContainer.new()
	box.add_child(row)
	for value in values:
		var btn := Button.new()
		btn.text = String(value)
		btn.toggle_mode = true
		btn.pressed.connect(callback.bind(String(value), btn))
		row.add_child(btn)
	return box


func _make_rtpc_row(rtpc_name: String, cfg: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "%s: %.0f" % [rtpc_name, cfg[2]]
	box.add_child(label)
	var slider := HSlider.new()
	slider.min_value = cfg[0]
	slider.max_value = cfg[1]
	slider.step = 1.0
	slider.value = cfg[2]
	slider.value_changed.connect(_on_rtpc_changed.bind(rtpc_name, label))
	box.add_child(slider)
	return box


func _on_rtpc_changed(value: float, rtpc_name: String, label: Label) -> void:
	label.text = "%s: %.0f" % [rtpc_name, value]
	if _audio and _audio.is_ready:
		_audio.set_rtpc(rtpc_name, value)


# ---------------------------------------------------------------- 事件清单

func _load_events() -> void:
	_events.clear()
	if not FileAccess.file_exists(PROJECT_DATA_PATH):
		push_warning("AudioTest: 找不到 " + PROJECT_DATA_PATH)
		return
	var text := FileAccess.get_file_as_string(PROJECT_DATA_PATH)
	var current: Dictionary = {}
	for line in text.split("\n"):
		if line.begins_with("["):
			if not current.is_empty() and not current["name"].is_empty():
				_events.append(current)
			current = {}
			if line.begins_with("[sub_resource type=\"WwiseTreeObjectEvent\""):
				current = {"name": "", "id": 0, "group": "Misc"}
		elif not current.is_empty():
			if line.begins_with("path = "):
				var path := line.trim_prefix("path = ").strip_edges().trim_suffix("\"").trim_prefix("\"")
				var parts := path.split("\\", false)
				if parts.size() >= 2:
					current["group"] = parts[parts.size() - 2]
			elif line.begins_with("name = "):
				current["name"] = line.trim_prefix("name = ").strip_edges().trim_suffix("\"").trim_prefix("\"")
			elif line.begins_with("id = "):
				current["id"] = int(line.trim_prefix("id = ").strip_edges())
	if not current.is_empty() and not current["name"].is_empty():
		_events.append(current)
	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])


func _rebuild_list() -> void:
	for child in _list_box.get_children():
		child.queue_free()
	var filter := _filter_edit.text.to_lower() if _filter_edit else ""
	var last_group := ""
	for event in _events:
		if not filter.is_empty() and not String(event["name"]).to_lower().contains(filter):
			continue
		if event["group"] != last_group:
			last_group = event["group"]
			var header := Label.new()
			header.text = "── " + last_group + " ──"
			header.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
			_list_box.add_child(header)
		var btn := Button.new()
		btn.text = event["name"]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_play_event.bind(event))
		_list_box.add_child(btn)


# ---------------------------------------------------------------- 动作

func _play_event(event: Dictionary) -> void:
	if not _audio or not _audio.is_ready:
		_last_label.text = "last: AudioService 未就绪，无法播放 " + event["name"]
		return
	var playing_id: int = _audio.play(event["name"])
	_last_label.text = "last: %s  (playing_id=%d%s)" % [
		event["name"], playing_id,
		"" if playing_id > 0 else "  ← 失败：bank 未加载或事件不在 bank 里",
	]


func _on_switch_pressed(group_name: String, value: String, btn: Button) -> void:
	# 同组按钮互斥显示
	for sibling in btn.get_parent().get_children():
		if sibling is Button and sibling != btn:
			sibling.button_pressed = false
	if _audio and _audio.is_ready:
		_audio.set_switch(group_name, value)
	_last_label.text = "switch: %s = %s" % [group_name, value]


func _on_state_pressed(group_name: String, value: String, btn: Button) -> void:
	for sibling in btn.get_parent().get_children():
		if sibling is Button and sibling != btn:
			sibling.button_pressed = false
	if _audio and _audio.is_ready:
		_audio.set_state(group_name, value)
	_last_label.text = "state: %s = %s" % [group_name, value]


func _on_stop_all() -> void:
	if _audio and _audio.is_ready:
		_audio.stop_all()
	_last_label.text = "stopped all"


func _on_refresh() -> void:
	_load_events()
	_rebuild_list()
	_refresh_status()


func _refresh_status() -> void:
	if not _audio:
		_status_label.text = "AudioService autoload 缺失！检查 project.godot"
		return
	var sfx := "OK" if _audio.bank_ok("SFX") else "FAIL"
	var music := "OK" if _audio.bank_ok("Music") else "FAIL"
	_status_label.text = "ready=%s | SFX.bnk=%s Music.bnk=%s | events=%d" % [
		str(_audio.is_ready), sfx, music, _events.size(),
	]
