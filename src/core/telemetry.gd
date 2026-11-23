## BuckdroidTelemetry - original code, part of Buckdroid Roulette. Development / tester diagnostics.
##
## While the game runs, writes one CSV line every INTERVAL seconds: time, scene, frame rate, average and worst frame
## time, GPU and CPU time per frame, the current frame cap, whether idle pacing is active, draw calls (picture and
## shadows), memory, video memory, and any device temperatures the app is allowed to read.
##
## Built to not skew what it measures: per frame it only adds a few numbers (no allocation, no file access); every
## INTERVAL seconds it reads a handful of small system files and appends one line to a file it closes again.
##
## graphics.ini: telemetry = on | off (default off). Files: <config folder>/../telemetry/session_<date>_<time>.csv
## (on Android the app's external files folder, readable over USB).
extends Node

const INTERVAL := 5.0
## Temperature files that apps may be able to read (Android blocks many of these; unreadable ones are skipped).
const TEMP_FILES := {
	"battery": "/sys/class/power_supply/battery/temp",       # tenths of a degree C
}
const ZONE_MAX := 40                                        # thermal_zone0 .. 39
const ZONE_TYPES := ["skin", "batt", "ap", "cpu", "gpu", "soc", "quiet", "xo", "pa"]

var enabled := false
var _path := ""
var _sources: Array = []          # [[label, path, divisor]]
var _frames := 0
var _elapsed := 0.0
var _worst := 0.0
var _gpu_total := 0.0
var _cpu_total := 0.0
var _last_us := 0
var _start_ms := 0


func _ready() -> void:
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	enabled = settings != null and settings.get_value("graphics", "telemetry") == "on"
	if OS.get_cmdline_user_args().has("--bd-telemetry"):
		enabled = true
	if not enabled:
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	var base: String = settings.config_dir.get_base_dir() if settings else "user://"
	var dir := base.path_join("telemetry")
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	_path = dir.path_join("session_%s.csv" % stamp)
	_find_temperature_sources()
	var header := "time,uptime_s,scene,fps,avg_ms,worst_ms,gpu_ms,cpu_ms,fps_cap,idle,draws,shadow_draws,mem_mb,vram_mb"
	for s in _sources:
		header += ",temp_" + s[0]
	_append(header)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_start_ms = Time.get_ticks_msec()
	_last_us = Time.get_ticks_usec()
	print("[buckdroid] telemetry: writing %s, temperature sources: %s" % [_path, _sources.map(func(s): return s[0])])


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	_worst = maxf(_worst, (now - _last_us) / 1000.0)
	_last_us = now
	_frames += 1
	_elapsed += delta
	_gpu_total += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_cpu_total += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	if _elapsed >= INTERVAL:
		_write_line()


func _notification(what: int) -> void:
	# Write what has been gathered when the app goes to the background or closes, so nothing is lost.
	if enabled and (what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST) and _frames > 0:
		_write_line()


func _write_line() -> void:
	var vp := get_viewport().get_viewport_rid()
	var scene := get_tree().current_scene
	var idle_node := get_node_or_null(^"/root/BuckdroidIdlePacing")
	var idle: bool = idle_node != null and bool(idle_node.get("_idle"))
	var fps := _frames / maxf(_elapsed, 0.001)
	var line := "%s,%d,%s,%.1f,%.2f,%.1f,%.2f,%.2f,%d,%d,%d,%d,%d,%d" % [
			Time.get_time_string_from_system(), (Time.get_ticks_msec() - _start_ms) / 1000,
			scene.name if scene else "-", fps, 1000.0 / maxf(fps, 0.001), _worst, _gpu_total / _frames,
			_cpu_total / _frames, Engine.max_fps, int(idle),
			RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
					RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
			RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
					RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
			OS.get_static_memory_usage() / 1048576,
			int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)]
	for s in _sources:
		line += ",%.1f" % _read_temp(s)
	_append(line)
	_frames = 0
	_elapsed = 0.0
	_worst = 0.0
	_gpu_total = 0.0
	_cpu_total = 0.0


func _append(text: String) -> void:
	var f := FileAccess.open(_path, FileAccess.READ_WRITE if FileAccess.file_exists(_path) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(text)
	f.close()


func _find_temperature_sources() -> void:
	for label in TEMP_FILES:
		_try_source(label, TEMP_FILES[label], 10.0)
	for i in ZONE_MAX:
		var zone := "/sys/class/thermal/thermal_zone%d" % i
		var type_text := FileAccess.get_file_as_string(zone + "/type").strip_edges().to_lower()
		if type_text.is_empty():
			continue
		for t in ZONE_TYPES:
			if type_text.begins_with(t):
				_try_source(type_text.replace(" ", "_"), zone + "/temp", 1000.0)
				break


func _try_source(label: String, path: String, divisor: float) -> void:
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if text.is_valid_int():
		var value := int(text) / divisor
		if value > 5.0 and value < 120.0:   # plausible degrees C
			_sources.append([label, path, divisor])


func _read_temp(source: Array) -> float:
	var text := FileAccess.get_file_as_string(source[1]).strip_edges()
	return int(text) / source[2] if text.is_valid_int() else -1.0
