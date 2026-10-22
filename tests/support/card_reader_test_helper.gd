extends RefCounted
## 通过真实读取层与显式操作按钮驱动奖励/商店 UI，避免测试替代用户确认。
static func active_reader(owner: Node) -> CanvasLayer:
	return _find_reader(owner, owner)

static func _find_reader(node: Node, owner: Node) -> CanvasLayer:
	if node is ReadingDetailOverlay and node.visible and not node.is_queued_for_deletion() and ReadingDetailOverlay.is_open_for(owner):
		return node
	for child: Node in node.get_children():
		var found := _find_reader(child, owner)
		if found != null: return found
	return null

static func action_button(owner: Node, text: String) -> Button:
	var reader := active_reader(owner)
	if reader == null: return null
	for button: Node in reader.find_children("*", "Button", true, false):
		if button.text == text and button.is_visible_in_tree(): return button as Button
	return null
