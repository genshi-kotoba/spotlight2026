extends RefCounted
## 等待真实表现层完成，不用固定帧数猜测异步地图与动画时长。
static func map_ready(tree: SceneTree, timeout_seconds := 90.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000)
	var transition := tree.root.get_node_or_null("SceneTransition")
	while transition != null and transition.is_loading():
		if Time.get_ticks_msec() >= deadline:
			push_error("测试等待场景加载遮罩关闭超时")
			return false
		await tree.create_timer(0.01).timeout
	while true:
		var scene := tree.current_scene
		if not is_instance_valid(scene) or not scene.has_method("is_map_ready") or scene.is_map_ready():
			return true
		if Time.get_ticks_msec() >= deadline:
			push_error("测试等待地图表现就绪超时：" + str(scene.get("_prepare_error")))
			return false
		await tree.create_timer(0.01).timeout
	return false

## 当前地图可走动时，路线门后的发现缓存仍可在后台准备。
## 需要发起路线战斗的用例应显式等待这里，普通输入/标题用例仍等待 map_ready。
static func route_ready(tree: SceneTree, timeout_seconds := 90.0) -> bool:
	if not await map_ready(tree, timeout_seconds):
		return false
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000)
	while true:
		var scene := tree.current_scene
		if not is_instance_valid(scene):
			return true
		var view: Variant = scene.get("_view")
		if not is_instance_valid(view) or not view.has_method("is_presentation_cache_preparing") or not view.is_presentation_cache_preparing():
			return true
		if Time.get_ticks_msec() >= deadline:
			push_error("测试等待路线发现缓存完成超时")
			return false
		await tree.create_timer(0.01).timeout
	return false

static func battle_settled(scene: BattleTestScene, timeout_seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000)
	while is_instance_valid(scene) and (scene._busy or scene._animating):
		if Time.get_ticks_msec() >= deadline:
			push_error("测试等待战斗动画完成超时")
			return false
		await scene.get_tree().create_timer(0.01).timeout
	return true
