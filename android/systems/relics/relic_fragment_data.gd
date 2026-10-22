class_name RelicFragmentData
extends Resource

enum Kind { TRIGGER, EFFECT, PRESENCE, NEGATIVE }
enum Reach { NONE, FOUR, EIGHT, ROW, COLUMN, VERTICAL, ALL }

@export var fragment_id := ""
@export var display_name := ""
@export_multiline var description := ""
@export var kind: Kind = Kind.EFFECT
@export var event_id := ""
@export var reach: Reach = Reach.NONE
@export var action_id := ""
@export var amount := 0
@export var negative_action := ""
@export var base_fragment_id := ""
## Generated fragments retain their rolls in their versioned ID, including across saves.
@export var name_fragment_id := ""
@export var color_index := -1
@export var auxiliary_id := ""
@export var primary_description := ""
@export var extra_description := ""
@export var presence_action := ""
@export var presence_event := ""
@export var presence_amount := 0

const PALETTE := ["e9b85e", "83c792", "79bce4", "bca1e6", "e5a7ba", "e49361", "78cfc4", "d4cfaa"]
const TRIGGER_CONDITIONS := {
	"card_gained": "获得卡牌", "pointer_four": "指针每挪动4格",
	"turn_end": "回合结束", "card_discarded": "弃牌", "blocked": "格挡成功",
	"player_damaged": "扣血", "pointer_moved": "指针被主动移动",
	"dot_damage": "dot造成伤害", "enemy_died": "敌方死亡",
	"attack_five": "本回合攻击每累计五次", "enemy_damaged": "对敌人造成伤害",
}
const REACH_DESCRIPTIONS := {
	Reach.FOUR: "周围四格", Reach.EIGHT: "周围八格", Reach.ROW: "一行",
	Reach.COLUMN: "一列", Reach.VERTICAL: "上下两格", Reach.ALL: "整个典籍",
}
const TRIGGER_COLOR := "#83c792"
const EFFECT_COLOR := "#ffffff"
const PRESENCE_COLOR := "#83baff"
const NEGATIVE_COLOR := "#ff7878"


func kind_name() -> String:
	return ["触发", "效果", "存在", "负面"][kind]


func tint() -> Color:
	if color_index >= 0 and color_index < PALETTE.size():
		return Color(PALETTE[color_index])
	return [Color("d1a55b"), Color("71b8cb"), Color("b69ddd"), Color("ba5966")][kind]


func rich_description() -> String:
	var main := primary_description if not primary_description.is_empty() else description
	var lines := PackedStringArray()
	# 装载能力先读，负面能力最后读；不依赖原始 description 的拼接顺序。
	if kind == Kind.PRESENCE:
		lines.append(_colored(PRESENCE_COLOR, _presence_sentence(main)))
	elif not presence_action.is_empty() and not extra_description.is_empty():
		lines.append(_colored(PRESENCE_COLOR, _presence_sentence(extra_description)))
	match kind:
		Kind.TRIGGER:
			var condition: String = TRIGGER_CONDITIONS.get(event_id, _trigger_condition(main))
			var area: String = REACH_DESCRIPTIONS.get(reach, "自身所在格")
			lines.append(_colored(TRIGGER_COLOR, "当%s时，触发%s范围。" % [condition, area]))
		Kind.EFFECT:
			var effect := _sentence_body(main)
			for prefix: String in ["被触发时，", "被触发时", "触发时，", "触发时"]:
				if effect.begins_with(prefix):
					effect = effect.trim_prefix(prefix)
					break
			lines.append(_colored(EFFECT_COLOR, "被触发时，%s。" % effect))
		Kind.NEGATIVE:
			lines.append(_negative_text("负面：%s。" % _sentence_body(main.trim_prefix("负面："))))
	if not extra_description.is_empty():
		if not negative_action.is_empty():
			lines.append(_negative_text("负面：%s。" % _sentence_body(extra_description.trim_prefix("负面："))))
		elif presence_action.is_empty() and kind != Kind.PRESENCE:
			# 兼容尚未填 presence_action 的旧展示数据；仍按装载说明置顶。
			lines.insert(0, _colored(PRESENCE_COLOR, _presence_sentence(extra_description)))
	# 仅负面词条使用怪物同源抖动，其余词条和标题保持静止。
	return "\n".join(lines)


func _negative_text(value: String) -> String:
	return "[relic_motion seed=%d]%s[/relic_motion]" % [fragment_id.hash(), _colored(NEGATIVE_COLOR, value)]


func rich_text(title_size: int = 30) -> String:
	return "[b][font_size=%d][color=#%s]%s[/color][/font_size][/b]\n%s" % [maxi(title_size, 1), tint().to_html(false), _escape(display_name), rich_description()]


static func _colored(color: String, value: String) -> String:
	return "[color=%s]%s[/color]" % [color, _escape(value)]


static func _sentence_body(value: String) -> String:
	return value.strip_edges().trim_suffix("。").trim_suffix(".")


static func _presence_sentence(value: String) -> String:
	var body := _sentence_body(value).trim_prefix("在场：")
	body = body.trim_prefix("当装载该残片时，")
	return "当装载该残片时，%s。" % body


static func _trigger_condition(value: String) -> String:
	# 仅为未知旧事件提供文案回退；正式条件始终由 event_id 确定。
	var condition := value.get_slice("触发", 0).get_slice("，", 0).strip_edges()
	return condition.trim_prefix("当").trim_suffix("时")


static func _escape(value: String) -> String:
	return value.replace("[", "[lb]")
