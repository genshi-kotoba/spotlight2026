extends Node

## Autoload name: SeedService. Do not also declare class_name SeedService.
## Only the run coordinator starts/restores a run; gameplay modules acquire streams.
const CONTENT_VERSION_SETTING := "application/config/seed_content_version"

var last_error: Error = OK
var _registry: SeedRegistry


func begin_run(seed_text: String = "") -> String:
	if not _ensure_registry():
		return ""
	var result := _registry.begin_run(seed_text)
	last_error = _registry.last_error
	return result


func get_main_seed() -> String:
	return "" if _registry == null else _registry.get_main_seed()


func get_stream(domain: StringName, ids: Array, occurrence: int = 0) -> RandomStream:
	if not _ensure_registry():
		return null
	var stream := _registry.get_stream(domain, ids, occurrence)
	last_error = _registry.last_error
	return stream


func capture_snapshot() -> Dictionary:
	if not _ensure_registry():
		return {}
	var snapshot := _registry.capture_snapshot()
	last_error = _registry.last_error
	return snapshot


func restore_snapshot(snapshot: Dictionary) -> Error:
	if not _ensure_registry():
		return last_error
	last_error = _registry.restore_snapshot(snapshot)
	return last_error


func _ensure_registry() -> bool:
	if _registry != null:
		return true
	var configured: Variant = ProjectSettings.get_setting(CONTENT_VERSION_SETTING, "")
	if not configured is String or configured.strip_edges().is_empty():
		last_error = ERR_UNCONFIGURED
		push_error("SeedService: Configure a nonempty String in " + CONTENT_VERSION_SETTING)
		return false
	_registry = SeedRegistry.new(configured.strip_edges())
	return true
