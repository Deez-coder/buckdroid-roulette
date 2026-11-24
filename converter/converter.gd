## Buckdroid Roulette converter - turns the player's own copy of Buckshot Roulette into the pack the phone runs.
## Original code, GPL-3.0-or-later. On-device counterpart of tools/build_patched_pck.py (--android, target 4.6).
##
## Started by the launcher as our Godot engine with this converter as the main pack and user arguments:
##   --source=<game .exe or .pck>   --out=<game.pck to write>   [--status=<json file the launcher reads>]
## Steps: identify the version (patches/versions.json), check the file hash, patch project.binary (our autoloads first,
## Android overrides), add the Buckdroid scripts, adapt for Godot 4.6, convert every S3TC texture to ETC2, write the
## pack. Everything stays on the phone. The converter package itself contains only this project's own code.
extends Control

const PckScript := preload("res://converter/pck.gd")
const EcfgScript := preload("res://converter/ecfg.gd")
const Tex := preload("res://converter/textures.gd")

const PAYLOAD := "res://payload/buckdroid"   # our game-side scripts, mapped to res://buckdroid/ in the game pack
const RES_PREFIX := "res://buckdroid/"
const BG := Color("#101318")
const CARD := Color("#1B2029")
const BLUE := Color("#3B82F6")
const GREY := Color("#9AA3B2")

var source_path := ""
var out_path := ""
var status_path := ""

# shared with the worker thread
var _phase := "Starting"
var _detail := ""
var _fraction := 0.0
var _state := "running"    # running | done | error
var _message := ""
var _thread: Thread
var _mutex := Mutex.new()

var _title: Label
var _phase_label: Label
var _detail_label: Label
var _bar: ProgressBar
var _status_timer := 0.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--source="):
			source_path = arg.trim_prefix("--source=")
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
		elif arg.begins_with("--status="):
			status_path = arg.trim_prefix("--status=")
	_build_ui()
	if source_path.is_empty() or out_path.is_empty():
		_fail("Missing --source or --out.")
		return
	_thread = Thread.new()
	_thread.start(_run)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(720, 0)
	box.position = Vector2(-360, -120)
	box.add_theme_constant_override(&"separation", 14)
	add_child(box)
	_title = Label.new()
	_title.text = "Preparing Buckshot Roulette"
	_title.add_theme_font_size_override(&"font_size", 34)
	box.add_child(_title)
	_phase_label = Label.new()
	_phase_label.add_theme_font_size_override(&"font_size", 22)
	_phase_label.add_theme_color_override(&"font_color", BLUE)
	box.add_child(_phase_label)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(720, 18)
	_bar.max_value = 1.0
	_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = BLUE
	fill.set_corner_radius_all(8)
	var back := StyleBoxFlat.new()
	back.bg_color = CARD
	back.set_corner_radius_all(8)
	_bar.add_theme_stylebox_override(&"fill", fill)
	_bar.add_theme_stylebox_override(&"background", back)
	box.add_child(_bar)
	_detail_label = Label.new()
	_detail_label.add_theme_color_override(&"font_color", GREY)
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_label.custom_minimum_size = Vector2(720, 0)
	box.add_child(_detail_label)
	var note := Label.new()
	note.text = "Everything stays on this phone. This takes a few minutes; keep the app open."
	note.add_theme_color_override(&"font_color", GREY)
	box.add_child(note)


func _process(delta: float) -> void:
	_mutex.lock()
	_phase_label.text = _phase
	_detail_label.text = _message if _state == "error" else _detail
	_bar.value = _fraction
	var state := _state
	_mutex.unlock()
	_status_timer += delta
	if _status_timer > 0.5:
		_status_timer = 0.0
		_write_status()
	if state != "running" and _thread and not _thread.is_alive():
		_thread.wait_to_finish()
		_thread = null
		_write_status()
		if state == "done":
			_phase_label.text = "Done"
			await get_tree().create_timer(1.0).timeout
			get_tree().quit(0)
		else:
			_title.text = "Could not prepare the game"
			_title.add_theme_color_override(&"font_color", Color("#E5393B"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _state != "running":
			get_tree().quit(1)


func _set_progress(phase: String, detail := "", fraction := -1.0) -> void:
	_mutex.lock()
	_phase = phase
	_detail = detail
	if fraction >= 0.0:
		_fraction = fraction
	_mutex.unlock()


func _fail(msg: String) -> void:
	_mutex.lock()
	_state = "error"
	_message = msg
	_mutex.unlock()
	printerr("[converter] ", msg)


func _write_status() -> void:
	if status_path.is_empty():
		return
	_mutex.lock()
	var d := {"state": _state, "phase": _phase, "detail": _detail, "fraction": _fraction, "message": _message}
	_mutex.unlock()
	var f := FileAccess.open(status_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


# --- the work (runs on a thread) ---------------------------------------------------------------------------------------

func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var versions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://payload/versions.json"))
	var autoloads: Array = JSON.parse_string(FileAccess.get_file_as_string("res://payload/autoloads.json"))["autoloads"]

	_set_progress("Checking the game file", source_path.get_file(), 0.0)
	var src = PckScript.new()
	src.open_path(source_path)
	if not src.error.is_empty():
		_fail("This file is not Buckshot Roulette: " + src.error + ".")
		return
	var ver: Dictionary = _identify(src, versions)
	if ver.is_empty():
		_fail("This version of Buckshot Roulette is not supported yet. Supported: %s." %
				", ".join(versions["supported"].map(func(v): return v["name"])))
		return
	if src.start > 0:
		var file_len: int = src.f.get_length()
		if int(ver.get("exe_size", 0)) != 0 and file_len != int(ver["exe_size"]):
			_fail("The game file is incomplete or changed (size %d, expected %d). Copy it again." % [file_len, ver["exe_size"]])
			return
		_set_progress("Checking the game file", "Verifying %s (this takes a moment)" % ver["name"], 0.02)
		var sha: String = FileAccess.get_sha256(source_path)
		if sha != ver["exe_sha256"]:
			_fail("The game file does not match the original %s. Copy it again from your Steam folder." % ver["name"])
			return

	_set_progress("Patching", ver["name"], 0.08)
	var replaced := {}   # res path -> PackedByteArray
	var pb = EcfgScript.new()
	pb.load_bytes(src.read("res://project.binary"))
	if not pb.error.is_empty():
		_fail("The game's settings could not be read.")
		return
	var first_game_autoload := ""
	for k in pb.keys():
		if k.begins_with("autoload/"):
			first_game_autoload = k
			break
	for a in autoloads:
		pb.insert_before(first_game_autoload, "autoload/" + a["name"], "*" + RES_PREFIX + a["script"])
	var overrides: Dictionary = versions["overrides"]["common"].duplicate()
	overrides.merge(versions["overrides"]["android"], true)
	for k in overrides:
		pb.set_value(k, _json_value(overrides[k]))
	replaced["res://project.binary"] = pb.to_bytes()

	# Godot 4.6 adaptations (see tools/build_patched_pck.py)
	var cache_key := "res://.godot/global_script_class_cache.cfg"
	var cache: String = src.read(cache_key).get_string_from_utf8()
	cache = cache.replace("\"icon\": \"\",", "\"icon\": \"\",\n\"is_abstract\": false,\n\"is_tool\": false,")
	replaced[cache_key] = cache.to_utf8_buffer()
	var mp_key := "res://multiplayer/scripts/user scripts/MP_ItemResource_User.gd"
	if src.has(mp_key):
		var mp: String = src.read(mp_key).get_string_from_utf8()
		for side in ["R", "L"]:
			for part in ["hand", "mesh"]:
				mp = mp.replace("@export var %s_assigned_%s : Node3D" % [side, part], "var %s_assigned_%s : Node3D" % [side, part])
		replaced[mp_key] = mp.to_utf8_buffer()

	# Textures
	var jobs := []   # [import path, s3tc path]
	for e in src.entries:
		if e.path.ends_with(".import"):
			var target: String = Tex.s3tc_target(src.read(e.path).get_string_from_utf8())
			if not target.is_empty() and src.has(target):
				jobs.append([e.path, target])
	var threads := clampi(OS.get_processor_count() - 2, 1, 6)
	var batch_size := threads * 2
	var done := 0
	var failed := 0
	var i := 0
	while i < jobs.size():
		var batch := jobs.slice(i, i + batch_size)
		var inputs := []
		for job in batch:
			inputs.append(src.read(job[1]))
		# One result holder per texture, so worker threads never write to the same container.
		var outputs := []
		for k in inputs.size():
			outputs.append([])
		var task := WorkerThreadPool.add_group_task(func(k: int): outputs[k].append(Tex.to_etc2(inputs[k])),
				inputs.size(), threads, true)
		WorkerThreadPool.wait_for_group_task_completion(task)
		for k in batch.size():
			var out: PackedByteArray = outputs[k][0] if not outputs[k].is_empty() else PackedByteArray()
			if out.is_empty():
				failed += 1
				continue
			replaced[batch[k][1]] = out
			var remap: PackedByteArray = Tex.add_etc2_remap(src.read(batch[k][0]).get_string_from_utf8(), batch[k][1]).to_utf8_buffer()
			remap.append(0)
			replaced[batch[k][0]] = remap
			done += 1
		i += batch.size()
		_set_progress("Converting textures for the phone", "%d of %d" % [i, jobs.size()], 0.1 + 0.6 * float(i) / jobs.size())
	if failed > 0:
		_fail("%d textures could not be converted." % failed)
		return

	# Our scripts
	var ours := {}
	_collect_payload(PAYLOAD, ours)

	# Write
	var items := []
	for e in src.entries:
		if replaced.has(e.path):
			var data: PackedByteArray = replaced[e.path]
			items.append({"path": e.path, "size": data.size(), "data": data})
		elif not ours.has(e.path):
			items.append({"path": e.path, "size": e.size, "entry": e, "source": "game"})
	for p in ours:
		items.append({"path": p, "size": ours[p].size(), "data": ours[p]})
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var progress := func(n: int, total: int):
		if n % 50 == 0 or n == total:
			_set_progress("Writing the game data", "%d of %d files" % [n, total], 0.7 + 0.3 * float(n) / total)
	var err: String = PckScript.write(out_path, src.engine, items, {"game": src}, progress)
	if not err.is_empty():
		_fail("Writing failed: " + err + ". Is there enough free space?")
		return
	print("[converter] done: %d textures, %d files, %.0f s" % [done, items.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	_set_progress("Done", "%s is ready (%d textures converted)." % [ver["name"], done], 1.0)
	_mutex.lock()
	_state = "done"
	_mutex.unlock()


func _identify(src, versions: Dictionary) -> Dictionary:
	if not src.has("res://project.binary"):
		return {}
	var engine: String = "%d.%d.%d" % src.engine
	var md5: String = src.by_path["res://project.binary"].md5.hex_encode()
	for v in versions["supported"]:
		if v["engine"] == engine and v["project_binary_md5"] == md5:
			return v
	return {}


func _json_value(v):
	# JSON numbers arrive as floats; settings that were whole numbers in versions.json are ints.
	if typeof(v) == TYPE_FLOAT and is_equal_approx(v, round(v)):
		return int(v)
	return v


func _collect_payload(dir: String, ours: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_collect_payload(dir.path_join(sub), ours)
	for fn in d.get_files():
		var full := dir.path_join(fn)
		var rel := full.trim_prefix(PAYLOAD + "/")
		ours[RES_PREFIX + rel] = FileAccess.get_file_as_bytes(full)
