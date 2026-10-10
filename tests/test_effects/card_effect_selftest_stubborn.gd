## 测试用 buff：只覆写 is_expired
##
## 用来验「四个钩子各自独立」——改了到期判定不影响别的方面。
## 本类永远不到期，模拟「层数归零也还留着」的特殊 buff。

extends BuffEffect


func is_expired(_buff: Dictionary) -> bool:
	return false
