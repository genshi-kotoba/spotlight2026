## 测试用 buff：只覆写 get_effect_strength
##
## 用来验「四个钩子各自独立」——改了强度换算不影响层数与时长。

extends BuffEffect


## 每层算三点，与基类的「一层一点」不同。
func get_effect_strength(buff: Dictionary) -> float:
	return float(layers_of(buff) * 3)
