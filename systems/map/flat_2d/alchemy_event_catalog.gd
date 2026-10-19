extends RefCounted
## Stable event identities only. Effects and presentation assets belong to callers.
const EVENTS := {
	"great_work": {"display_name": "伟大炼成", "asset_id": "EVBG-001"},
	"medical": {"display_name": "医疗", "asset_id": "EVBG-002"},
	"empty_gambling_table": {"display_name": "空置赌桌", "asset_id": "EVBG-003"},
	"death_and_taxes": {"display_name": "死亡与赋税", "asset_id": "EVBG-004"},
	"wishing_well": {"display_name": "许愿池", "asset_id": "EVBG-005"},
	"beast_fight": {"display_name": "与兽共斗", "asset_id": "EVBG-006"},
	"damage_stele": {"display_name": "伤害石碑", "asset_id": "EVBG-007"},
	"object_confession": {"display_name": "器物告白", "asset_id": "EVBG-008"},
	"codex_exchange": {"display_name": "典籍交换", "asset_id": "EVBG-009"},
	"material_synthesis": {"display_name": "素材合成", "asset_id": "EVBG-010"},
	"material_upgrade": {"display_name": "素材升级", "asset_id": "EVBG-011"},
	"listening_conch": {"display_name": "倾听海螺", "asset_id": "EVBG-012"},
}

static func ids() -> Array:
	# Dictionary insertion order is the stable catalog order used by map.nodes.
	return EVENTS.keys()

static func has_event(id: String) -> bool:
	return EVENTS.has(id)

static func display_name(id: String) -> String:
	return str(EVENTS[id].display_name) if EVENTS.has(id) else ""
