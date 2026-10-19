class_name CardEffectProgram
extends CardEffect

## 静态指令资源，不在运行时解析自然语言。只产生队列命令。
@export var instructions: Array[Dictionary] = []

func execute(ctx: EffectContext, card: Dictionary) -> void:
	ctx.execute_card_program(instructions, card)
	executed.emit(self, card)
