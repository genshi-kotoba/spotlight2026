extends RichTextEffect
## 只采样表现时间，不访问玩法随机流；从中央向两侧显字。
var bbcode := "region_reveal"
var elapsed := 0.0
var character_count := 1
var reduced_motion := false

func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	if reduced_motion:
		return true
	var distance := absf(float(char_fx.relative_index) - float(character_count - 1) * 0.5)
	# 长标题仍在相同的入场窗口内显完，不把末尾字拖到淡出阶段。
	var stagger := minf(0.10, 0.30 / maxf(1.0, float(character_count) * 0.5))
	var progress := smoothstep(0.0, 0.85, elapsed - 0.14 - distance * stagger)
	char_fx.color.a *= progress
	char_fx.offset.y += (1.0 - progress) * 7.0
	return true
