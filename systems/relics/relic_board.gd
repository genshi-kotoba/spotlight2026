class_name RelicBoard
extends RefCounted

const COLUMNS := 4
const ROWS := 3
const CELL_COUNT := COLUMNS * ROWS
const SAVE_VERSION := 1
const SAVE_PATH := "user://relic_test_board.json"

var cells: Array[String] = []


func _init() -> void:
	cells.resize(CELL_COUNT)
	cells.fill("")


func place(index: int, fragment_id: String, catalog: Dictionary) -> Error:
	if index < 0 or index >= CELL_COUNT or (not fragment_id.is_empty() and not catalog.has(fragment_id)):
		return ERR_INVALID_PARAMETER
	cells[index] = fragment_id
	return OK


func swap_cells(source: int, destination: int) -> Error:
	if source < 0 or source >= CELL_COUNT or destination < 0 or destination >= CELL_COUNT:
		return ERR_INVALID_PARAMETER
	var previous := cells[destination]
	cells[destination] = cells[source]
	cells[source] = previous
	return OK


func neighbors(index: int, reach: RelicFragmentData.Reach) -> Array[int]:
	var result: Array[int] = []
	if index < 0 or index >= CELL_COUNT or reach == RelicFragmentData.Reach.NONE:
		return result
	var origin := Vector2i(index % COLUMNS, index / COLUMNS)
	for candidate in CELL_COUNT:
		var position := Vector2i(candidate % COLUMNS, candidate / COLUMNS)
		var delta := (position - origin).abs()
		if candidate == index:
			continue
		if reach == RelicFragmentData.Reach.FOUR and delta.x + delta.y == 1:
			result.append(candidate)
		elif reach == RelicFragmentData.Reach.EIGHT and maxi(delta.x, delta.y) == 1:
			result.append(candidate)
	return result


func to_dictionary() -> Dictionary:
	return {"version": SAVE_VERSION, "columns": COLUMNS, "rows": ROWS, "cells": cells.duplicate()}


func restore(data: Dictionary, catalog: Dictionary) -> Error:
	if data.get("version") != SAVE_VERSION or data.get("columns") != COLUMNS or data.get("rows") != ROWS:
		return ERR_INVALID_DATA
	var values: Variant = data.get("cells")
	if not values is Array or values.size() != CELL_COUNT:
		return ERR_INVALID_DATA
	for value: Variant in values:
		if not value is String or (not value.is_empty() and not catalog.has(value)):
			return ERR_INVALID_DATA
	cells.assign(values)
	return OK


func save_to_file(path: String = SAVE_PATH) -> Error:
	# 临时文件完成写入后再替换；失败时保留原有配置。
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dictionary(), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return error
	return DirAccess.rename_absolute(temporary, path)


func load_from_file(catalog: Dictionary, path: String = SAVE_PATH) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return ERR_INVALID_DATA
	return restore(parsed, catalog)
