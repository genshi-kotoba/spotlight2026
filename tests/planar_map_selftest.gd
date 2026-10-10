extends SceneTree

const PlanarMapRun = preload("res://state_machines/run/planar_map_run.gd")
const SeedRegistryScript = preload("res://systems/random/seed_registry.gd")
const CONTENT_VERSION := "planar-map-selftest-v1"
const TEST_SEED := "planar-map-deterministic-seed"

var _failures := 0


func _initialize() -> void:
	var configs: Array = [{}, {"normal": 4}, {"elite": 2}]
	var first_registry := SeedRegistryScript.new(CONTENT_VERSION)
	var first_run := PlanarMapRun.new(first_registry, CONTENT_VERSION)
	_check("新局接受三层配置", first_run.start_new_run(TEST_SEED, configs))
	var first_entry: Dictionary = first_run.enter_floor(1)
	_check("第一层成功生成", not first_entry.is_empty())
	if first_entry.is_empty():
		_finish()
		return

	var snapshot: Dictionary = first_entry["snapshot"]
	var state: Dictionary = first_entry["state"]
	_check("地图身份稳定", snapshot.get("map_id") == "world:floor-001")
	_check("地图种子来自局内主种子", snapshot.get("seed") == TEST_SEED)
	_check("生成结果含格子和节点", not snapshot.get("cells", []).is_empty()
		and not snapshot.get("nodes", []).is_empty())

	var repeated_registry := SeedRegistryScript.new(CONTENT_VERSION)
	_check("重复上下文接受相同主种子", not repeated_registry.begin_run(TEST_SEED).is_empty())
	var shop_stream: Variant = repeated_registry.get_stream(RandomDomains.SHOP, ["isolation"])
	_check("其他随机域可独立消费", shop_stream != null
		and shop_stream.pick(["a", "b"]) != null)
	var repeated_run := PlanarMapRun.new(repeated_registry, CONTENT_VERSION)
	_check("地图可挂到既有随机上下文", repeated_run.attach_existing_run(configs))
	var repeated_entry: Dictionary = repeated_run.enter_floor(1)
	_check("同种子不受其他随机域影响", not repeated_entry.is_empty()
		and JSON.stringify(repeated_entry["snapshot"]) == JSON.stringify(snapshot))

	var saved: Dictionary = first_run.capture_snapshot(state)
	_check("整局地图快照可捕获", not saved.is_empty())
	var restored_registry := SeedRegistryScript.new(CONTENT_VERSION)
	var restored_run := PlanarMapRun.new(restored_registry, CONTENT_VERSION)
	_check("整局地图快照可恢复", restored_run.restore_snapshot(saved))
	var restored_entry: Dictionary = restored_run.get_floor(1)
	_check("恢复后静态地图一致", not restored_entry.is_empty()
		and JSON.stringify(restored_entry["snapshot"]) == JSON.stringify(snapshot))
	_check("恢复后探索状态一致", not restored_entry.is_empty()
		and JSON.stringify(restored_entry["state"]) == JSON.stringify(state))
	_finish()


func _check(label: String, passed: bool) -> void:
	if passed:
		print("  通过  " + label)
	else:
		_failures += 1
		push_error("  失败  " + label)


func _finish() -> void:
	if _failures == 0:
		print("平面地图全部通过")
		quit(0)
	else:
		push_error("平面地图失败 %d 项" % _failures)
		quit(1)
