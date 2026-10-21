extends Control

## 开始界面的设置页。只做一件事：把公共音量块与诊断块摆进图鉴/成就同款的外壳里。
## 音量怎么落地不在这里，见 systems/audio/audio_settings.gd。

const CATALOG_UI := preload("res://ui/catalog/catalog_ui.gd")
const VOLUME_SETTINGS := preload("res://ui/components/volume_settings.gd")
const DIAGNOSTICS_SETTINGS := preload("res://ui/components/diagnostics_settings.gd")


func _ready() -> void:
	var body := CATALOG_UI.shell(self, "设置", "拖动即生效，不需要确认。返回用右上角按钮。")
	var diagnostics := Control.new()
	diagnostics.name = "Diagnostics"
	diagnostics.custom_minimum_size = DIAGNOSTICS_SETTINGS.BLOCK_SIZE
	diagnostics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(diagnostics)
	DIAGNOSTICS_SETTINGS.build(diagnostics)
	var holder := Control.new()
	holder.name = "Volume"
	holder.custom_minimum_size = VOLUME_SETTINGS.BLOCK_SIZE
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(holder)
	VOLUME_SETTINGS.build(holder)
