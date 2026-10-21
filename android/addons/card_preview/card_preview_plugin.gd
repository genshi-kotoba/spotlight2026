## 卡牌预览插件的入口
##
## 挂三样东西：
##   1. 检查器插件 —— 打开 CardData 时，属性列表顶部出现卡面
##   2. 右侧的「卡牌」面板 —— 只显示当前选中的那张卡，见 card_dock.gd
##   3. 卡牌大图窗口 —— 菜单「项目 → 工具 → 卡牌大图」，见 card_window.gd
##
## 后两个共用同一份展示体 card_stage.gd，所以「只显示一张卡、跟着选中走、实时刷新」
## 只有一处实现。
##
## 本文件是编辑器插件，只在编辑器里运行，游戏运行期不加载。文件必须是无 BOM 的 UTF-8：
## 带 BOM 时 Godot 的 ConfigFile 解析不出 [plugin] 段，插件被静默跳过，且没有任何报错
## （PowerShell 5.1 的 -Encoding utf8 写出的文件就带 BOM）。

@tool
extends EditorPlugin

const INSPECTOR_PLUGIN_SCRIPT := preload("res://addons/card_preview/card_data_inspector_plugin.gd")
const DOCK_SCRIPT := preload("res://addons/card_preview/card_dock.gd")
const WINDOW_SCRIPT := preload("res://addons/card_preview/card_window.gd")

const WINDOW_MENU_ITEM := "卡牌大图"

var _inspector_plugin: EditorInspectorPlugin
var _dock: EditorDock
var _window: Window


func _enter_tree() -> void:
	_inspector_plugin = INSPECTOR_PLUGIN_SCRIPT.new()
	add_inspector_plugin(_inspector_plugin)

	var editor := get_editor_interface()

	# EditorDock 只能在编辑器里实例化；万一不在编辑器环境，new() 会返回 null。
	_dock = DOCK_SCRIPT.new()
	if _dock == null:
		push_warning("卡牌预览：编辑器面板建不起来，跳过")
	else:
		_dock.setup(editor)
		add_dock(_dock)

	_window = WINDOW_SCRIPT.new()
	# 先入树再 setup：Window 在入树时会重置自己的尺寸，入树前设的 size 不作数。
	add_child(_window)
	_window.setup(editor)
	add_tool_menu_item(WINDOW_MENU_ITEM, _open_window)

	_connect_selection_signals(editor)
	_refresh_all()


func _exit_tree() -> void:
	remove_tool_menu_item(WINDOW_MENU_ITEM)
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _dock != null:
		remove_dock(_dock)
		_dock.queue_free()
		_dock = null
	if _window != null:
		_window.queue_free()
		_window = null


func _open_window() -> void:
	if _window == null:
		return
	_window.popup_centered(_window.size)
	_window.refresh_now()


## 三处「选中变了」都直接叫展示体重判一次，不必等兜底轮询。
## 连接会在对象释放时自动断开，所以 _exit_tree 里不做手工 disconnect。
func _connect_selection_signals(editor: Object) -> void:
	var refresh := Callable(self, "_refresh_all")

	var file_system: Object = editor.get_file_system_dock()
	if file_system != null and file_system.has_signal("selection_changed"):
		file_system.connect("selection_changed", refresh)

	var inspector: Object = editor.get_inspector()
	if inspector != null and inspector.has_signal("edited_object_changed"):
		inspector.connect("edited_object_changed", refresh)

	var selection: Object = editor.get_selection()
	if selection != null and selection.has_signal("selection_changed"):
		selection.connect("selection_changed", refresh)


func _refresh_all() -> void:
	if _dock != null:
		_dock.refresh_now()
	if _window != null:
		_window.refresh_now()
