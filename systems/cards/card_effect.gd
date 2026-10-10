## 卡牌效果基类
##
## 卡牌效果是「一次性执行」：打出时执行一次，执行完就结束。它不持层数，也不参与
## 每回合结算——那是 BuffEffect 的事。
##
## 继承 GameEffect 而不是直接继承 Resource，是为了让卡牌能直接挂 buff 效果、buff
## 也能直接挂卡牌效果。理由见 game_effect.gd 的注释。
##
## 参数就是编辑器里那些框，所以每个效果类用 @export 暴露参数，不放构造函数。
## 数值一律走 @export，不得写死在 execute 里——以后的卡牌升级要靠改数值而不改代码。

class_name CardEffect
extends GameEffect


## 执行本效果，子类覆写。
##
## card 是触发本效果的那张牌的字典，形如
## {"instance_id": "card-1", "card_id": "bonk"}。效果需要指认「自己」时
## （例如从战斗中移除本牌）用它。
func execute(_ctx: EffectContext, _card: Dictionary) -> void:
	push_error("CardEffect.execute 未被子类实现：%s" % _script_path())
