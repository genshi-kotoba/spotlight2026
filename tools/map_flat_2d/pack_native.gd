extends SceneTree
## Raw source bundle for the isolated native demo; no editor or 3D assets.
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not args[0].is_absolute_path():
		push_error("Expected an absolute output PCK path")
		quit(1)
		return
	var output: String = args[0]
	var settings := output.get_base_dir().path_join("flat-project.binary")
	if ProjectSettings.save_custom(settings) != OK:
		quit(1)
		return
	var pack := PCKPacker.new()
	if pack.pck_start(output) != OK or pack.add_file("res://project.binary", settings) != OK:
		quit(1)
		return
	var files: Array[String] = ["systems/map/hex_coord.gd", "core/signals/map_events.gd", "autoload/seed_service.gd", "state_machines/run/planar_map_run.gd", ".godot/global_script_class_cache.cfg"]
	for folder in ["systems/map/flat_2d", "systems/random", "ui/world_map/flat_2d", "data/config/flat_2d"]:
		for file in DirAccess.get_files_at("res://" + folder):
			if file.get_extension() in ["gd", "tscn", "json"]:
				files.append(folder.path_join(file))
	for file in files:
		if pack.add_file("res://" + file, "res://" + file) != OK:
			push_error("Could not pack " + file)
			quit(1)
			return
	if pack.flush() != OK:
		quit(1)
		return
	print("Flat demo PCK: ", output, " (", files.size(), " source files)")
	quit()
