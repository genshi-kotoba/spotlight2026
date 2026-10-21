extends Node

var suspend_on_focus_loss:bool = false;
var _wwise: Object

func _init() -> void:
	suspend_on_focus_loss = ProjectSettings.get_setting("wwise/common_user_settings/suspend_audio_during_focus_loss", false)
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Native libraries are platform-specific; keep the autoload usable when absent.
	if not Engine.has_singleton("Wwise"):
		push_warning("WwiseRuntimeManager: native Wwise module unavailable on %s" % OS.get_name())
		return
	_wwise = Engine.get_singleton("Wwise")
	_wwise.call("init")


func _process(_delta: float) -> void:
	if is_instance_valid(_wwise) and _wwise.call("is_initialized"):
		_wwise.call("render_audio")


func _notification(what: int) -> void:
	if not is_instance_valid(_wwise):
		return
	if suspend_on_focus_loss:
		# Handling pause state on desktop platforms
		if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
			pause()
		elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
			resume()

	# Handling pause state on Android
	if what == NOTIFICATION_APPLICATION_PAUSED:
		pause()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		resume()

	# Handling shutdown
	if what == NOTIFICATION_EXIT_TREE || what == NOTIFICATION_CRASH:
		if not _wwise.call("is_initialized"):
			return
		_wwise.call("shutdown")


func pause():
	if is_instance_valid(_wwise) and _wwise.call("is_initialized"):
		_wwise.call("suspend", false)


func resume():
	if is_instance_valid(_wwise) and _wwise.call("is_initialized"):
		_wwise.call("wakeup_from_suspend")
