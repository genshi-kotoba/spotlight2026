extends Node2D
## One current-floor presentation, owned here rather than by a battle scene.
## Game progress and random streams never live in this cache.
const Renderer = preload("res://systems/map/relief_2d/renderer_2d.gd")
var renderer: Node2D
var height_identity := ""
var height_layer: Dictionary = {}
var envelope: Dictionary = {}
var veil_revision := ""
var discovery_revision := 0
var _run_identity := ""
var _borrower: WeakRef

func acquire(borrower: Node, run_identity: String) -> Node2D:
	if _run_identity != run_identity:
		clear()
		_run_identity = run_identity
	if not is_instance_valid(renderer):
		renderer = Renderer.new()
		renderer.name = "ReliefRenderer"
		add_child(renderer)
	_borrower = weakref(borrower)
	renderer.hide()
	renderer.process_mode = Node.PROCESS_MODE_INHERIT
	return renderer

func owns(borrower: Node) -> bool:
	return _borrower != null and _borrower.get_ref() == borrower

func present(borrower: Node) -> void:
	if owns(borrower) and is_instance_valid(renderer):
		renderer.show()

func release(borrower: Node) -> void:
	if not owns(borrower):
		return
	_borrower = null
	if is_instance_valid(renderer):
		renderer.hide()
		renderer.process_mode = Node.PROCESS_MODE_DISABLED

func clear() -> void:
	_borrower = null
	if is_instance_valid(renderer):
		renderer.free() # Renderer joins all outstanding workers in _exit_tree.
	renderer = null
	height_identity = ""
	height_layer = {}
	envelope = {}
	veil_revision = ""
	discovery_revision = 0
	_run_identity = ""
