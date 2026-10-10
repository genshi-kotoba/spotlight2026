## 测试用 buff：只覆写 tick_duration
##
## 用来验「四个钩子各自独立」——改了时长规则不影响层数与强度换算。
## 是自测夹具，不是产品效果，所以放 tests/ 下。

extends BuffEffect


func tick_duration(buff: Dictionary) -> void:
	var duration := duration_of(buff)
	if duration > 0:
		buff["duration"] = maxi(0, duration - 2)
