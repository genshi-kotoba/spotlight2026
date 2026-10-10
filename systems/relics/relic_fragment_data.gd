class_name RelicFragmentData
extends Resource

enum Kind { TRIGGER, EFFECT, PRESENCE }
enum Reach { NONE, FOUR, EIGHT }

@export var fragment_id := ""
@export var display_name := ""
@export_multiline var description := ""
@export var kind: Kind = Kind.EFFECT
@export var event_id := ""
@export var reach: Reach = Reach.NONE
@export var action_id := ""
@export var amount := 0


func kind_name() -> String:
	return ["触发", "效果", "存在"][kind]


func tint() -> Color:
	return [Color("d1a55b"), Color("71b8cb"), Color("b69ddd")][kind]
