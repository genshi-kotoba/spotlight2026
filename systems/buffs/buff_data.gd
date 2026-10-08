## buff 数据
##
## 一种 buff 的静态配置，存成 .tres。运行期的「某个目标身上的一条 buff」是
## PRG-004 手里的字典 {"buff_id": "poison", "layers": 2, "duration": 0}，
## 不是本类。
##
## PRG-008 的三要素分布在两处：
##   层数        运行期在 buff 字典的 "layers" 里；每回合怎么变由挂的效果决定
##   持续回合数   初值在下面的持续回合，运行期在 buff 字典的 "duration" 里
##   效果        挂在下面的效果列表里，一条效果一个文件
##
## 持续回合的语义（0 表示不限回合，正数为剩余回合数）见 buff_effect.gd 的说明。
## 状态机要求它非负，所以这里不能填负数。

class_name BuffData
extends Resource

## 稳定标识。同一个目标身上同 id 的 buff 只有一条，加第二次是改层数不是加一条。
@export var buff标识: StringName = &""

@export var 显示名: String = ""

@export_multiline var 描述: String = ""

## 初始持续回合数。0 表示不限回合，正数为剩余回合数。
@export_range(0, 999) var 持续回合: int = 0

## 初始层数。施加时写进 buff 字典。
@export_range(0, 999) var 初始层数: int = 1

## 效果列表。
##
## 元素类型是 GameEffect，所以 buff 既能挂卡牌效果（每回合抽一张牌），也能挂
## buff 效果（每回合再叠一层毒）。PRG-008 原文：buff 效果包括所有的卡牌效果。
@export var 效果: Array[GameEffect] = []
