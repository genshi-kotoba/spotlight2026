class_name FeelCurve
extends RefCounted
## 全工程共用的缓动与节拍常量。出处 docs/ops/2026-10-19-非战斗手感触点清单.html 第 07 节。
## 只放数值与枚举，不放逻辑；改这里等于同时改所有界面的手感。

# 时长，单位秒
const HOVER_IN := 0.07
const HOVER_OUT := 0.09
const PRESS_BACK := 0.12
const POPUP_IN := 0.18
const PUSH_IN := 0.22
const VALUE_ROLL := 0.28
const CELL_LAND := 0.16

# 一次发生多件事时的节拍间隔，单位秒
const BEAT_VALUE := 0.05
const BEAT_GRAPHIC := 0.16
const BEAT_READ := 0.35

# 曲线
const CURVE_HOVER := Tween.TRANS_SINE
const CURVE_BACK := Tween.TRANS_BACK
const CURVE_CUBIC := Tween.TRANS_CUBIC
const EASE_OUT := Tween.EASE_OUT

# 悬停与按下的形变幅度，相对控件自身尺寸的缩放倍数
const SCALE_HOVER := 1.03
const SCALE_PRESS := 0.97
