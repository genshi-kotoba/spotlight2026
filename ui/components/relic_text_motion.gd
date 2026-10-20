class_name RelicTextMotion
extends RichTextEffect
## 富文本适配层：沿用怪物文字的逐字离散曲线，只降低说明正文的幅度。
const MOTION := preload("res://ui/components/text_glyph_motion.gd")
const PERTURB_INTERVAL := 0.1
const CURVE_SCALE := 0.75
const ANGLE_MULTIPLIER := 0.35
var bbcode := "relic_motion"


func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var tick := maxi(0, int(floor(char_fx.elapsed_time / PERTURB_INTERVAL + 0.000001)))
	var pose := MOTION.sample(int(char_fx.env.get("seed", 0)), char_fx.relative_index,
		tick, CURVE_SCALE, ANGLE_MULTIPLIER)
	char_fx.offset += Vector2(pose.offset)
	char_fx.transform = char_fx.transform.rotated_local(float(pose.angle))
	# 不修改 visible、color 或 scale，正文完整显示，BBCode 的分类色仍然有效。
	return true
