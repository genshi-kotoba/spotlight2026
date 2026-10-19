extends RefCounted
## Original CC0 sheets, drawn inside the same canvas pass as foreground faces.
## Actual displacement drives walk frames, so collision cannot animate sliding.
const Profile = preload("res://systems/map/relief_2d/actor_profile.gd")
const DIRECTIONS := ["e", "se", "s", "sw", "w", "nw", "n", "ne"]
## 扇区边界上的滞回，约 10°。不设它时朝向会在 45° 边界上来回跳。
const FACING_HYSTERESIS := 0.17
var config: Dictionary = {}
var textures: Dictionary = {}
var facing := "s"
var walking := false
var _last_move_angle := PI / 2.0
var walk_phase := 0.0
var idle_time := 0.0
var frame_index := 0
var pixel_scale := 1.0

func load_config(path: String, target_height: float) -> bool:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not parsed.has_all(["animations", "frame_size", "foot_anchor"]): return false
	config = parsed
	pixel_scale = target_height / float(config.get("max_body_height_px", 46))
	for animation: Array in config.animations.values():
		for frame: Dictionary in animation:
			var file := String(frame.path)
			if textures.has(file): continue
			if FileAccess.file_exists(file) and not FileAccess.file_exists(file + ".import"):
				# The isolated raw-source PCK intentionally includes original PNG bytes.
				var img := Image.new()
				if img.load_png_from_buffer(FileAccess.get_file_as_bytes(file)) != OK or img.is_empty(): return false
				textures[file] = ImageTexture.create_from_image(img)
			elif ResourceLoader.exists(file):
				# Standard Godot exports may remap PNGs to imported .ctex.
				var imported = load(file)
				if not imported is Texture2D: return false
				textures[file] = imported
			else:
				return false
	return not textures.is_empty()

func advance(plane_delta: Vector2, screen_delta: Vector2, delta: float) -> bool:
	var old := "%s:%s:%d" % [facing, walking, frame_index]
	var was_walking := walking
	walking = plane_delta.length_squared() > 0.00000001
	if walking:
		_last_move_angle = screen_delta.angle()
		facing = _resolve_facing(_last_move_angle)
		walk_phase = fposmod(walk_phase + plane_delta.length() / Profile.STRIDE_DISTANCE, 1.0)
		idle_time = 0.0
	else:
		idle_time += delta
		if was_walking:
			# 停下时对准最终移动方向，别停在滞回留住的旧扇区。
			facing = DIRECTIONS[posmod(int(round(_last_move_angle / (PI / 4.0))), 8)]
	var frames: Array = config.get("animations", {}).get(animation_name(), [])
	frame_index = mini(frames.size() - 1, int(walk_phase * frames.size())) if walking else 0
	return old != "%s:%s:%d" % [facing, walking, frame_index]

func _resolve_facing(angle: float) -> String:
	var current := DIRECTIONS.find(facing)
	if current < 0:
		current = 0
	var offset := wrapf(angle - current * (PI / 4.0), -PI, PI)
	# 扇区边界在 ±22.5°，滞回加在这条边界上，不是加在扇区中心。
	if absf(offset) <= PI / 8.0 + FACING_HYSTERESIS:
		return facing
	return DIRECTIONS[posmod(int(round(angle / (PI / 4.0))), 8)]

func animation_name() -> String:
	return ("walk_" if walking else "idle_") + facing

func frame() -> Dictionary:
	var frames: Array = config.get("animations", {}).get(animation_name(), [])
	return frames[clampi(frame_index, 0, frames.size() - 1)] if not frames.is_empty() else {}

func draw_rect(feet: Vector2) -> Rect2:
	var size: Array = config.get("frame_size", [32, 48])
	var anchor: Array = config.get("foot_anchor", [16, 47])
	return Rect2(feet - Vector2(float(anchor[0]), float(anchor[1])) * pixel_scale, Vector2(float(size[0]), float(size[1])) * pixel_scale)

func body_rect(feet: Vector2) -> Rect2:
	var bbox: Array = config.get("alpha_union_bbox", [1, 1, 31, 48])
	return Rect2(draw_rect(feet).position + Vector2(float(bbox[0]), float(bbox[1])) * pixel_scale, Vector2(float(bbox[2] - bbox[0]), float(bbox[3] - bbox[1])) * pixel_scale)

func report() -> Dictionary:
	return {"animation": animation_name(), "frame": frame_index, "walk_phase": walk_phase, "walking": walking, "facing": facing, "pixel_scale": pixel_scale, "asset_loaded": not textures.is_empty(), "gait_driven_by": "actual planar displacement", "foot_anchor": config.get("foot_anchor", [])}
