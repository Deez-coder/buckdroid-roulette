## BuckdroidSettings - original code, part of Buckdroid Roulette.
##
## Reads the port's settings, shared with the launcher. The files follow the launcher UI kit's contract:
## plain "key = value" lines, ';' starts a comment, keys match without regard to case, a missing key means the
## default (both sides must agree on defaults), values are short words or numbers.
##
## Location: <folder of the game data>/config/  (on Android the app's external files folder, where the launcher
## writes; found from the --main-pack argument), falling back to user://config/.
##
##   graphics.ini   shadow_mode = mixed | cube | paraboloid     fps_cap = 60 | 30 | 0 (unlimited)
##   controls.ini   touch_mode = direct | relative   cursor_speed = 1.00 (0.25 - 4)   cursor_size = 1.00 (0.5 - 3)
##   graphics.ini   fps_counter = off | on (performance overlay)
##
## Read once at start; touch settings are read again when controls.ini changes (checked about once a second), so
## the launcher's in-game menu can change them live later.
extends Node

signal controls_changed

const DEFAULTS := {
	"graphics": {"shadow_mode": "", "fps_cap": "", "fps_counter": "off", "idle_fps": "", "telemetry": "off", "transparency_fallback": "", "render_scale": "", "shadow_refresh": "", "shadow_resolution": "", "shadow_softness": "", "mesh_detail": "", "thermal_guard": ""},   # "" = let BuckdroidRender pick the platform default
	"controls": {"touch_mode": "direct", "cursor_speed": "1.00", "cursor_size": "1.00", "tap_assist": "off"},
}

var config_dir := "user://config"
var _values := {}                  # file -> {key: value}
var _controls_mtime := 0
var _check_timer := 0.0


func _ready() -> void:
	# Godot removes --main-pack from the arguments scripts see, so the folder is worked out per platform.
	# Android: the app's external files folder, /storage/emulated/0/Android/data/<package>/files, where the game data
	# and the launcher's config live. The package name is the second-to-last part of the internal user data path
	# (/data/user/0/<package>/files).
	if OS.get_name() == "Android":
		var parts := OS.get_user_data_dir().split("/", false)
		if parts.size() >= 2:
			var external := "/storage/emulated/0/Android/data/%s/files" % parts[parts.size() - 2]
			if DirAccess.dir_exists_absolute(external):
				config_dir = external.path_join("config")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-config-dir="):
			config_dir = arg.trim_prefix("--bd-config-dir=")
	_write_defaults_if_missing()
	for file in DEFAULTS:
		_load(file)
	_apply_engine_settings()
	_controls_mtime = FileAccess.get_modified_time(_path("controls"))
	print("[buckdroid] settings from %s: %s" % [config_dir, _values])


# Settings the engine reads once when it first draws a shadow, so they must be set here, before the first frame.
func _apply_engine_settings() -> void:
	var refresh := get_value("graphics", "shadow_refresh")
	if refresh.is_valid_int():
		var n := clampi(int(refresh), 1, 8)
		ProjectSettings.set_setting("rendering/lights_and_shadows/positional_shadow/buckdroid_cube_update_interval", n)
		ProjectSettings.set_setting("rendering/lights_and_shadows/positional_shadow/buckdroid_paraboloid_update_interval", n)
		print("[buckdroid] shadow refresh: lights redraw moving shadows every %d frame(s)" % n)


func get_value(file: String, key: String) -> String:
	var v: String = _values.get(file, {}).get(key.to_lower(), "")
	return v if not v.is_empty() else DEFAULTS.get(file, {}).get(key, "")


func get_float(file: String, key: String, fallback: float) -> float:
	var v := get_value(file, key)
	return float(v) if v.is_valid_float() else fallback


func _process(delta: float) -> void:
	_check_timer += delta
	if _check_timer < 1.0:
		return
	_check_timer = 0.0
	var m := FileAccess.get_modified_time(_path("controls"))
	if m != _controls_mtime:
		_controls_mtime = m
		_load("controls")
		controls_changed.emit()


## The game creates the folder and files itself, so they belong to the app (a folder made from outside, e.g. over
## adb, can be unreadable for the app). Each key gets a line of explanation, as the UI kit expects; the launcher
## later changes values on their own lines and keeps the comments.
const DEFAULT_FILES := {
	"graphics": """; Buckdroid Roulette - graphics settings. A missing key means the default.
; Shadow quality: cube = exact original shadows (heaviest), mixed = weak fill lights use cheaper shadows,
; paraboloid = all lights use cheaper shadows (fastest, shading on faces changes). Empty = automatic.
shadow_mode =
; Frame rate limit: 60, 30 or 0 (no limit). Empty = automatic (60 on phones).
fps_cap =
; Performance overlay in the top-left corner: on or off.
fps_counter = off
; Frame rate while nothing on screen changes (no input, camera still for 2 s): 30, or 0 to turn this off.
; Saves heat and battery while you think; any touch or camera movement restores full speed at once. Empty = automatic.
idle_fps =
; 3D resolution, from 0.5 to 1.0 (1.0 = full). Lower is cooler and faster but softer; menus and text stay sharp.
render_scale = 1.0
; How often lights redraw moving shadows: 1 = every frame (original, default), 2 or 3 = every 2nd/3rd frame.
; 3 saves about 12% GPU load (cooler phone) but moving shadows visibly lag and lifted items can flash dark.
shadow_refresh =
; Shadow map size: 4096 (original), 2048 or 1024. Smaller saves a little GPU work; shadow edges get slightly coarser.
shadow_resolution =
; Shadow edge softness: 0 (hard) to 5 (softest); empty = original (2). 0 saves about 11% GPU load but edges look harder.
shadow_softness =
; Mesh detail: 1.0 (original). Higher (e.g. 2.0) uses simpler versions of small or distant objects; saves a few percent.
mesh_detail =
; Heat guard: when Android reports the phone is about to throttle, lower the 3D resolution a step (back up once it
; cools). Normal play is unaffected. on (default) or off.
thermal_guard =
; Fallback that hides fading objects on renderers that ignore their fade: auto, on or off.
transparency_fallback = auto
; Diagnostics for testers: write performance and temperature logs to the telemetry folder (on or off).
telemetry = off
""",
	"controls": """; Buckdroid Roulette - touch settings. A missing key means the default.
; direct = tap where you want to click; relative = drag to move a cursor like a trackpad, tap to click;
; pad = on-screen buttons (D-pad, A, B, menu) over the game, tapping the game is off.
touch_mode = direct
; Cursor movement per finger movement in relative mode (0.25 - 4).
cursor_speed = 1.00
; Cursor size in relative mode (0.5 - 3).
cursor_size = 1.00
; Direct mode: a tap that misses goes to the nearest object you can use (easier to hit small items). on or off.
tap_assist = off
; pad mode: the buttons' opacity (0.1 - 1) and size (0.6 - 1.6); pos_<button> = x y size lines come from the layout editor.
touch_opacity = 0.45
touch_scale = 1.00
""",
}


func _write_defaults_if_missing() -> void:
	DirAccess.make_dir_recursive_absolute(config_dir)
	for file in DEFAULT_FILES:
		if FileAccess.file_exists(_path(file)):
			continue
		var f := FileAccess.open(_path(file), FileAccess.WRITE)
		if f:
			f.store_string(DEFAULT_FILES[file])


func _path(file: String) -> String:
	return config_dir.path_join(file + ".ini")


func _load(file: String) -> void:
	var out := {}
	var text := FileAccess.get_file_as_string(_path(file))   # missing file: empty, every key at its default
	for raw in text.split("\n"):
		var line := raw.split(";")[0].strip_edges()
		var eq := line.find("=")
		if eq <= 0:
			continue
		out[line.substr(0, eq).strip_edges().to_lower()] = line.substr(eq + 1).strip_edges().to_lower()
	_values[file] = out
