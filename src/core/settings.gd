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
	"graphics": {"shadow_mode": "", "fps_cap": "", "fps_counter": "off"},   # "" = let BuckdroidRender pick the platform default
	"controls": {"touch_mode": "direct", "cursor_speed": "1.00", "cursor_size": "1.00"},
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
	for file in DEFAULTS:
		_load(file)
	_controls_mtime = FileAccess.get_modified_time(_path("controls"))
	print("[buckdroid] settings from %s: %s" % [config_dir, _values])


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
