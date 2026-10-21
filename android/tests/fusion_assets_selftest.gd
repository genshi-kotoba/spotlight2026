extends Node
## 合并回归：美术按层隔离，不改玩法种子、地图数据或正式玩家存档。
const Themes = preload("res://systems/map/relief_2d/map_art_themes.gd")
const Catalog = preload("res://systems/map/relief_2d/art_variant_catalog.gd")
const ArtMaterial = preload("res://systems/map/relief_2d/env005_material.gd")
const Renderer = preload("res://systems/map/relief_2d/renderer_2d.gd")
const NodeArt = preload("res://systems/map/relief_2d/node_art.gd")
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	SeedService.begin_run("fusion-art-fixture")
	var random_before := JSON.stringify(SeedService.capture_snapshot())
	var identities: Array = []
	for floor_index in range(1, 5):
		var theme := Themes.for_floor(floor_index)
		var material := ArtMaterial.new()
		material.select_floor(floor_index)
		_check("第%d层主题有效且缓存身份独立" % floor_index, theme.fallback_reason.is_empty() and material.atlas_path == theme.atlas and not identities.has(material.cache_identity()))
		identities.append(material.cache_identity())
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Themes.CONFIG_PATH))
	for id: String in config.themes:
		var definition: Dictionary = config.themes[id]
		var catalog := Catalog.new({}, definition.manifest)
		var atlas := ArtMaterial.atlas_texture(definition.atlas)
		_check("主题%s图集与UV尺寸匹配" % id, atlas != null and atlas.get_size() == catalog.size)
		_check("主题%s目录完整且共享纹理" % id, catalog.errors.is_empty() and not catalog.pools.ground.is_empty() and not catalog.pools.wall.is_empty() and atlas == ArtMaterial.atlas_texture(definition.atlas))
	_check("未知层数仅回退美术，不开放新层", Themes.for_floor(0).id == "alchemy" and Themes.for_floor(5).id == "alchemy")
	for kind: String in NodeArt.EVENT_ART:
		var hidden := NodeArt.describe({"type": "event", "event_kind": kind, "display_name": "不应泄露事件名"})
		var opened := NodeArt.describe({"type": "event", "event_kind": kind, "opened": true})
		_check("事件%s隐藏身份且解锁后使用对应图片" % kind, hidden.label == "?" and hidden.texture.ends_with("question.png") and opened.texture == NodeArt.EVENT_ART[kind] and ResourceLoader.exists(opened.texture))
	_check("精英节点使用专用美术", NodeArt.describe({"type": "elite"}).texture.ends_with("elite.png"))
	var button := Button.new()
	button.text = "返回"
	CommonUiSkin.style_navigation_button(button, "back", true)
	_check("返回图标保留可访问说明", button.icon != null and button.text.is_empty() and button.tooltip_text == "返回")
	button.free()
	for floor_index in [2, 3]:
		var snapshot := _map(floor_index)
		var original := snapshot.duplicate(true)
		var known: Dictionary = {}
		for cell: Dictionary in snapshot.cells: known["%d,%d" % [cell.q, cell.r]] = true
		var renderer := Renderer.new(false)
		renderer.set_art_enabled(true, false)
		add_child(renderer)
		renderer.set_layer(snapshot, known, {}, true)
		var atlas := ArtMaterial.atlas_texture(Themes.for_floor(floor_index).atlas)
		var textured := 0
		var correct := true
		for batch in renderer._vector_batches:
			if batch._atlas_texture != null:
				textured += 1
				correct = correct and batch._atlas_texture == atlas
		_check("第%d层实际网格使用当前主题图集" % floor_index, textured > 0 and correct)
		_check("第%d层渲染不修改地图快照" % floor_index, snapshot == original)
		var bounds: Rect2 = renderer.get_bounds()
		var factor := minf(1400.0 / maxf(bounds.size.x, 1.0), 780.0 / maxf(bounds.size.y, 1.0))
		renderer.scale = Vector2.ONE * factor
		renderer.position = get_viewport().get_visible_rect().size * 0.5 - bounds.get_center() * factor
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://.godot/fusion20261020-map-floor-%d.png" % floor_index)
		renderer.queue_free()
		await get_tree().process_frame
	_check("所有美术选择不消耗玩法随机流", random_before == JSON.stringify(SeedService.capture_snapshot()))
	print("fusion资产与主题整合：全部通过" if failures == 0 else "fusion资产与主题整合：失败%d项" % failures)
	get_tree().quit(failures)

func _map(floor_index: int) -> Dictionary:
	var cells: Array = []
	for q in range(-2, 3):
		for r in range(-2, 3):
			cells.append({"q": q, "r": r, "level": 0, "terrain": "wall" if q == -2 or r == -2 else "ground"})
	return {"map_id": "fusion:floor-%03d" % floor_index, "seed": "fusion-art-fixture", "floor_index": floor_index, "cells": cells, "nodes": [], "spawn": [0, 0], "height_quantum": 0.2, "outer_radius": 1.0}

func _check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("%s %s" % ["PASS" if passed else "FAIL", label])
