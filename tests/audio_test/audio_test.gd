extends Control
## Audio Test 场景：全事件试听 + Switch/State/RTPC 调试台 + UI 面板仿真。
##
## 数据源 = bank 生成物 res://wwise_soundbanks/Windows/*.json（每次
## Wwise 重生成 bank 自动更新，永远与运行时 bank 内容一致）：
##   - 事件清单（含分组、是否有音频文件——无音频的置灰标注）
##   - Switch 组 / State 组 / RTPC 列表（调试台自动构建）
## 操作：点按钮播事件；Esc 返回主菜单（面板开着时先关面板）。

const BANK_JSON_DIR := "res://wwise_soundbanks/Windows/"
const BANK_JSONS: Array[String] = ["Init.json", "SFX.json", "Music.json"]
const MAIN_MENU_PATH := "res://ui/main_menu/main_menu.tscn"
const RTPC_EXCLUDE_PREFIX := "SS_Air_" ## Wwise 自带工厂参数，不显示
const GAME_PARAMS_WWU := "res://WwiseProject/Game Parameters/Default Work Unit.wwu"
## RTPC 后备默认值（wwu 里没写 InitialValue 时用）；范围缺省 0–100
const RTPC_DEFAULTS := {
	"Volume_Music": 100.0,
	"Volume_SFX": 100.0,
	"Volume_UI": 100.0,
	"Volume_Ambience": 100.0,
	"Volume_Voice": 100.0,
	"Player_Health": 100.0,
}

var _audio: Node
var _events: Array[Dictionary] = [] # {name, id, group, has_audio}
var _switch_groups: Dictionary = {} # group_name -> Array[String]
var _state_groups: Dictionary = {} # group_name -> Array[String]
var _rtpc_names: Array[String] = []
var _rtpc_ranges: Dictionary = {} # name -> {min, max, initial}
var _banks_found: Array[String] = []

var _main_box: HBoxContainer
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
	_build_ui_panel() # 先建面板，保证它永远在最上层
	_load_bank_data()
	_build_ui()
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


# ---------------------------------------------------------------- 数据加载

## 从 bank 生成物 JSON 读取事件 / Switch / State / RTPC。
## 与运行时 bank 内容严格一致——bank 里都没有的东西，post 了也不会响。
func _load_bank_data() -> void:
	_events.clear()
	_switch_groups.clear()
	_state_groups.clear()
	_rtpc_names.clear()
	_banks_found.clear()
	var seen_events: Dictionary = {}

	for file_name in BANK_JSONS:
		var path := BANK_JSON_DIR + file_name
		if not FileAccess.file_exists(path):
			continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not data is Dictionary:
			continue
		_banks_found.append(file_name.get_basename())
		var banks: Array = data.get("SoundBanksInfo", {}).get("SoundBanks", [])
		for bank in banks:
			for ev in bank.get("Events", []):
				var ev_name: String = ev.get("Name", "")
				if ev_name.is_empty() or seen_events.has(ev_name):
					continue
				seen_events[ev_name] = true
				var object_path: String = ev.get("ObjectPath", "")
				var parts := object_path.split("\\", false)
				_events.append({
					"name": ev_name,
					"id": int(ev.get("Id", "0")),
					"group": parts[parts.size() - 2] if parts.size() >= 2 else "Misc",
					"has_audio": _event_has_audio(ev),
				})
			for sg in bank.get("SwitchGroups", []):
				var values: Array[String] = []
				for sw in sg.get("Switches", []):
					values.append(sw.get("Name", ""))
				if not values.is_empty():
					_switch_groups[sg.get("Name", "")] = values
			for sg in bank.get("StateGroups", []):
				var values: Array[String] = []
				for st in sg.get("States", []):
					var st_name: String = st.get("Name", "")
					if st_name != "None": # None 没有试听意义
						values.append(st_name)
				if not values.is_empty():
					_state_groups[sg.get("Name", "")] = values
			for gp in bank.get("GameParameters", []):
				var gp_name: String = gp.get("Name", "")
				if not gp_name.begins_with(RTPC_EXCLUDE_PREFIX) and not _rtpc_names.has(gp_name):
					_rtpc_names.append(gp_name)

	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	_rtpc_names.sort()
	_load_rtpc_ranges()


## 从 Wwise 工程的 Game Parameters 工作单元读真实 Min/Max/InitialValue
## （bank JSON 不含范围）。wwu 缺省值按 Wwise 默认：Min=0, Max=100。
func _load_rtpc_ranges() -> void:
	_rtpc_ranges.clear()
	for rtpc_name in _rtpc_names:
		_rtpc_ranges[rtpc_name] = {"min": 0.0, "max": 100.0, "initial": RTPC_DEFAULTS.get(rtpc_name, 50.0)}
	if not FileAccess.file_exists(GAME_PARAMS_WWU):
		return
	var text := FileAccess.get_file_as_string(GAME_PARAMS_WWU)
	var block_re := RegEx.new()
	block_re.compile("(?s)<GameParameter Name=\"(?<name>[^\"]+)\"[^>]*>(?<body>.*?)</GameParameter>")
	var prop_re := RegEx.new()
	prop_re.compile("Property Name=\"(?<prop>InitialValue|Min|Max)\"[^>]*Value=\"(?<val>[^\"]+)\"")
	for block in block_re.search_all(text):
		var gp_name := block.get_string("name")
		if not _rtpc_ranges.has(gp_name):
			continue
		var range: Dictionary = _rtpc_ranges[gp_name]
		for prop in prop_re.search_all(block.get_string("body")):
			var value := prop.get_string("val").to_float()
			match prop.get_string("prop"):
				"Min":
					range["min"] = value
				"Max":
					range["max"] = value
				"InitialValue":
					range["initial"] = value


## 事件是否含音频：普通事件在顶层 MediaRefs；Switch 容器事件在
## SwitchContainers[].MediaRefs（顶层是空的， FOOTSTEPS/010 就是这种）。
func _event_has_audio(ev: Dictionary) -> bool:
	if not ev.get("MediaRefs", []).is_empty():
		return true
	for container in ev.get("SwitchContainers", []):
		if not container.get("MediaRefs", []).is_empty():
			return true
	return false


# ---------------------------------------------------------------- UI 构建

func _build_ui() -> void:
	_main_box = HBoxContainer.new()
	_main_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main_box.add_theme_constant_override("separation", 12)
	# 面板保持在最上层：main_box 插到面板之前
	if _panel:
		add_child(_main_box)
		move_child(_main_box, _panel.get_index())
	else:
		add_child(_main_box)

	# ---- 左栏：状态 + 调试台（可滚动，组多了也不挤）----
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size.x = 360
	_main_box.add_child(left_scroll)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	left_scroll.add_child(left)

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
	if _switch_groups.is_empty():
		left.add_child(_make_hint("bank 里还没有 Switch"))
	else:
		for group_name in _switch_groups:
			left.add_child(_make_button_row(group_name, _switch_groups[group_name], _on_switch_pressed))

	left.add_child(HSeparator.new())
	left.add_child(_make_header("States (global)"))
	if _state_groups.is_empty():
		left.add_child(_make_hint("bank 里还没有 State"))
	else:
		for group_name in _state_groups:
			left.add_child(_make_button_row(group_name, _state_groups[group_name], _on_state_pressed))

	left.add_child(HSeparator.new())
	left.add_child(_make_header("RTPCs"))
	for rtpc_name in _rtpc_names:
		left.add_child(_make_rtpc_row(rtpc_name))

	# ---- 右栏：事件列表 ----
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	_main_box.add_child(right)

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


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	return label


func _make_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	return label


func _make_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer


## 一组互斥按钮（Switch/State 通用）；值多了用 HFlowContainer 自动换行。
## handler 为未绑定的方法引用（_on_switch_pressed / _on_state_pressed），
## 调用时显式传 (group_name, value, btn)——不做链式 bind
## （链式 bind 的参数顺序是"后绑在前"，会把 btn 顶到第 2 个参数导致转换失败）。
func _make_button_row(group_name: String, values: Array, handler: Callable) -> VBoxContainer:
	var box := VBoxContainer.new()
	var title_label := Label.new()
	title_label.text = group_name
	box.add_child(title_label)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 4)
	box.add_child(row)
	for value in values:
		var v := String(value)
		var btn := Button.new()
		btn.text = v
		btn.toggle_mode = true
		btn.pressed.connect(func() -> void: handler.call(group_name, v, btn))
		row.add_child(btn)
	return box


func _make_rtpc_row(rtpc_name: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var range: Dictionary = _rtpc_ranges.get(rtpc_name, {"min": 0.0, "max": 100.0, "initial": 50.0})
	var label := Label.new()
	label.text = "%s: %.0f  [%.0f–%.0f]" % [rtpc_name, range["initial"], range["min"], range["max"]]
	box.add_child(label)
	var slider := HSlider.new()
	slider.min_value = range["min"]
	slider.max_value = range["max"]
	slider.step = 1.0 if range["max"] - range["min"] <= 50.0 else 0.5
	slider.value = range["initial"]
	slider.value_changed.connect(_on_rtpc_changed.bind(rtpc_name, label, range))
	box.add_child(slider)
	return box


func _on_rtpc_changed(value: float, rtpc_name: String, label: Label, range: Dictionary) -> void:
	label.text = "%s: %.0f  [%.0f–%.0f]" % [rtpc_name, value, range["min"], range["max"]]
	if _audio and _audio.is_ready:
		_audio.set_rtpc(rtpc_name, value)


# ---------------------------------------------------------------- 事件列表

func _rebuild_list() -> void:
	for child in _list_box.get_children():
		child.queue_free()
	var filter := _filter_edit.text.to_lower() if _filter_edit else ""
	var last_group := ""
	var no_audio_count := 0
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
		if event["has_audio"]:
			btn.text = event["name"]
		else:
			btn.text = "%s   (no audio)" % event["name"]
			btn.modulate = Color(1, 1, 1, 0.45)
			no_audio_count += 1
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_play_event.bind(event))
		_list_box.add_child(btn)


# ---------------------------------------------------------------- 动作

func _play_event(event: Dictionary) -> void:
	if not _audio or not _audio.is_ready:
		_last_label.text = "last: AudioService 未就绪，无法播放 " + event["name"]
		return
	var playing_id: int = _audio.play(event["name"])
	var note := ""
	if playing_id <= 0:
		note = "  ← post 失败"
	elif not event["has_audio"]:
		note = "  ← post 成功，但事件里还没填音频，所以无声（正常）"
	_last_label.text = "last: %s  (playing_id=%d)%s" % [event["name"], playing_id, note]


## 单选行为：点选的保持按下，同组其余全部弹起（再点已选中的也不会灭）
func _select_exclusive(btn: Button) -> void:
	for sibling in btn.get_parent().get_children():
		if sibling is Button:
			sibling.button_pressed = (sibling == btn)


func _on_switch_pressed(group_name: String, value: String, btn: Button) -> void:
	_select_exclusive(btn)
	if _audio and _audio.is_ready:
		var ok: bool = _audio.set_switch(group_name, value)
		_last_label.text = "switch: %s = %s → SDK 返回 %s" % [group_name, value, "成功" if ok else "失败（组/值没解析到）"]
	else:
		_last_label.text = "switch: AudioService 未就绪"


func _on_state_pressed(group_name: String, value: String, btn: Button) -> void:
	_select_exclusive(btn)
	if _audio and _audio.is_ready:
		var ok: bool = _audio.set_state(group_name, value)
		_last_label.text = "state: %s = %s → SDK 返回 %s" % [group_name, value, "成功" if ok else "失败"]
	else:
		_last_label.text = "state: AudioService 未就绪"


func _on_stop_all() -> void:
	if _audio and _audio.is_ready:
		_audio.stop_all()
	_last_label.text = "stopped all"


func _on_refresh() -> void:
	# 整棵左栏+右栏重建（Switch/State/RTPC 结构可能变了），面板保留
	_main_box.queue_free()
	_load_bank_data()
	_build_ui()
	_rebuild_list()
	_refresh_status()


func _refresh_status() -> void:
	if not _audio:
		_status_label.text = "AudioService autoload 缺失！检查 project.godot"
		return
	var sfx := "OK" if _audio.bank_ok("SFX") else "FAIL"
	var music := "OK" if _audio.bank_ok("Music") else "FAIL"
	var no_audio := _events.count(func(e: Dictionary) -> bool: return not e["has_audio"])
	_status_label.text = "ready=%s | SFX.bnk=%s Music.bnk=%s | banks: %s | events=%d (no audio: %d)" % [
		str(_audio.is_ready), sfx, music, "+".join(PackedStringArray(_banks_found)), _events.size(), no_audio,
	]


# ---------------------------------------------------------------- UI 面板仿真

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
