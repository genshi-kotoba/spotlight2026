class_name SlotCard
extends Button

## 单张档案卡片：把 list_slots() 的一项画成一张卡。只有切换档案屏用它。
## 三态文案与摘要字段见 docs/prompts/PRG-016-021-开始界面与设置.md §五。

@onready var _slot_label: Label = $槽号
@onready var _state_label: Label = $状态
@onready var _summary_label: Label = $摘要
@onready var _current_label: Label = $当前标注

var slot := 0


func setup(info: Dictionary, is_current: bool) -> void:
	slot = int(info.get("slot", 0))
	_slot_label.text = "档案 %d" % slot
	_state_label.text = state_text(String(info.get("state", "empty")))
	_summary_label.text = summary_text(info)
	_current_label.visible = is_current


## 三态文案。内部状态字串保持 "empty" / "active" / "ended"，与接口对齐。
static func state_text(state: String) -> String:
	match state:
		"active":
			return "进行中"
		"ended":
			return "已结束"
		_:
			return "空"


## 卡片只写状态与数值，不写提示句。空档一个破折号。
static func summary_text(info: Dictionary) -> String:
	var state := String(info.get("state", "empty"))
	if state == "empty":
		return "—"
	var lines: Array[String] = []
	var region := String(info.get("region", ""))
	if not region.is_empty():
		lines.append("区域 %s" % region)
	if state == "ended":
		lines.append("对局 %d" % int(info.get("run_count", 0)))
	else:
		# 没有真实快照的局（占位）max_health 为 0：写进度，不编生命与金币。
		if int(info.get("max_health", 0)) > 0:
			lines.append("生命 %d" % int(info.get("health", 0)))
			lines.append("金币 %d" % int(info.get("gold", 0)))
		else:
			lines.append("进度 %d" % int(info.get("progress", 0)))
	var updated := String(info.get("updated_at", ""))
	if not updated.is_empty():
		lines.append("上次 %s" % updated)
	return "\n".join(lines)
