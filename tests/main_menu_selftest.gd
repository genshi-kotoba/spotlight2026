extends SceneTree

## PRG-016 / PRG-021 开始界面与设置的自测。用 --script 跑，不依赖渲染。
##
##   godot --headless --path . --script res://tests/main_menu_selftest.gd
##
## 覆盖 docs/prompts/PRG-016-021-开始界面与设置.md §十 的占位期清单。
## 占位期不碰 state_machines/：SaveGateway 只读档案 JSON 与自己的全局设置文件，
## 最后一条用例就是守住这件事——新游戏、继续、死亡的状态流转不许由界面来判。
##
## 注意事项（本工程踩过的坑）：
##   - 工程把警告当错误，不要用 := 承接返回类型为 Variant 的表达式。
##   - 信号接内部类记录器，不接 lambda（lambda 对捕获变量只读，且会报 ObjectDB leaked）。
##   - 本测试在 user://save 下造假档案与设置，跑完把改动撤回去。

const MAIN_MENU_PATH := "res://ui/main_menu/main_menu.tscn"
const PROFILE_SWITCH_PATH := "res://ui/main_menu/profile_switch.tscn"
const SETTINGS_SCENE_PATH := "res://ui/settings/settings.tscn"
const PLACEHOLDER_RUN_PATH := "res://ui/placeholder_run/placeholder_run.tscn"

const GATEWAY_SCRIPT_PATH := "res://autoload/save_gateway.gd"
const MENU_SCRIPT_PATH := "res://ui/main_menu/main_menu.gd"
const SWITCH_SCRIPT_PATH := "res://ui/main_menu/profile_switch.gd"
const SETTINGS_SCRIPT_PATH := "res://ui/settings/settings.gd"
const RUN_SCRIPT_PATH := "res://ui/placeholder_run/placeholder_run.gd"

const BUTTON_TEXTS: Array[String] = ["继续游戏", "新游戏", "设置", "成就", "感谢名单", "退出游戏"]
const TITLE_TEXT := "这里是标题"
const VERSION_TEXT := "v0.1.0"

const SAVE_DIR := "user://save"
const SLOT1_PATH := "user://save/slot1.json"
const SLOT2_PATH := "user://save/slot2.json"
const SETTINGS_FILE := "user://save/settings.json"
const BROKEN_SETTINGS_PATH := "user://no_such_dir/settings.json"

var _failures := 0
var _gateway: Node = null
var _recorder := Recorder.new()
## 文件名 → 内容。跑之前把 user://save 整个备份下来，跑完放回去，不动玩家自己的档。
var _save_backup := {}


class Recorder:
	var active_slot_changes: Array[int] = []
	var refreshed_count := 0
	var failure_messages: Array[String] = []

	func on_active_slot_changed(slot: int) -> void:
		active_slot_changes.append(slot)

	func on_slots_refreshed() -> void:
		refreshed_count += 1

	func on_save_failed(_error: int, message: String) -> void:
		failure_messages.append(message)


func _initialize() -> void:
	# --script 模式下 _initialize() 跑在 SceneTree 迭代之前，add_child 不触发 ready、
	# @onready 变量全是 null。等一帧再跑，时序才和真实运行一致。
	await process_frame

	_gateway = root.get_node_or_null("SaveGateway")
	if _gateway != null:
		_gateway.active_slot_changed.connect(_recorder.on_active_slot_changed)
		_gateway.slots_refreshed.connect(_recorder.on_slots_refreshed)
		_gateway.save_failed.connect(_recorder.on_save_failed)

	_backup_save_dir()
	_clear_save_dir()

	_test_gateway_registered()
	_test_slots_start_empty()
	_test_active_slot_round_trip()
	_test_injected_active_run()
	await _test_main_menu()
	await _test_placeholder_run_loop()
	await _test_profile_switch()
	await _test_settings_screen()
	_test_setting_persistence()
	_test_directory_created_on_demand()
	_test_save_failed_signal()
	_test_scripts_never_write_run_state()

	_restore_save_dir()
	if _failures == 0:
		print("全部通过")
	else:
		print("失败 %d 项" % _failures)
	quit(_failures)


# ------------------------------------------------------------------ 用例

func _test_gateway_registered() -> void:
	_check("SaveGateway 已登记为 autoload", _gateway != null)
	if _gateway == null:
		return
	_check("网关就是指到 autoload/save_gateway.gd 的那个节点",
		(_gateway.get_script() as Script) != null
			and (_gateway.get_script() as Script).resource_path == GATEWAY_SCRIPT_PATH)


func _test_slots_start_empty() -> void:
	var slots: Array = _gateway.list_slots()
	_check("list_slots() 返回三项", slots.size() == 3, "实际 %d 项" % slots.size())
	var all_empty := true
	for item: Variant in slots:
		if item is Dictionary:
			var info: Dictionary = item
			if bool(info.get("exists", true)) or String(info.get("state", "")) != "empty":
				all_empty = false
	_check("空档 exists 为假、state 为 empty", all_empty)
	_check("空档没有可继续的局", not bool(_gateway.has_continuable_run()))


func _test_active_slot_round_trip() -> void:
	var error: Error = _gateway.set_active_slot(2)
	_check("set_active_slot(2) 返回 OK", error == OK)
	_check("get_active_slot() 读回 2", int(_gateway.get_active_slot()) == 2)
	_check("发出了 active_slot_changed",
		not _recorder.active_slot_changes.is_empty() and _recorder.active_slot_changes[-1] == 2)
	_gateway.set_active_slot(1)


func _test_injected_active_run() -> void:
	_write_json(SLOT1_PATH, {
		"save_version": 1,
		"unlocked_cards": ["bonk"],
		"run_history": [{"result": "defeat"}],
		"active_run": {
			"run_snapshot": {
				"health": 30,
				"max_health": 80,
				"gold": 12,
				"current_map_id": "贫民窟",
			},
		},
	})
	_gateway.set_active_slot(1)
	var info := _slot_info(1)
	_check("注入的档被判为进行中", String(info.get("state", "")) == "active",
		"实际 %s" % String(info.get("state", "")))
	_check("生命读成 int", typeof(info.get("health")) == TYPE_INT and int(info.get("health")) == 30)
	_check("金币读成 int", typeof(info.get("gold")) == TYPE_INT and int(info.get("gold")) == 12)
	_check("区域读出来", String(info.get("region", "")) == "贫民窟")
	_check("对局记录条数读出来", int(info.get("run_count", 0)) == 1)
	_check("当前档有可继续的局", bool(_gateway.has_continuable_run()))


func _test_main_menu() -> void:
	var menu := _instantiate(MAIN_MENU_PATH)
	if menu == null:
		return
	await process_frame

	var texts: Array[String] = []
	for child: Node in menu.get_node("按钮列").get_children():
		if child is Button:
			texts.append((child as Button).text)
	_check("六个按钮文案正确", texts == BUTTON_TEXTS, "实际 %s" % str(texts))
	_check("标题是占位文字", _label_text(menu, "标题") == TITLE_TEXT)
	_check("右下角是版本号", _label_text(menu, "版本") == VERSION_TEXT)
	_check("右上角显示当前档案", _button_text(menu, "档案").contains("当前档案"))

	var continue_button := menu.get_node("按钮列/继续游戏") as Button
	_check("当前档有进行中的局时「继续游戏」可点", not continue_button.disabled)

	_gateway.set_active_slot(3)
	menu.call("refresh")
	_check("当前档为空时「继续游戏」置灰", continue_button.disabled)
	_gateway.set_active_slot(1)
	menu.free()


## 占位跑图这一圈要闭环：开一局 → 主菜单的「继续游戏」亮 → 继续回得来 →
## 放弃之后置灰，而且同一个档还能再开一局。
func _test_placeholder_run_loop() -> void:
	_clear_save_dir()
	_gateway.set_active_slot(1)

	var start_error: Error = _gateway.start_new_run("selftest-seed", {})
	_check("开新局返回 OK", start_error == OK)
	_check("开完局当前档有进行中的局", bool(_gateway.has_continuable_run()))
	var info := _slot_info(1)
	_check("归档被标成进行中", String(info.get("state", "")) == "active")
	_check("占位局报出场景名", String(info.get("region", "")) == "占位跑图")
	_check("占位局进度从 0 起", int(info.get("progress", -1)) == 0)

	var progress_error: Error = _gateway.set_run_progress(7)
	_check("写局内进度返回 OK", progress_error == OK)
	_check("进度写进了档案", int(_slot_info(1).get("progress", -1)) == 7)

	# 重新载入场景：进度从档案里读回来，这就是「继续游戏」接回同一局的证据。
	var run_scene := _instantiate(PLACEHOLDER_RUN_PATH)
	if run_scene != null:
		await process_frame
		_check("占位场景读回档案里的进度", _label_text(run_scene, "界面/进度").contains("7"))
		var buttons: Array[String] = []
		for child: Node in run_scene.get_node("界面/按钮行").get_children():
			if child is Button:
				buttons.append((child as Button).text)
		_check("占位场景只有两个出口", buttons == ["回主菜单", "放弃本局"], "实际 %s" % str(buttons))
		run_scene.free()

	var continue_error: Error = _gateway.continue_saved_run()
	_check("继续游戏返回 OK", continue_error == OK)
	_check("继续之后进度还在", int(_slot_info(1).get("progress", -1)) == 7)

	var abandon_error: Error = _gateway.abandon_run()
	_check("放弃本局返回 OK", abandon_error == OK)
	_check("放弃之后继续游戏置灰", not bool(_gateway.has_continuable_run()))
	_check("放弃之后档案判为已结束", String(_slot_info(1).get("state", "")) == "ended")
	_check("放弃之后档案文件还在", FileAccess.file_exists(SLOT1_PATH))

	_check("没有进行中的局时继续游戏会失败", _gateway.continue_saved_run() != OK)
	_recorder.failure_messages.clear()

	var restart_error: Error = _gateway.start_new_run("selftest-seed-2", {})
	_check("同一个档可以再开一局", restart_error == OK and bool(_gateway.has_continuable_run()))


func _test_profile_switch() -> void:
	_write_json(SLOT2_PATH, {
		"save_version": 1,
		"run_history": [{"result": "victory"}, {"result": "defeat"}],
	})
	var screen := _instantiate(PROFILE_SWITCH_PATH)
	if screen == null:
		return
	await process_frame

	var cards: Array[Node] = screen.get_node("卡片行").get_children()
	_check("切换档案屏有三张卡片", cards.size() == 3, "实际 %d 张" % cards.size())
	if cards.size() != 3:
		screen.free()
		return
	var first := cards[0] as SlotCard
	var second := cards[1] as SlotCard
	var third := cards[2] as SlotCard
	_check("第一张卡显示进行中", _label_text(first, "状态") == "进行中")
	_check("第二张卡显示已结束", _label_text(second, "状态") == "已结束")
	_check("墓碑卡显示对局数", _label_text(second, "摘要").contains("对局 2"))
	_check("第三张卡显示空", _label_text(third, "状态") == "空")
	_check("当前档案标在对应卡片上",
		first.get_node("当前标注").visible and not second.get_node("当前标注").visible)

	screen.call("select_slot", 2)
	_check("选中态只落在选中的卡片",
		not first.button_pressed and second.button_pressed and not third.button_pressed)

	var delete_button := screen.get_node("按钮行/删除存档") as Button
	screen.call("select_slot", 3)
	_check("选中空档时删除按钮置灰", delete_button.disabled)

	screen.call("select_slot", 2)
	delete_button.pressed.emit()
	var dialog := screen.get_node("确认弹窗") as Control
	_check("点删除存档会弹确认", dialog.visible)
	(dialog.get_node("面板/按钮行/取消") as Button).pressed.emit()
	_check("取消后档案还在", FileAccess.file_exists(SLOT2_PATH))
	_check("取消后弹窗收起来", not dialog.visible)

	delete_button.pressed.emit()
	(dialog.get_node("面板/按钮行/确定") as Button).pressed.emit()
	_check("确认后档案文件被删掉", not FileAccess.file_exists(SLOT2_PATH))
	_check("确认后卡片回到空态", _label_text(second, "状态") == "空")
	_check("删档发出了 slots_refreshed", _recorder.refreshed_count > 0)
	screen.free()


func _test_settings_screen() -> void:
	# 先把这两项摆回默认：设置是全局的，上一次跑测试留下的值会带进来。
	_gateway.set_setting("fullscreen", true)
	_gateway.set_setting("resolution", "1920x1080")
	var screen := _instantiate(SETTINGS_SCENE_PATH)
	if screen == null:
		return
	await process_frame

	var master := screen.get_node("面板/条目/主音量/滑条") as HSlider
	var master_value := screen.get_node("面板/条目/主音量/数值") as Label
	var fullscreen_button := screen.get_node("面板/条目/全屏/开关") as CheckButton
	var resolution_button := screen.get_node("面板/条目/分辨率/下拉") as OptionButton
	_check("分辨率下拉三档", resolution_button.item_count == 3,
		"实际 %d 档" % resolution_button.item_count)
	_check("全屏默认开", fullscreen_button.button_pressed)
	_check("全屏时分辨率置灰", resolution_button.disabled)

	master.value = 55.0
	_check("拖滑条写进设置", int(_gateway.get_setting("master_volume", 0)) == 55)
	_check("数值标签跟着走", master_value.text == "55")

	fullscreen_button.button_pressed = false
	_check("关掉全屏写进设置", not bool(_gateway.get_setting("fullscreen", true)))
	_check("关掉全屏后分辨率可点", not resolution_button.disabled)

	resolution_button.select(1)
	resolution_button.item_selected.emit(1)
	_check("选分辨率写进设置", String(_gateway.get_setting("resolution", "")) == "1600x900")
	screen.free()


func _test_setting_persistence() -> void:
	var error: Error = _gateway.set_setting("sfx_volume", 42)
	_check("写设置返回 OK", error == OK)
	var read_back: Variant = _gateway.get_setting("sfx_volume", null)
	_check("读回同值", read_back != null and int(read_back) == 42)
	_check("读回仍是 int", typeof(read_back) == TYPE_INT, "实际 %s" % type_string(typeof(read_back)))
	_check("设置文件写出来了", FileAccess.file_exists(SETTINGS_FILE))

	var parsed := _read_json(SETTINGS_FILE)
	var stored_section: Variant = parsed.get("settings")
	if stored_section is Dictionary:
		_check("文件里的设置项在场",
			(stored_section as Dictionary).has("sfx_volume"),
			"实际 %s" % str(stored_section))
	_check("文件里写的是整数形态",
		_read_text(SETTINGS_FILE).replace(" ", "").contains("\"sfx_volume\":42"))

	_gateway.call("_load_settings")
	var reloaded: Variant = _gateway.get_setting("sfx_volume", null)
	_check("重读之后还是 int 且同值",
		typeof(reloaded) == TYPE_INT and int(reloaded) == 42)


func _test_directory_created_on_demand() -> void:
	_clear_save_dir()
	_recorder.failure_messages.clear()
	var error: Error = _gateway.set_setting("master_volume", 33)
	_check("目录被删掉后也能写", error == OK)
	_check("自动把目录建回来", DirAccess.dir_exists_absolute(SAVE_DIR))
	_check("这一步没有 save_failed", _recorder.failure_messages.is_empty(),
		"实际 %s" % str(_recorder.failure_messages))


func _test_save_failed_signal() -> void:
	_recorder.failure_messages.clear()
	_gateway.settings_path = BROKEN_SETTINGS_PATH
	var error: Error = _gateway.set_setting("master_volume", 44)
	_check("写不进去时返回错误", error != OK)
	_check("写不进去时发 save_failed", not _recorder.failure_messages.is_empty())
	_gateway.settings_path = SETTINGS_FILE


## 守住用户最在意的那条：新游戏、继续、死亡的状态流转只归 GlobalState，
## 界面脚本一个字都不许提 active_run，网关只准读它。
func _test_scripts_never_write_run_state() -> void:
	for path: String in [MENU_SCRIPT_PATH, SWITCH_SCRIPT_PATH, SETTINGS_SCRIPT_PATH, RUN_SCRIPT_PATH]:
		_check("%s 不碰 active_run" % path.get_file(), not _read_text(path).contains("active_run"))
	_check("网关只读 active_run，不写", not _assigns_run_state(_read_text(GATEWAY_SCRIPT_PATH)))


func _assigns_run_state(text: String) -> bool:
	for line: String in text.split("\n"):
		var found_at := line.find("active_run")
		if found_at < 0:
			continue
		var equals_at := line.find("=")
		if equals_at >= 0 and found_at < equals_at:
			return true
	return false


# ------------------------------------------------------------------ 工具

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  通过  %s" % label)
	else:
		_failures += 1
		print("  失败  %s  %s" % [label, detail])


func _instantiate(path: String) -> Node:
	var scene: PackedScene = load(path)
	if scene == null:
		_check("能载入 %s" % path, false)
		return null
	var node: Node = scene.instantiate()
	root.add_child(node)
	return node


func _slot_info(slot: int) -> Dictionary:
	var slots: Array = _gateway.list_slots()
	for item: Variant in slots:
		if item is Dictionary and int((item as Dictionary).get("slot", 0)) == slot:
			return item as Dictionary
	return {}


func _label_text(node: Node, path: String) -> String:
	var label := node.get_node_or_null(path) as Label
	return label.text if label != null else ""


func _button_text(node: Node, path: String) -> String:
	var button := node.get_node_or_null(path) as Button
	return button.text if button != null else ""


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(_read_text(path))
	if parsed is Dictionary:
		return parsed
	return {}


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check("能写 %s" % path, false)
		return
	file.store_string(JSON.stringify(data))
	file.close()


## 清掉假档案与设置。跑完用 _restore_save_dir() 把进来之前的设置还原。
func _clear_save_dir() -> void:
	if DirAccess.dir_exists_absolute(SAVE_DIR):
		for file_name: String in DirAccess.get_files_at(SAVE_DIR):
			DirAccess.remove_absolute(SAVE_DIR + "/" + file_name)
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)


func _backup_save_dir() -> void:
	_save_backup.clear()
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		return
	for file_name: String in DirAccess.get_files_at(SAVE_DIR):
		_save_backup[file_name] = _read_text(SAVE_DIR + "/" + file_name)


func _restore_save_dir() -> void:
	_clear_save_dir()
	for file_name: String in _save_backup:
		var file := FileAccess.open(SAVE_DIR + "/" + file_name, FileAccess.WRITE)
		if file != null:
			file.store_string(String(_save_backup[file_name]))
			file.close()
	if _gateway != null:
		_gateway.settings_path = SETTINGS_FILE
		_gateway.call("_load_settings")
