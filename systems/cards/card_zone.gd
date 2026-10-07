## 区域与作用域枚举
##
## 一张牌在不同阶段待在哪个区，以及被移除时的作用域。
## 纯常量，无逻辑，无节点依赖。

class_name CardZone
extends RefCounted

## 牌可能待的五个区。抽牌堆与弃牌堆在结算中互相流转，
## 手牌是玩家的选择对象，出牌区是回合中排列待结算的牌。
enum Zone {
	DRAW_PILE,
	HAND,
	PLAY_AREA,
	DISCARD,
	REMOVED,
}

## 「使用后从战斗中移除」与「使用后从本局移除」的差别。
## BATTLE 只在这一场战斗内消失，战后回到牌组；
## RUN 在本局余下的战斗中都不再出现。
enum RemoveScope {
	BATTLE,
	RUN,
}

## 指针移动方向。用枚举而不是正负号，编辑器里是下拉加数字，读到不用猜。
enum 方向 {
	左,
	右,
}
