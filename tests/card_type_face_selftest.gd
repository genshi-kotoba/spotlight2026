extends Node

const CARD_SCENE := preload("res://ui/components/card/card_view.tscn")
var failures := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := FormalCardCatalog.load_definitions()
	_check("正式卡牌加载成功", result.error == OK)
	var samples := {"1": CardData.FaceTint.RED, "11": CardData.FaceTint.BLUE,
		"40": CardData.FaceTint.YELLOW, "6": CardData.FaceTint.GRAY, "71": CardData.FaceTint.GRAY}
	for id: String in samples:
		var data: CardData = result.cards[id]
		_check("正式卡牌%s分类颜色" % id, data.face_tint == samples[id])
		var view: CardView = CARD_SCENE.instantiate()
		view.set_card(data)
		add_child(view)
		_check("正式卡牌%s实际底图" % id, _texture_path(view) == _expected_path(data.rarity, samples[id]))
		view.free()
	var parent := Control.new()
	add_child(parent)
	var types := {"伤害": CardData.FaceTint.RED, "buff": CardData.FaceTint.BLUE,
		"移位": CardData.FaceTint.YELLOW, "特殊": CardData.FaceTint.GRAY, "暂无": CardData.FaceTint.GRAY}
	for type_name: String in types:
		for rarity: String in ["普通", "稀有"]:
			var holder := CatalogUi.preview(parent, {"type": type_name, "rarity": rarity}, "cards", 0.25)
			var view: CardView = holder.get_child(0)
			var rarity_value := CardData.Rarity.RARE if rarity == "稀有" else CardData.Rarity.COMMON
			_check("图鉴%s%s实际底图" % [type_name, rarity], _texture_path(view) == _expected_path(rarity_value, types[type_name]))
			holder.free()
	parent.free()
	print("分类底图自测：全部通过" if failures == 0 else "分类底图自测：%d 项失败" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _texture_path(view: CardView) -> String:
	var texture: Texture2D = view.get_node("%卡框").texture
	return texture.resource_path if texture != null else ""


func _expected_path(rarity: int, tint: int) -> String:
	return "res://assets/ui/UI-001/%s%s.png" % ["月" if rarity == CardData.Rarity.RARE else "日", ["灰", "红", "蓝", "黄"][tint]]


func _check(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)
	if not passed:
		failures += 1
