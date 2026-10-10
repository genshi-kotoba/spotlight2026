## 卡牌数据
##
## 一张卡的静态配置，存成 .tres。运行期的「某一张具体的牌」是 PRG-004 手里的字典
## {"instance_id": "card-1", "card_id": "bonk"}，不是本类。
##
## PRG-007 的要素是「稀有度、效果」，两样都在本类上：
##   稀有度  rarity
##   效果    effects
##
## 类型 kind 按策划案 2.4 的四分类。本轮只保留字段，各类的行为差异等卡牌定稿后
## 再定义。
##
## 数值一律走 @export，不写死在代码里——以后的卡牌升级机制要靠改数值而不改代码。
## 本类不含打出费用：费用的规则策划案未定，等定了再加字段。

class_name CardData
extends Resource

## 稀有度。策划案 2.4 定两档：
##   普通  可从任何卡牌奖励获得
##   稀有  只能从商店、精英与 Boss 奖励、部分随机事件获得
##
## 获取途径属 PRG-003 的池子逻辑，本类只保存档位。
enum Rarity {
	COMMON,
	RARE,
}

## 卡牌类型。策划案 2.4：伤害、buff、移位、特殊。
enum Kind {
	DAMAGE,
	BUFF,
	SHIFT,
	SPECIAL,
}

## UI-001 卡框提供四种色调。该字段只决定表现，不替代策划案定义的卡牌类型。
enum FaceTint {
	GRAY,
	RED,
	BLUE,
	YELLOW,
}

## 稳定标识，卡牌数据之间互相引用用它。形如 &"bonk"。
@export var card_id: StringName = &""

## 展示名。
@export var card_name: String = ""

## 卡面描述文本。动态数值的拼装属 PRG-014。
@export_multiline var description: String = ""

@export var rarity: Rarity = Rarity.COMMON

@export var kind: Kind = Kind.DAMAGE

## 卡框色调；卡头形状继续由普通/稀有两档决定。
@export var face_tint: FaceTint = FaceTint.GRAY

## 效果列表，按顺序执行。
##
## 元素类型是 GameEffect 而不是 CardEffect，所以卡牌既可以直接挂纯效果（攻击、
## 抽牌），也可以直接挂 buff 效果（给目标叠 3 层中毒）。buff 就是这么来的。
@export var effects: Array[GameEffect] = []
