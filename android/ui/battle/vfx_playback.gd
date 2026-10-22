class_name VfxPlayback
extends Sprite2D

## 播一遍 VFX-001 的序列帧后自毁。
## 三套图是交付的 BMP 序列（720×540、纯白底），已由工具转成透明底图集：
## 每行 5 帧，帧数不等，所以行列数由调用方给。

const ATTACK_SHEET := preload("res://assets/vfx/VFX-001/attack_sheet.png")
const BLOCK_SHEET := preload("res://assets/vfx/VFX-001/block_sheet.png")
const HEAL_SHEET := preload("res://assets/vfx/VFX-001/heal_sheet.png")

enum Kind { ATTACK, BLOCK, HEAL }

const SHEETS := {
	Kind.ATTACK: {"texture": ATTACK_SHEET, "frames": 20, "rows": 4},
	Kind.BLOCK: {"texture": BLOCK_SHEET, "frames": 20, "rows": 4},
	Kind.HEAL: {"texture": HEAL_SHEET, "frames": 23, "rows": 5},
}
const COLUMNS := 5
const FPS := 26.0

var _frame_count := 20
var _time := 0.0


func play(kind: Kind, at: Vector2, view_size: Vector2) -> void:
	var sheet: Dictionary = SHEETS[kind]
	texture = sheet["texture"]
	hframes = COLUMNS
	vframes = int(sheet["rows"])
	_frame_count = int(sheet["frames"])
	position = at
	z_index = 55
	modulate = Color.WHITE
	var native := Vector2(texture.get_width() / float(COLUMNS),
		texture.get_height() / float(vframes))
	scale = view_size / native
	frame = 0


func _process(delta: float) -> void:
	_time += delta
	var index := int(_time * FPS)
	if index >= _frame_count:
		queue_free()
		return
	frame = index
	var progress := _time / (float(_frame_count) / FPS)
	# 最后 25% 淡出，收得干净一些。
	modulate.a = 1.0 if progress < 0.75 else clampf((1.0 - progress) * 4.0, 0.0, 1.0)
