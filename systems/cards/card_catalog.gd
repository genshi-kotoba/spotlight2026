@tool
## 卡牌清单与校验工具
##
## 用法：在 Godot 里打开本文件，按 Ctrl+Shift+X。也可以在 FileSystem 面板里右键本
## 脚本选 Run。结果打印在编辑器的输出面板。
##
## 做检查器做不了的事：
##   - 列出 data/cards/ 下的全部卡牌与字段汇总
##   - 校验卡牌标识是否唯一、是否为空
##   - 校验效果里有没有空元素（断链）与重复引用
##   - 报每个效果被多少张卡引用，用于判断某个效果能不能删
##
## **不得引用 BattleStateMachine。** 本工程把警告当错误，而 PRG-004 目前有若干处
## 类型推断告警，一旦引用，本脚本会跟着编译失败，工具就跑不起来。
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
		_check_fields(data, path)
		_collect_effect_usage(data, path)

	## 字段层面的问题：标识与名字是否为空、有没有效果。
	func _check_fields(data: CardData, path: String) -> void:
		var 卡牌标识 := String(data.卡牌标识)
		if 卡牌标识.strip_edges().is_empty():
			problems.append("%s：卡牌标识为空" % path)
		else:
			if not ids.has(卡牌标识):
				ids[卡牌标识] = []
			ids[卡牌标识].append(path)

		if String(data.卡牌名).strip_edges().is_empty():
			problems.append("%s：卡牌名为空（编辑器里显示不出来）" % path)

		if data.效果.is_empty():
			problems.append("%s：效果为空，这张卡打出去什么都不做" % path)

	## 效果层面的问题：断链、同一张卡里重复挂同一个资源实例，同时记下引用次数。
	func _collect_effect_usage(data: CardData, path: String) -> void:
		for i in data.效果.size():
			var effect: GameEffect = data.效果[i]
			if effect == null:
				problems.append("%s：效果[%d] 是空元素（断链）" % [path, i])
				continue
			var effect_name := _effect_name(effect)
			if not effect_usage.has(effect_name):
				effect_usage[effect_name] = []
			effect_usage[effect_name].append("%s[%d]" % [path, i])

		# 同一张卡里重复挂同一个效果资源实例，通常是复制粘贴的疏忽
		for i in data.效果.size():
			for j in range(i + 1, data.效果.size()):
				if data.效果[i] == data.效果[j] and data.效果[i] != null:
					problems.append("%s：效果[%d] 与效果[%d] 是同一个资源实例"
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
		for 卡牌标识: String in ids:
			var paths: Array = ids[卡牌标识]
			if paths.size() > 1:
				result.append(卡牌标识)
		result.sort()
		return result

	func print_to_console() -> void:
		print("=== 卡牌清单与校验 ===")
		print("  卡牌文件 %d 个，不同卡牌标识 %d 个" % [card_files.size(), ids.size()])

		print("--- 每张卡的字段 ---")
		for data: CardData in cards:
			var effect_names: Array[String] = []
			for effect: GameEffect in data.效果:
				if effect == null:
					effect_names.append("<空>")
				else:
					effect_names.append(_effect_name(effect))
			print("  %s | %s | 卡面=%s%s | 效果=[%s]" % [
				data.卡牌标识,
				data.卡牌名,
				_member_name(CardData.稀有度档, data.稀有度),
				_member_name(CardData.颜色档, data.颜色),
				", ".join(effect_names),
			])

		print("--- 同名卡（同一个卡牌标识出现在多个文件里）---")
		var duplicates := duplicate_ids()
		if duplicates.is_empty():
			print("  无。每个卡牌标识只对应一个文件")
		else:
			for 卡牌标识 in duplicates:
				var paths: Array = ids[卡牌标识]
				print("  %s x%d：%s" % [卡牌标识, paths.size(), ", ".join(paths)])
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

	## 取枚举成员名，供报表显示。GDScript 的枚举底层是有序字典：keys() 的顺序就是成员的
	## 定义顺序，与它的整数值一一对应，所以这里不逐个 match —— 加了颜色或稀有度也不用改，
	## 也就不会出现「新成员印成未知」这种报表说谎的情况。
	func _member_name(enum_dict: Dictionary, value: int) -> String:
		var keys: Array = enum_dict.keys()
		if value < 0 or value >= keys.size():
			return "未知(%d)" % value
		return String(keys[value])
