extends Node
## 只持有资源，不实例化玩法场景、不访问节点、不生成商店、不推进随机流。
## 全部节点共用同一份公共资源；每次换层替换节点清单和本层专有缓存。
const MAP_SCENE := "res://ui/main_menu/menu_map_entry.tscn"
const MENU_SCENE := "res://ui/main_menu/main_menu.tscn"
const BATTLE_SCENE := "res://ui/battle/map_battle_scene.tscn"
const CARD_SCENE := "res://ui/components/card/card_view.tscn"
const SHOP_SCRIPT := "res://ui/shop/shop_popup.gd"
const LOOT_SCRIPT := "res://ui/rewards/loot_popup.gd"
const Environments = preload("res://ui/battle/battle_environment.gd")
const BATTLE_DYNAMIC := [
	"res://ui/battle/block_shield.gd", "res://ui/components/item_icon.gd",
	"res://ui/components/hover_tip.gd", "res://ui/world_map/map_viewer.gd",
	"res://assets/ui/UI-025/中毒.png", "res://assets/ui/UI-025/力量.png",
	"res://assets/ui/UI-025/虚弱.png",
]
const MAX_IN_FLIGHT := 2
const FRAME_BUDGET_USEC := 1500
var _resources: Dictionary = {}
var _texts: Dictionary = {}
var _errors: Dictionary = {}
var _pins: Dictionary = {}
var _map_paths: Dictionary = {}
var _queued: Array[String] = []
var _in_flight: Dictionary = {}
var _nodes: Dictionary = {}
var _map_id := ""
var _run_id := ""
var _priority_node := ""
var _rule_resources: Array[String] = []
var cache_hits := 0
var foreground_misses := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	SaveGateway.run_started.connect(func(_slot: int): clear_map())
	SaveGateway.active_slot_changed.connect(func(_slot: int): clear_map())

## 菜单显示期间就读取地图入口与通用战斗资源，不把工作留到点击新游戏之后。
func warm_menu(game_scene := MAP_SCENE) -> void:
	for path: String in [game_scene, BATTLE_SCENE, MENU_SCENE, SHOP_SCRIPT, LOOT_SCRIPT, CARD_SCENE]:
		request_resource(path)

func request_resource(path: String, pin := true, priority := false) -> Error:
	if not path.begins_with("res://") or ".." in path:
		return ERR_INVALID_PARAMETER
	if pin:
		_pins[path] = true
	if _resources.has(path) or _texts.has(path) or _in_flight.has(path):
		return OK
	if path in _queued:
		if priority:
			_queued.erase(path)
			_queued.push_front(path)
		return OK
	var exists := FileAccess.file_exists(path) if path.ends_with(".txt") else ResourceLoader.exists(path)
	if not exists:
		_errors[path] = ERR_FILE_NOT_FOUND
		return ERR_FILE_NOT_FOUND
	_errors.erase(path)
	if priority:
		_queued.push_front(path)
	else:
		_queued.append(path)
	set_process(true)
	return OK

## 每层加载/恢复后调用。snapshot 是完整内部地图，绝不把 content_id 交给显示层。
func prepare_map(snapshot: Dictionary, run_id: String, monsters: Dictionary = {}) -> void:
	_map_id = str(snapshot.get("map_id", ""))
	_run_id = run_id
	_priority_node = ""
	_nodes.clear()
	_map_paths.clear()
	var floor_index := clampi(int(snapshot.get("floor_index", 1)), 1, 4)
	var card_art: Array[String] = []
	for category: String in ["cards", "fragments", "items"]:
		for record: Dictionary in TextCatalog.entries(category):
			var path := str(record.get("art_path", record.get("icon_path", "")))
			if path.begins_with("res://") and path not in card_art and ResourceLoader.exists(path):
				card_art.append(path)
	if _rule_resources.is_empty():
		_collect_resources("res://data/cards")
		_collect_resources("res://data/buffs")
	for node: Dictionary in snapshot.get("nodes", []):
		var paths: Array[String] = [MAP_SCENE, MENU_SCENE]
		match str(node.get("type", "")):
			"battle", "elite", "boss":
				paths.append_array([BATTLE_SCENE, CARD_SCENE, LOOT_SCRIPT, Environments.path_for_floor(floor_index)])
				paths.append_array(BATTLE_DYNAMIC)
				paths.append_array(_rule_resources)
				paths.append_array(card_art)
				var id := str(node.get("content_id", ""))
				var enemy: Dictionary = monsters.get(id, TextCatalog.entry("monsters", id))
				# 与正式战斗相同：台词优先按稳定图片路径匹配，兼容旧怪物编号。
				for path: String in [str(enemy.get("art_path", "")), TextCatalog.monster_battle_text_path({"enemy_id": id, "art_path": enemy.get("art_path", "")})]:
					if path.begins_with("res://"):
						paths.append(path)
			"shop":
				paths.append_array([SHOP_SCRIPT, LOOT_SCRIPT, CARD_SCENE])
				# 不提前抽取/保存货架，缓存候选卡图也覆盖未来开包和附魔选牌。
				paths.append_array(card_art)
			"event":
				var index := RandomEventCatalog.index_for_node(SeedService.get_main_seed(), _map_id, str(node.id))
				paths.append_array([RandomEventCatalog.SCENE, RandomEventCatalog.background(index), CARD_SCENE])
			_:
				# 当前事件/休息节点是地图内已有的弹窗，不存在额外独立场景。
				# 仍登记全部节点；以后有专属页面可在此补充资源。
				pass
		_nodes[str(node.id)] = {"kind": str(node.get("type", "")), "paths": paths}
		for path: String in paths:
			_map_paths[path] = true
	_trim_floor_cache()
	# 公共场景先入队；单独请求每个节点的贴图/台词，重复路径自动去重。
	warm_menu()
	for path: String in _map_paths:
		request_resource(path, false)

func prioritize_node(map_id: String, node_id: String) -> void:
	if map_id != _map_id or node_id == _priority_node or not _nodes.has(node_id):
		return
	_priority_node = node_id
	var paths: Array = _nodes[node_id].paths
	for index in range(paths.size() - 1, -1, -1):
		request_resource(str(paths[index]), false, true)

func node_status(map_id: String, node_id: String) -> Dictionary:
	if map_id != _map_id or not _nodes.has(node_id):
		return {}
	var ready := 0
	var failed := 0
	var paths: Array = _nodes[node_id].paths
	for path: String in paths:
		ready += int(_resources.has(path) or _texts.has(path))
		failed += int(_errors.has(path))
	return {"total": paths.size(), "ready": ready, "failed": failed, "complete": ready == paths.size()}

func stats() -> Dictionary:
	return {"map_id": _map_id, "nodes": _nodes.size(), "cached": _resources.size(),
		"texts": _texts.size(), "queued": _queued.size(), "loading": _in_flight.size(),
		"hits": cache_hits, "misses": foreground_misses, "failed": _errors.size()}

func clear_map() -> void:
	_map_id = ""
	_run_id = ""
	_priority_node = ""
	_nodes.clear()
	_map_paths.clear()
	_trim_floor_cache()

func cached_resource(path: String) -> Resource:
	return _resources.get(path)

func cached_text(path: String) -> Variant:
	if not _texts.has(path):
		return null
	var value: Dictionary = _texts[path]
	if int(value.modified) != FileAccess.get_modified_time(path):
		_texts.erase(path)
		return null
	return value.text

## 转场只取本缓存；遇到探索尚未加载完的节点时提升请求优先级，等待同一个任务。
func load_scene(path: String) -> PackedScene:
	if _resources.get(path) is PackedScene:
		cache_hits += 1
		return _resources[path]
	foreground_misses += 1
	if request_resource(path, true, true) != OK:
		return null
	while not _resources.has(path) and not _errors.has(path):
		await get_tree().process_frame
	return _resources.get(path) as PackedScene

func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	# 只收取已完成任务；绝不对 IN_PROGRESS 调用阻塞式 get。
	for path: String in _in_flight.keys():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_in_flight.erase(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var resource := ResourceLoader.load_threaded_get(path)
			if _wanted(path) and resource != null:
				_resources[path] = resource
			elif _wanted(path):
				_errors[path] = ERR_INVALID_DATA
		elif _wanted(path):
			_errors[path] = ERR_CANT_OPEN
		# 脚本依赖与贴图提交的单次成本不可切分，每帧至多接收一个。
		break
	while not _queued.is_empty() and _in_flight.size() < MAX_IN_FLIGHT and Time.get_ticks_usec() - started < FRAME_BUDGET_USEC:
		var path: String = _queued.pop_front()
		if not _wanted(path):
			continue
		if path.ends_with(".txt"):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				_texts[path] = {"text": file.get_as_text().trim_prefix("\uFEFF"), "modified": FileAccess.get_modified_time(path)}
			else:
				_errors[path] = FileAccess.get_open_error()
		else:
			var type_hint := "PackedScene" if path.ends_with(".tscn") else ""
			var error := ResourceLoader.load_threaded_request(path, type_hint)
			if error == OK:
				_in_flight[path] = true
			else:
				_errors[path] = error
	set_process(not _queued.is_empty() or not _in_flight.is_empty())

func _wanted(path: String) -> bool:
	return _pins.has(path) or _map_paths.has(path)

func _trim_floor_cache() -> void:
	for cache: Dictionary in [_resources, _texts, _errors]:
		for path: String in cache.keys():
			if not _wanted(path):
				cache.erase(path)
	for path: String in _queued.duplicate():
		if not _wanted(path):
			_queued.erase(path)
	# 无法取消的旧楼层线程正常收尾，完成后按 _wanted 丢弃，不污染新局。

func _collect_resources(directory: String) -> void:
	for file: String in DirAccess.get_files_at(directory):
		if file.ends_with(".tres"):
			_rule_resources.append(directory.path_join(file))
	for child: String in DirAccess.get_directories_at(directory):
		_collect_resources(directory.path_join(child))
