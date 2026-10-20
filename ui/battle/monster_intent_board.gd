class_name MonsterIntentBoard
extends Node
## 将同一份表现快照投影为每只怪物的意图数据；不创建独立面板。

const PREVIEW_PATH := "res://systems/monsters/monster_intent_preview.gd"
const ICON_REGION := Rect2(104, 125, 847, 863)
static var _icons: Dictionary = {}
var _signature := ""
var records: Array[Dictionary] = []

func show_snapshot(player: Dictionary, enemies: Array, buffs: Dictionary, turn: int) -> void:
	var preview_script: GDScript = load(PREVIEW_PATH) as GDScript
	var next: Array[Dictionary] = []
	for enemy: Dictionary in enemies:
		if int(enemy.get("health", 0)) <= 0: continue
		var record: Dictionary = preview_script.describe(enemy, player, enemies, buffs)
		if int(record.get("turn", -1)) != turn:
			# 回合开始表现可能先于新计划就绪；不能把上一轮动作标成这一轮。
			record["ready"] = false
			record["action_count"] = 0
			record["actions"] = []
			record["triggers"] = []
			record["summary"] = "意图准备中"
		record["enemy_id"] = str(enemy.get("enemy_id", ""))
		record["name"] = str(enemy.get("name", "怪物"))
		next.append(record)
	var signature := JSON.stringify([turn, next])
	if signature == _signature: return
	_signature = signature
	records = next

func preview_for(enemy_id: String) -> Dictionary:
	for record: Dictionary in records:
		if str(record.enemy_id) == enemy_id: return record
	return {}

static func icon_for(kind: String) -> Texture2D:
	if not _icons.has(kind):
		if kind == "buff":
			_icons[kind] = load("res://assets/ui/UI-016/Buff.svg")
		else:
			var atlas := AtlasTexture.new()
			atlas.atlas = TextCatalogService.art_texture("res://assets/ui/UI-016/%s.png" % {"attack": "攻击", "block": "防御"}.get(kind, "特殊"))
			atlas.region = ICON_REGION
			_icons[kind] = atlas
	return _icons[kind]
