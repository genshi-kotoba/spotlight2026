@tool
extends EditorPlugin

class RuntimePngExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "RuntimePngExport"

	func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		# These images are decoded on the CPU to build atlas/alpha/fog data.
		# Imported .ctex alone cannot satisfy FileAccess.get_file_as_bytes().
		for directory: String in ["res://assets/environment", "res://assets/map_nodes"]:
			_include_pngs(directory)

	func _include_pngs(directory: String) -> void:
		for name: String in DirAccess.get_files_at(directory):
			if name.get_extension().to_lower() == "png":
				var path := directory.path_join(name)
				add_file(path, FileAccess.get_file_as_bytes(path), false)
		for child: String in DirAccess.get_directories_at(directory):
			_include_pngs(directory.path_join(child))

var _exporter: EditorExportPlugin

func _enter_tree() -> void:
	_exporter = RuntimePngExport.new()
	add_export_plugin(_exporter)

func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null
