@tool
## 卡牌清单与校验工具
##
## 用法：在 Godot 里打开本文件，按 Ctrl+Shift+X。也可以在 FileSystem 面板里右键本
## 脚本选 Run。结果打印在编辑器的输出面板。
##
## 做检查器做不了的事：
##   - 列出 data/cards/ 下的全部卡牌与字段汇总
##   - 校验 card_id 是否唯一、是否为空
##   - 校验 effects 里有没有空元素（断链）与重复引用
##   - 报每个效果被多少张卡引用，用于判断某个效果能不能删
##
## **不得引用 BattleStateMachine。** 本工程把警告当错误，而 PRG-004 目前有若干处
## 类型推断告警（见 docs/ops/Godot警告等级实测.md），一旦引用，本脚本会跟着编译
## 失败，工具就跑不起来。这也是提示词文档 §5 那条硬约束的由来。
##
## "For those who come after."
##
## 这个工具是给后来人用的：卡牌会越加越多，靠眼睛数不过来。

extends EditorScript

const CARDS_DIR := "res://data/cards"


func _run() -> void:
	var report := CardCatalogReport.new()
	report.scan(CARDS_DIR)
	report.print_to_console()


## 扫描与统计。单独成类，方便将来接进别的界面而不用改扫描逻辑。
class CardCatalogReport:
	var card_files: Array[String] = []
	var cards: Array[CardData] = []
	var ids: Dictionary = {}
	var problems: Array[String] = []
	var effect_usage: Dictionary = {}

	func scan(directory: String) -> void:
		card_files.clear()
		cards.clear()
		ids.clear()
		problems.clear()
		effect_usage.clear()

		var dir := DirAccess.open(directory)
		if dir == null:
			problems.append("打不开目录 %s" % directory)
			return

		for file_name in dir.get_files():
			if not file_name.ends_with(".tres"):
				continue
			var path := "%s/%s" % [directory, file_name]
			card_files.append(path)
			_load_one(path)

		card_files.sort()

	func _load_one(path: String) -> void:
		var resource: Resource = ResourceLoader.load(path)
		if resource == null:
			problems.append("%s：载入失败" % path)
			return
		if not (resource is CardData):
			problems.append("%s：不是 CardData（实际 %s）" % [path, resource.get_class()])
			return

		var data: CardData = resource
		cards.append(data)

		var card_id := String(data.card_id)
		if card_id.strip_edges().is_empty():
			problems.append("%s：card_id 为空" % path)
		else:
			if not ids.has(card_id):
				ids[card_id] = []
			ids[card_id].append(path)

		if String(data.card_name).strip_edges().is_empty():
			problems.append("%s：card_name 为空（编辑器里显示不出来）" % path)

		if data.effects.is_empty():
			problems.append("%s：effects 为空，这张卡打出去什么都不做" % path)

		for i in data.effects.size():
			var effect: GameEffect = data.effects[i]
			if effect == null:
				problems.append("%s：effects[%d] 是空元素（断链）" % [path, i])
				continue
			var effect_name := _effect_name(effect)
			if not effect_usage.has(effect_name):
				effect_usage[effect_name] = []
			effect_usage[effect_name].append("%s[%d]" % [path, i])

		# 同一张卡里重复挂同一个效果资源实例，通常是复制粘贴的疏忽
		for i in data.effects.size():
			for j in range(i + 1, data.effects.size()):
				if data.effects[i] == data.effects[j] and data.effects[i] != null:
					problems.append("%s：effects[%d] 与 effects[%d] 是同一个资源实例"
						% [path, i, j])

	func _effect_name(effect: GameEffect) -> String:
		var script: Script = effect.get_script()
		if script == null:
			return "<无脚本>"
		var global_name := script.get_global_name()
		if global_name != &"":
			return String(global_name)
		return script.resource_path

	func duplicate_ids() -> Array[String]:
		var result: Array[String] = []
		for card_id: String in ids:
			var paths: Array = ids[card_id]
			if paths.size() > 1:
				result.append(card_id)
		result.sort()
		return result

	func print_to_console() -> void:
		print("=== 卡牌清单与校验 ===")
		print("  卡牌文件 %d 个，不同 card_id %d 个" % [card_files.size(), ids.size()])

		print("--- 每张卡的字段 ---")
		for data: CardData in cards:
			var effect_names: Array[String] = []
			for effect: GameEffect in data.effects:
				if effect == null:
					effect_names.append("<空>")
				else:
					effect_names.append(_effect_name(effect))
			print("  %s | %s | 稀有度=%s | 类型=%s | 卡面色调=%s | 效果=[%s]" % [
				data.card_id,
				data.card_name,
				_rarity_name(data.rarity),
				_kind_name(data.kind),
				_face_tint_name(data.face_tint),
				", ".join(effect_names),
			])

		print("--- 同名卡（同一个 card_id 出现在多个文件里）---")
		var duplicates := duplicate_ids()
		if duplicates.is_empty():
			print("  无。每个 card_id 只对应一个文件")
		else:
			for card_id in duplicates:
				var paths: Array = ids[card_id]
				print("  %s x%d：%s" % [card_id, paths.size(), ", ".join(paths)])
			print("  说明：原型卡是刻意做两份同名的（验实例区分）。")
			print("  正式卡牌数据里出现同名，说明有重复登记，要清掉。")

		print("--- 效果被引用次数 ---")
		var effect_names_all: Array = effect_usage.keys()
		effect_names_all.sort()
		if effect_names_all.is_empty():
			print("  没有任何效果被引用")
		else:
			for effect_name: String in effect_names_all:
				var refs: Array = effect_usage[effect_name]
				print("  %s：被引用 %d 次" % [effect_name, refs.size()])

		print("--- 问题 ---")
		if problems.is_empty():
			print("  未发现问题")
		else:
			for problem: String in problems:
				print("  [!] %s" % problem)
			print("  合计 %d 条" % problems.size())

	func _rarity_name(rarity: CardData.Rarity) -> String:
		match rarity:
			CardData.Rarity.COMMON:
				return "普通"
			CardData.Rarity.RARE:
				return "稀有"
		return "未知"

	func _kind_name(kind: CardData.Kind) -> String:
		match kind:
			CardData.Kind.DAMAGE:
				return "伤害"
			CardData.Kind.BUFF:
				return "buff"
			CardData.Kind.SHIFT:
				return "移位"
			CardData.Kind.SPECIAL:
				return "特殊"
		return "未知"

	func _face_tint_name(tint: CardData.FaceTint) -> String:
		match tint:
			CardData.FaceTint.GRAY:
				return "灰"
			CardData.FaceTint.RED:
				return "红"
			CardData.FaceTint.BLUE:
				return "蓝"
			CardData.FaceTint.YELLOW:
				return "黄"
		return "未知"
