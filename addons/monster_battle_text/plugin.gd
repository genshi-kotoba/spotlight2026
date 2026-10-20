@tool
extends EditorPlugin

const EXPORTER := preload("res://addons/monster_battle_text/text_exporter.gd")
var _exporter: EditorExportPlugin


func _enter_tree() -> void:
	_exporter = EXPORTER.new()
	add_export_plugin(_exporter)


func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null
