class_name CsvTextTable
extends RefCounted

## UTF-8 CSV，支持 BOM、CRLF、引号转义和跨行文本。错误整表拒绝，不展示半份数据。
static func read(path: String, headers: Array, keys: Array) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure(FileAccess.get_open_error(), "无法读取：" + path)
	return parse(file.get_as_text(), headers, keys)


static func parse(source: String, headers: Array, keys: Array) -> Dictionary:
	if source.begins_with("\uFEFF"):
		source = source.substr(1)
	var rows: Array = []
	var row: Array = []
	var field := ""
	var quoted := false
	var closed := false
	var i := 0
	while i < source.length():
		var ch := source.substr(i, 1)
		if quoted:
			if ch == "\"":
				if i + 1 < source.length() and source.substr(i + 1, 1) == "\"":
					field += "\""
					i += 1
				else:
					quoted = false
					closed = true
			else:
				field += ch
		elif ch == "," or ch == "\n" or ch == "\r":
			row.append(field)
			field = ""
			closed = false
			if ch != ",":
				rows.append(row)
				row = []
				if ch == "\r" and i + 1 < source.length() and source.substr(i + 1, 1) == "\n":
					i += 1
		elif ch == "\"":
			if not field.is_empty() or closed:
				return _failure(ERR_PARSE_ERROR, "CSV 引号必须位于字段开头")
			quoted = true
		else:
			if closed:
				return _failure(ERR_PARSE_ERROR, "CSV 闭合引号后出现非法字符")
			field += ch
		i += 1
	if quoted:
		return _failure(ERR_PARSE_ERROR, "CSV 文本引号未闭合")
	if not row.is_empty() or not field.is_empty() or closed:
		row.append(field)
		rows.append(row)
	if rows.is_empty() or rows[0] != headers or headers.size() != keys.size():
		return _failure(ERR_INVALID_DATA, "CSV 表头必须为：" + ",".join(headers))
	var records: Array[Dictionary] = []
	var ids: Dictionary = {}
	for r: int in range(1, rows.size()):
		var cells: Array = rows[r]
		var blank := true
		for cell: String in cells:
			blank = blank and cell.strip_edges().is_empty()
		if blank:
			continue
		if cells.size() != keys.size():
			return _failure(ERR_INVALID_DATA, "CSV 第 %d 条记录列数不匹配" % (r + 1))
		var id: String = cells[0].strip_edges()
		if id.is_empty() or ids.has(id):
			return _failure(ERR_INVALID_DATA, "CSV 第 %d 条记录编号为空或重复" % (r + 1))
		var record: Dictionary = {}
		for c: int in keys.size():
			record[keys[c]] = cells[c]
		record["id"] = id
		ids[id] = true
		records.append(record)
	# 自然数字排序：2 在 10 前，CARD-002 在 CARD-010 前。
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var compared := String(a.id).naturalnocasecmp_to(String(b.id))
		return String(a.id) < String(b.id) if compared == 0 else compared < 0)
	return {"error": OK, "message": "", "records": records}


static func _failure(error: Error, message: String) -> Dictionary:
	return {"error": error, "message": message, "records": []}
