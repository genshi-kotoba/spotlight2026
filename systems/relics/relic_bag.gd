class_name RelicBag
extends RefCounted

## 背包里还没装进典籍的残片，按进包顺序排。先来的在前，不做任何排序 ——
## 装进典籍就移出，从典籍上摘下来就接在末尾。
## 存在单独一个文件里，因为典籍板面（RelicBoard）只管那 20 格装了谁。

const SAVE_PATH := "user://relic_bag.json"
const SAVE_VERSION := 1

var fragment_ids: Array[String] = []


## 读盘。文件不存在时按目录顺序铺一遍，好让测试环境一进背包就有残片可拖。
## 目录里已经没有的、以及已经装进典籍的 id 都会被剔掉。
func load_from_file(catalog: Dictionary, placed: Array[String] = []) -> Error:
	fragment_ids.clear()
	var error := OK
	if FileAccess.file_exists(SAVE_PATH):
		error = _read(catalog, placed)
		if error != OK:
			fragment_ids.clear()
	if fragment_ids.is_empty():
		for fragment_id: String in catalog.keys():
			if not placed.has(fragment_id):
				fragment_ids.append(fragment_id)
	return error


## 追加到末尾。已经在里面的不重复加，避免同一个残片在背包里出现两份。
func add(fragment_id: String) -> void:
	if fragment_id.is_empty() or fragment_ids.has(fragment_id):
		return
	fragment_ids.append(fragment_id)


func remove(fragment_id: String) -> void:
	fragment_ids.erase(fragment_id)


func has(fragment_id: String) -> bool:
	return fragment_ids.has(fragment_id)


func save_to_file() -> Error:
	var data := {
		"version": SAVE_VERSION,
		"fragments": fragment_ids.duplicate(),
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return OK


func _read(catalog: Dictionary, placed: Array[String]) -> Error:
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return ERR_FILE_CORRUPT
	var raw: Variant = (parsed as Dictionary).get("fragments", [])
	if not raw is Array:
		return ERR_FILE_CORRUPT
	for entry: Variant in raw:
		var fragment_id := str(entry)
		if fragment_id.is_empty() or not catalog.has(fragment_id) or placed.has(fragment_id):
			continue
		add(fragment_id)
	return OK
