## 卡牌底图成套数据
##
## UI-001 交付了 8 张底图：两种卡头（日 / 月）× 四种色调（灰 / 红 / 蓝 / 黄）。两个栏位的
## 枚举定义在 CardData 上（稀有度与颜色），本类只负责按这两栏取图，不另定义一套枚举。
##
## 对应关系：稀有度「日」配日头、「月」配月头，选项名与底图一一对应。
##
## 配置见 data/config/card_face_set.tres。
##
## 是 @tool：卡面模板在编辑器里也运行，会调 texture_for 取底图。不声明 @tool 时编辑器
## 里的资源是占位实例，调它的方法会报 "Attempt to call a method on a placeholder
## instance"。

@tool
class_name CardFaceSet
extends Resource

## 每个稀有度下的颜色个数。底图列表的下标按稀有度 * TINT_COUNT + 颜色排。
const TINT_COUNT := 4

## 齐全时的张数。
const FACE_COUNT := 8

## 8 张底图，下标与交付文件名一一对应：
##   0 日灰  1 日红  2 日蓝  3 日黄     ← 稀有度 = 日
##   4 月灰  5 月红  6 月蓝  7 月黄     ← 稀有度 = 月
@export var 底图列表: Array[Texture2D] = []


## 按两个栏位取底图。缺图或下标越界时报错并返回 null，由调用方决定保留原贴图。
func texture_for(稀有度: CardData.Rarity, 颜色: CardData.FaceTint) -> Texture2D:
	var index: int = int(稀有度) * TINT_COUNT + int(颜色)
	if index < 0 or index >= 底图列表.size():
		push_error("CardFaceSet：第 %d 张底图缺失（稀有度=%d 颜色=%d）" % [index, 稀有度, 颜色])
		return null
	var texture: Texture2D = 底图列表[index]
	if texture == null:
		push_error("CardFaceSet：第 %d 张底图是空的（稀有度=%d 颜色=%d）" % [index, 稀有度, 颜色])
	return texture


## 8 张是否齐全。
func is_complete() -> bool:
	if 底图列表.size() != FACE_COUNT:
		return false
	for texture in 底图列表:
		if texture == null:
			return false
	return true
