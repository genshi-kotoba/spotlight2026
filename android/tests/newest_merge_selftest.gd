extends Node
const Batch = preload("res://systems/map/relief_2d/vector_batch.gd")
const Steam = preload("res://systems/map/relief_2d/elite_steam.gd")
const Integration = preload("res://autoload/audio_integration.gd")
const LOG = preload("res://systems/diagnostics/runtime_log.gd")
var failures := 0
var checks := 0

class AudioProbe extends Node:
	var is_ready := true
	var default_game_object: Node = self
	var posts: Array[String] = []
	var stops: Array = []
	var parameters: Dictionary = {}
	func play(event: String) -> int:
		posts.append(event)
		return posts.size()
	func stop_event(id: int, fade: int = 200) -> void:
		stops.append([id, fade])
	func set_rtpc(key: String, value: float, _target: Node = null) -> bool:
		parameters[key] = value
		return true
	func set_state(_group: String, _value: String) -> bool:
		return true

func check(label: String, ok: bool) -> void:
	checks += 1
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures += 1

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/relief_2d/exploration.json"))
	check("floor one gains one elite and floor three keeps two", int(config.floors[0].elite) == 1 and int(config.floors[2].elite) == 2)
	var generator := preload("res://systems/map/flat_2d/planar_map_generator.gd").new()
	var old: Dictionary = config.floors[0].duplicate(true)
	old.elite = 0
	check("old floor-one config still accepted", not generator.normalize_config(old).is_empty())
	check("new floor-one config accepted", not generator.normalize_config(config.floors[0]).is_empty())
	check("release/editor save separation retained", GlobalStateMachine.default_save_path() == (GlobalStateMachine.DEFAULT_SAVE_PATH if OS.has_feature("editor") else GlobalStateMachine.RELEASE_SAVE_PATH))
	check("runtime diagnostics installed", FileAccess.file_exists(LOG.current_path()))
	for platform: String in ["Windows", "Android"]:
		var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://wwise_soundbanks/" + platform + "/Music.json"))
		var names: Array = metadata.SoundBanksInfo.SoundBanks[0].Events.map(func(event: Dictionary): return event.Name)
		check(platform + " music banks carry both region blend events", "mus_alchemy" in names and "mus_church" in names)
		check(platform + " music media are embedded", metadata.SoundBanksInfo.SoundBanks[0].Media.all(func(media: Dictionary): return media.Streaming == "false" and media.Location == "Memory"))
		var init: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://wwise_soundbanks/" + platform + "/Init.json"))
		check(platform + " music crossfade RTPC present", JSON.stringify(init).contains("Music_Combat"))
	var marker := {"node_marker":true, "rect":Rect2(100,100,90,120), "visual":{"type":"elite", "completed":false}, "elite_steam":true, "tint":Color.WHITE}
	check("elite marker steam eligible", Steam.is_active(marker))
	check("steam bounds cover marker", Steam.bounds(marker.rect).encloses(marker.rect))
	var completed := marker.duplicate(true)
	completed.visual.completed = true
	check("completed elite has no steam", not Steam.is_active(completed))
	var batch := Batch.new()
	add_child(batch)
	batch.commands = [marker]
	batch._refresh_elite_steam()
	batch.queue_redraw()
	await _frames(8)
	check("visible elite animates", batch.elite_steam_stats().eligible == 1 and batch.is_processing())
	batch.hide()
	await _frames(3)
	check("hidden cached elite stops processing", not batch.is_processing())
	batch.show()
	await _frames(8)
	check("shown elite resumes processing", batch.is_processing())
	batch.position = Vector2(100000,100000)
	await _frames(8)
	check("offscreen elite stops processing", not batch.is_processing())
	batch.clear()
	check("empty batch releases steam notifier", batch._elite_steam_notifier == null and not batch.is_processing())
	batch.queue_free()
	var integration := Integration.new()
	add_child(integration)
	var probe := AudioProbe.new()
	add_child(probe)
	integration._audio = probe
	integration._scene_transition = null
	integration._set_music_mode(false, "Workshop")
	check("workshop starts blend event once", probe.posts == ["mus_alchemy"])
	integration._set_music_mode(true, "Workshop")
	await get_tree().create_timer(2.7).timeout
	check("battle crossfade reaches100 without restarting song", probe.posts.size() == 1 and is_equal_approx(float(probe.parameters.Music_Combat), 100.0))
	integration._set_music_mode(false, "Church")
	check("region change starts church music and fades prior event", probe.posts == ["mus_alchemy", "mus_church"] and probe.stops[0][1] == 4000 and is_zero_approx(float(probe.parameters.Music_Combat)))
	integration.queue_free()
	probe.queue_free()
	print("NEWEST_MERGE_RESULT checks=%d failures=%d" % [checks, failures])
	get_tree().quit(failures)

func _frames(count: int) -> void:
	for index in count: await get_tree().process_frame
