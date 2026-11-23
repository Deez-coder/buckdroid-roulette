## BuckdroidIdlePacing - original code, part of Buckdroid Roulette.
##
## Halves the frame rate while nothing on screen is changing, to cut heat. Buckshot Roulette is turn-based: a lot of
## time is spent looking at a still table while deciding. Godot 4.1 redraws every shadow map every frame even when
## nothing moves (measured on the phone: freezing all animations saved no GPU time), so the only way to save that
## work while the picture is still is to draw fewer frames.
##
## Idle = no input and the camera hasn't moved or turned for IDLE_AFTER seconds. Then the cap drops to IDLE_FPS.
## Any input (touch, mouse, controller, key) or camera movement restores the normal cap in the same frame.
## graphics.ini: idle_fps = 30 | 0 (0 turns this off). Off by default everywhere (user decision 2026-11-23).
extends Node

const IDLE_AFTER := 2.0          # seconds without input or camera movement
const CAMERA_EPSILON := 0.0005   # movement (units / radians) per frame that still counts as still

var idle_fps := 0                 # off by default (user decision 2026-11-23); graphics.ini idle_fps = 30 turns it on
var _active_cap := -1            # the normal cap (from BuckdroidRender / settings), restored on activity
var _still_for := 0.0
var _idle := false
var _last_cam_xform := Transform3D()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 2000      # after BuckdroidRender has set the normal cap
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	var v: String = settings.get_value("graphics", "idle_fps") if settings else ""
	if v.is_valid_int():
		idle_fps = int(v)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-idle-fps="):
			idle_fps = int(arg.trim_prefix("--bd-idle-fps="))
	print("[buckdroid] idle pacing: idle_fps=%d after %.1f s" % [idle_fps, IDLE_AFTER])


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.relative.length() < 0.5:
		return
	_wake()


func _process(delta: float) -> void:
	if idle_fps <= 0:
		return
	if _active_cap < 0:
		_active_cap = Engine.max_fps
	var cam := get_viewport().get_camera_3d()
	if cam:
		var x := cam.global_transform
		var moved := x.origin.distance_to(_last_cam_xform.origin) > CAMERA_EPSILON \
				or not x.basis.is_equal_approx(_last_cam_xform.basis)
		_last_cam_xform = x
		if moved:
			_wake()
			return
	_still_for += delta
	if not _idle and _still_for >= IDLE_AFTER:
		_idle = true
		if not _is_test_driver_measuring():
			Engine.max_fps = idle_fps


func _wake() -> void:
	_still_for = 0.0
	if _idle:
		_idle = false
		Engine.max_fps = _active_cap


## The dev test driver sets its own caps for measurements; idle pacing must not interfere with those runs.
func _is_test_driver_measuring() -> bool:
	return get_node_or_null(^"/root/BuckdroidTestDriver") != null and Engine.max_fps == 0
