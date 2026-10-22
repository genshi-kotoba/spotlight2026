## 效果根类
##
## 卡牌效果与 buff 效果共用这个根类。它只提供两样东西：一个执行入口，一个执行完的
## 信号。之所以要有共同根类，是因为两边的效果要能互相挂载：
##
##   - 卡牌要能直接挂 buff 效果（「给目标叠 3 层中毒」），buff 就是这么来的
##   - buff 要能直接挂卡牌效果（PRG-008 原文：buff 效果包括所有的卡牌效果）
##
## 挂载靠 @export 数组，而编辑器给数组「添加元素」时列的是**声明元素类型的全部子类**。
## 所以两套效果必须有一个共同祖先，否则策划在卡牌上选不到 buff 效果。
##
## 子类分两支，各自承载自己的语义，不是为了限制能挂什么：
##   - CardEffect：一次性执行，执行完就结束
##   - BuffEffect：多出层数、持续回合数、每回合结算
##
## 依赖方向：属于 systems 层，不认识 ui，也不认识 state_machines。一切外界交互都
## 通过 execute 收到的 EffectContext 走。
##
## 这个根类存在的理由只有一个：让后来人加一条效果时只加一个文件，不必回头改这里，
## 也不必改 CardEffect 或 BuffEffect。
##
## "When one falls, we continue."

class_name GameEffect
extends Resource

## 执行完毕后释放。参数带上效果自身与触发它的上下文（对卡牌效果是那张牌的字典）。
signal executed(effect: GameEffect, context: Dictionary)


## 唯一的执行入口。调用方只认根类，不认具体效果。
##
## 子类必须覆写。基类留一个会报错的实现，是为了让漏写 execute 的子类在自测里
## 立刻炸出来，而不是静默通过。
func execute(_ctx: EffectContext, _context: Dictionary) -> void:
	push_error(
		"GameEffect.execute 未被子类实现：%s" % _script_path()
	)


func _script_path() -> String:
	# Resource.get_script() 的静态类型是 Variant，这里显式标注。
	# 本工程把警告当错误，用 := 推断会直接编译失败。
	var script: Script = get_script()
	if script == null:
		return "<无脚本>"
	return script.resource_path


func _to_string() -> String:
	return "<%s %s>" % [get_class(), _script_path()]
