@tool
extends EditorExportPlugin


func _get_name() -> String:
	return "MonsterBattleTextFiles"


func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
	# TXT 是非资源文件，不能指望场景引用自动打包；按 CSV 路径精确收集。
	var file := FileAccess.open("res://data/text/monsters.csv", FileAccess.READ)
	if file == null:
		push_error("无法导出怪物战斗文本：缺少 monsters.csv")
		return
	var headers := file.get_csv_line()
	var column := headers.find("战斗中文本资源路径")
	if column < 0:
		return
	var added := {}
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() <= column:
			continue
		var path := row[column].strip_edges()
		if not path.begins_with("res://") or ".." in path or path.get_extension().to_lower() != "txt" or added.has(path):
			continue
		if not FileAccess.file_exists(path):
			push_error("导出时缺少怪物战斗文本：" + path)
			continue
		add_file(path, FileAccess.get_file_as_bytes(path), false)
		added[path] = true
