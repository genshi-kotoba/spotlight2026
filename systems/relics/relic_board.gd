class_name RelicBoard
extends RefCounted

const COLUMNS := 4
const ROWS := 5
const CELL_COUNT := COLUMNS * ROWS
const SAVE_VERSION := 2
const DEFAULT_UNLOCKED := [0, 1, 2, 4, 5, 6, 8, 9, 10]
const SAVE_PATH := "user://relic_test_board.json"

var cells: Array[String] = []
var unlocked_cells: Array[int] = []


func _init() -> void:
	cells.resize(CELL_COUNT)
	cells.fill("")
	unlocked_cells.assign(DEFAULT_UNLOCKED)


func is_unlocked(index: int) -> bool:
	return index >= 0 and index < CELL_COUNT and unlocked_cells.has(index)


func set_unlocked_cells(values: Array) -> Error:
	var prepared := _unlock_indices(values)
	if prepared.size() != values.size(): return ERR_INVALID_DATA
	for index in CELL_COUNT:
		if not cells[index].is_empty() and not prepared.has(index): return ERR_INVALID_DATA
	unlocked_cells.assign(prepared)
	return OK


func unlock_cell(index: int) -> Error:
	if index < 0 or index >= CELL_COUNT: return ERR_INVALID_PARAMETER
	if not unlocked_cells.has(index):
		unlocked_cells.append(index)
		unlocked_cells.sort()
	return OK


func place(index: int, fragment_id: String, catalog: Dictionary) -> Error:
	if not is_unlocked(index) or (not fragment_id.is_empty() and RelicCatalog.resolve(fragment_id, catalog) == null):
		return ERR_INVALID_PARAMETER
	cells[index] = fragment_id
	return OK


func swap_cells(source: int, destination: int) -> Error:
	if not is_unlocked(source) or not is_unlocked(destination):
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
		elif (reach == RelicFragmentData.Reach.ROW and delta.y == 0) \
				or (reach == RelicFragmentData.Reach.COLUMN and delta.x == 0) \
				or (reach == RelicFragmentData.Reach.VERTICAL and delta.x == 0 and delta.y == 1) \
				or reach == RelicFragmentData.Reach.ALL:
			result.append(candidate)
	return result


func to_dictionary() -> Dictionary:
	return {"version": SAVE_VERSION, "columns": COLUMNS, "rows": ROWS,
		"cells": cells.duplicate(), "unlocked_cells": unlocked_cells.duplicate()}


func restore(data: Dictionary, catalog: Dictionary) -> Error:
	var legacy: bool = data.get("version") == 1 and data.get("rows") == 3
	if data.get("columns") != COLUMNS or (not legacy and (data.get("version") != SAVE_VERSION or data.get("rows") != ROWS)):
		return ERR_INVALID_DATA
	var values: Variant = data.get("cells")
	if not values is Array or values.size() != (12 if legacy else CELL_COUNT):
		return ERR_INVALID_DATA
	for value: Variant in values:
		if not value is String or (not value.is_empty() and RelicCatalog.resolve(value, catalog) == null):
			return ERR_INVALID_DATA
	var opens: Variant = range(12) if legacy else data.get("unlocked_cells")
	if not opens is Array: return ERR_INVALID_DATA
	var prepared := _unlock_indices(opens)
	if prepared.size() != opens.size(): return ERR_INVALID_DATA
	for index in values.size():
		if not values[index].is_empty() and not prepared.has(index): return ERR_INVALID_DATA
	var expanded: Array[String] = []
	expanded.assign(values)
	while expanded.size() < CELL_COUNT: expanded.append("")
	cells.assign(expanded)
	unlocked_cells.assign(prepared)
	return OK


static func _unlock_indices(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value: Variant in values:
		if (not value is int and not value is float) or not is_finite(float(value)) \
				or float(value) != floorf(float(value)) or int(value) < 0 or int(value) >= CELL_COUNT or result.has(int(value)):
			return []
		result.append(int(value))
	result.sort()
	return result


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
