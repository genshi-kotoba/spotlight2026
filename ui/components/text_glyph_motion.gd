class_name TextGlyphMotion
extends RefCounted
## 怪物文字与残片说明共用的纯运动采样器，不创建或推进任何随机流。


## 按句/字/离散时间片寻址的32位混合；帧率和查询顺序不改变结果。
static func unit(seed_value: int, index: int, tick: int, channel: int) -> float:
	var value := (seed_value ^ (index * 0x9e3779b9) ^ (tick * 0x85ebca6b) ^ (channel * 0xc2b2ae35)) & 0xffffffff
	value = ((value ^ (value >> 16)) * 0x45d9f3b) & 0xffffffff
	value = ((value ^ (value >> 16)) * 0x45d9f3b) & 0xffffffff
	return float(value ^ (value >> 16)) / 4294967296.0


static func sample(seed_value: int, index: int, tick: int, curve_scale: float = 1.0,
		angle_multiplier: float = 1.0, changed: bool = false) -> Dictionary:
	return {"offset": Vector2(unit(seed_value, index, tick, 0) * 2.0 - 1.0,
		unit(seed_value, index, tick, 1) * 2.0 - 1.0) * curve_scale,
		"angle": deg_to_rad((unit(seed_value, index, tick, 2) * 10.0 - 5.0) * angle_multiplier),
		"scale": 1.0 + unit(seed_value, 0, tick, 3) * 0.2 if changed else 1.0}
