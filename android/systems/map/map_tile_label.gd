class_name MapTileLabel
extends Node3D

## 贴在格子顶面上的数字池。
##
## 路径预览用它在每一格标出还剩几格，让玩家一眼看出这段路有多长。
## 数字从池子里复用，不做频繁的节点增删。

## 数字相对格面的抬升。比路径高亮更高，免得被边框压住。
const LIFT := 0.08

## 数字往白色方向提亮的比例。路径高亮是绿底绿字，不提亮会糊在一起。
const BRIGHTEN := 0.6

## 字号与像素尺寸相乘才是世界高度。64 乘 0.012 约 0.77，在 2.0 宽的六边形上够醒目。
@export var font_size := 64
@export var pixel_size := 0.012

## 平躺之后绕竖轴转多少度。默认与相机的初始水平朝向一致，开局看着是正的。
@export var flat_yaw_degrees := 45.0

var _pool: Array[Label3D] = []
var _active := 0


## 一次性铺开一批数字。positions 与 texts 一一对应。
func show_all(positions: Array[Vector3], texts: PackedStringArray, color: Color) -> void:
	clear()
	for i in mini(positions.size(), texts.size()):
		var node := _obtain(_active)
		_active += 1
		node.text = texts[i]
		node.modulate = color.lerp(Color.WHITE, BRIGHTEN)
		node.global_position = positions[i] + Vector3(0.0, LIFT, 0.0)
		node.visible = true


func clear() -> void:
	for i in _active:
		_pool[i].visible = false
	_active = 0


func _obtain(index: int) -> Label3D:
	while _pool.size() <= index:
		var node := Label3D.new()
		node.name = "Number%d" % _pool.size()
		node.font_size = font_size
		node.pixel_size = pixel_size
		node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

		# 躺平贴地，不跟着镜头转。
		# 用 billboard 的话整块文字面板会随镜头上下翻，视角一低就切进地块里，
		# 看着像数字被埋了。躺平之后无论怎么转视角姿态都不变。
		# Label3D 默认朝 +Z 立着，绕 X 转 -90 度就是面朝上。
		node.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		node.rotation_degrees = Vector3(-90.0, flat_yaw_degrees, 0.0)

		# 描边只压一圈以免字糊在浅色地形里。描太粗会把数字本身吃掉
		node.outline_size = 6
		node.outline_modulate = Color(0.10, 0.10, 0.12)
		node.no_depth_test = false
		add_child(node)
		_pool.append(node)
	return _pool[index]
