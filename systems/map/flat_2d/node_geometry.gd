extends RefCounted
## Logical planar circles/capsules, measured against the hex outer radius = 1.
## Height and rendering scale never participate in these dimensions.
const MAX_BODY_RADIUS := 0.45
# Basis.from_euler(Vector3(-pitch, yaw=35 degrees, 0)).x projected to X/Z.
const CAMERA_RIGHT := Vector2(0.8191520442889918, -0.5735764363510460)
const CAMERA_NEAR := Vector2(0.5735764363510460, 0.8191520442889918)
const EVENT_CAPSULE_HALF_LENGTH := 0.32
const EVENT_CAPSULE_RADIUS := 0.012
const ALCHEMY_BODY_RADII := {
	"battle": 0.34, "boss": 0.42, "shop": 0.38,
	# Retain the earlier event-circle dimension for explicit old circle callers.
	# New event snapshots use event_capsule() instead.
	"chest": 0.34, "pile": 0.30, "event": 0.30,
}
const RELEASED_TYPES := ["battle", "elite", "boss", "chest", "pile"]

static func alchemy_radius(type: String) -> float:
	return float(ALCHEMY_BODY_RADII.get(type, 0.0))

static func event_capsule() -> Dictionary:
	return {"half_length": EVENT_CAPSULE_HALF_LENGTH, "radius": EVENT_CAPSULE_RADIUS,
		"axis": [CAMERA_RIGHT.x, CAMERA_RIGHT.y]}

static func active_capsule(node: Dictionary, completed: bool) -> Dictionary:
	if not node.has("body_capsule") or _released(node, completed):
		return {}
	return node.body_capsule.duplicate(true)

static func active_radius(node: Dictionary, completed: bool) -> float:
	if _released(node, completed):
		return 0.0
	return float(node.get("body_radius", 0.0))

static func _released(node: Dictionary, completed: bool) -> bool:
	# A closed local gate already blocks its complete footprint. Finishing it
	# releases both that footprint and its optional small entity.
	return (node.get("is_route_gate", false) and not completed) or (completed and node.type in RELEASED_TYPES)
