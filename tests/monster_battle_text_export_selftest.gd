extends SceneTree
## 独立 MainLoop，不启动战斗、不写存档。参数为 -- 导出PCK绝对路径。


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not ProjectSettings.load_resource_pack(args[0], true):
		push_error("请传入可挂载的怪物文本测试PCK")
		quit(1)
		return
	var file := FileAccess.open("res://data/text/monsters.csv", FileAccess.READ)
	if file == null:
		quit(1)
		return
	var headers := file.get_csv_line()
	var column := headers.find("战斗中文本资源路径")
	var count := 0
	while not file.eof_reached() and column >= 0:
		var row := file.get_csv_line()
		if row.size() <= column:
			continue
		var path := row[column]
		if not FileAccess.file_exists(path) or FileAccess.get_file_as_string(path).strip_edges().is_empty():
			push_error("PCK缺少怪物文本：" + path)
			quit(1)
			return
		count += 1
	print("PASS 导出PCK包含全部%d份真实怪物TXT" % count)
	quit(0 if count == 23 else 1)
