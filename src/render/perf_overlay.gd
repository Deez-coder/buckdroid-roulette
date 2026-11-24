## BuckdroidPerfOverlay - original code, part of Buckdroid Roulette.
##
## A small performance panel in the top-left corner: frame rate, frame time (average and worst over the last
## half second), GPU time per frame, memory, video memory, and the active renderer / shadow mode / fps cap.
## graphics.ini: fps_counter = on | off (default off). "--bd-perf-overlay" turns it on for testing.
extends CanvasLayer

const UPDATE_EVERY := 0.5         # seconds

var _label: Label
var _panel: PanelContainer
var _frames := 0
var _worst := 0.0
var _gpu_total := 0.0
var _elapsed := 0.0
var _last_us := 0


func _ready() -> void:
	layer = 127
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	var on: bool = settings != null and settings.get_value("graphics", "fps_counter") == "on"
	if OS.get_cmdline_user_args().has("--bd-perf-overlay"):
		on = true
	if not on:
		set_process(false)
		return
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.55)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	_panel.add_theme_stylebox_override(&"panel", style)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.position = Vector2(4, 4)
	_label = Label.new()
	_label.add_theme_font_size_override(&"font_size", 9)
	_label.add_theme_color_override(&"font_color", Color(0.8, 1.0, 0.8))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)
	add_child(_panel)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_last_us = Time.get_ticks_usec()


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	_worst = maxf(_worst, (now - _last_us) / 1000.0)
	_last_us = now
	_frames += 1
	_elapsed += delta
	_gpu_total += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	if _elapsed < UPDATE_EVERY:
		return
	var fps := _frames / _elapsed
	var render := get_node_or_null(^"/root/BuckdroidRender")
	var shadow_mode: String = render.shadow_mode if render else "?"
	_label.text = "%d fps  %.1f ms (worst %.1f)\nGPU %.1f ms\nRAM %d MB  VRAM %d MB\n%s / %s shadows / cap %s" % [
			roundi(fps), 1000.0 / maxf(fps, 0.001), _worst, _gpu_total / _frames,
			OS.get_static_memory_usage() / 1048576,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			ProjectSettings.get_setting("rendering/renderer/rendering_method"), shadow_mode,
			str(Engine.max_fps) if Engine.max_fps > 0 else "off"]
	var thermal := get_node_or_null(^"/root/BuckdroidThermal")
	if thermal and thermal.headroom >= 0.0:
		# Android's thermal headroom: 1.0 = about to throttle. 3D scale shows when the heat guard eased it.
		_label.text += "
heat %.2f  status %d  3D %.0f%%" % [thermal.headroom, thermal.status,
				get_tree().root.scaling_3d_scale * 100.0]
	_frames = 0
	_worst = 0.0
	_gpu_total = 0.0
	_elapsed = 0.0
