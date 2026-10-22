## 诊断块：一个「导出诊断日志」按钮，主菜单设置页与跑图设置页共用这一份。
##
## 日志怎么落地不在这里，见 systems/diagnostics/runtime_log.gd。
## 桌面：生成 user://logs/export-<时间>/ 并打开目录。
## 移动端：应用私有目录玩家拿不到，先尝试复制到系统下载目录；
## 复制不成则把最近事件塞进剪贴板，玩家直接粘贴到反馈群。

const RUNTIME_LOG := preload("res://systems/diagnostics/runtime_log.gd")

const BLOCK_SIZE := Vector2(536, 156)
const TITLE_FONT_SIZE := 28
const BUTTON_FONT_SIZE := 26
const HINT_FONT_SIZE := 22
const CLIPBOARD_CHARS := 4000
const COL_TITLE := Color(0.910, 0.706, 0.333, 0.85)
const COL_TEXT := Color(0.749, 0.682, 0.553)
const HINT_TEXT := "遇到异常时点这里，把日志发出来。"


static func build(parent: Control, origin: Vector2 = Vector2.ZERO) -> Control:
	var block := Control.new()
	block.name = "DiagnosticsSettings"
	block.position = origin
	block.custom_minimum_size = BLOCK_SIZE
	block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(block)

	var title := _label("诊断", TITLE_FONT_SIZE, COL_TITLE)
	title.position = Vector2(0, 0)
	title.size = Vector2(200, 40)
	block.add_child(title)

	var hint := _label(HINT_TEXT, HINT_FONT_SIZE, COL_TEXT)
	hint.position = Vector2(300, 46)
	hint.size = Vector2(236, 96)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	block.add_child(hint)

	var button := Button.new()
	button.text = "导出诊断日志"
	button.position = Vector2(0, 44)
	button.size = Vector2(280, 72)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", BUTTON_FONT_SIZE)
	button.add_theme_color_override("font_color", Color(0.949, 0.890, 0.776))
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.914, 0.722))
	CommonUiSkin.style_button(button, Vector4.ZERO)
	button.pressed.connect(_on_export_pressed.bind(hint))
	block.add_child(button)
	return block


static func _on_export_pressed(hint: Label) -> void:
	var path := RUNTIME_LOG.export_bundle()
	if path.is_empty():
		hint.text = "导出失败，日志目录不可写。"
		return
	var delivered := _deliver(path)
	hint.text = str(delivered.get("text", path))
	RUNTIME_LOG.event("log.export", {"mode": str(delivered.get("mode", "")),
		"path": str(delivered.get("path", path))})


static func _deliver(path: String) -> Dictionary:
	if OS.get_name() in ["Android", "iOS"]:
		var public_dir := _copy_to_public(path)
		if not public_dir.is_empty():
			OS.shell_open(public_dir)
			return {"mode": "public", "path": public_dir, "text": "已导出到：" + public_dir}
		DisplayServer.clipboard_set(_clip_text())
		return {"mode": "clipboard", "path": path, "text": "已复制最近事件到剪贴板，粘贴到反馈群即可。"}
	OS.shell_open(path)
	return {"mode": "folder", "path": path, "text": path}


## 复制到系统下载目录。导出的目录只有平铺文件，逐个复制即可。
static func _copy_to_public(path: String) -> String:
	var base := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if base.is_empty():
		return ""
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "-")
	var target := base.path_join("spotlight-logs-" + stamp)
	if DirAccess.make_dir_recursive_absolute(target) != OK:
		return ""
	var source := DirAccess.open(path)
	if source == null:
		return ""
	for name in source.get_files():
		if DirAccess.copy_absolute(path.path_join(name), target.path_join(name)) != OK:
			return ""
	return target


static func _clip_text() -> String:
	var text := RUNTIME_LOG.summary()
	return text.substr(maxi(0, text.length() - CLIPBOARD_CHARS))


static func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
