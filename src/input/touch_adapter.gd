## BuckdroidTouch - original code, part of Buckdroid Roulette.
##
## Turns touches into the mouse events the game was written for. Two modes (controls.ini: touch_mode):
##
## direct (default): the game is clicked where the finger touches. The game picks what is under the pointer over two
##   frames (a camera raycast, then the interaction lookup) and only acts on a click if something was already under
##   the pointer, while Godot's built-in touch emulation sends move and press together, so every tap on a 3D object
##   missed. Here the pointer moves first, the press follows HOVER_FRAMES frames later, and the release always
##   follows its press. (input_devices/pointing/emulate_mouse_from_touch is turned off by the installer.)
##
## relative: works like a laptop trackpad. Dragging moves an on-screen cursor (controls.ini: cursor_speed); a quick
##   tap without movement clicks where the cursor is. The cursor is drawn with the game's own cursor images (pointer,
##   hover, invalid) taken from its CursorManager, follows the game's own show/hide state, and switches to the hover
##   image the same way the game's InteractionManager decides it. If those aren't available it uses the project's
##   default cursor image.
##
## Both modes: "press any button" screens. Some game screens continue on any key press that reaches
## _unhandled_input (e.g. the end-of-run stats). A tap becomes a mouse click that the screen's UI overlay consumes,
## so the screen never saw it. While such a screen is waiting, a tap also sends a harmless InputEventAction
## ("buckdroid_any_button") that the UI ignores. Only the screens listed in ANY_BUTTON_SCREENS get it, because other
## screens (the key-rebinding menu) would capture it.
##
## Direct mode: bigger hit areas (controls.ini: tap_assist = on | off, default off). If a tap lands on nothing the
##   game can use, the nearest usable object within ASSIST_RADII is tapped instead, found with the same kind of camera
##   raycast the game uses. Small items and buttons get easier to hit with a finger.
##
## Only the first finger acts as the mouse.
##
## Look around (multiplayer free look): on PC it is the right mouse button held while moving the mouse. Here two fingers
## on the screen hold it (InputEventAction "free look toggle"), and their movement becomes the mouse movement; lifting
## them lets the game turn the camera back as it does on PC. A first finger's tap that has not happened yet is dropped;
## the remaining finger does nothing until all fingers are up. controls.ini look_speed (0.25 - 3, default 1.0).
extends Node

const HOVER_FRAMES := 3            # direct mode: frames between the pointer move and the press (50 ms at 60 fps)
const TAP_SLOP := 8.0              # relative mode: movement (base pixels) below which a touch counts as a tap
const TAP_TIME_MS := 350           # relative mode: longest touch that still counts as a tap
const ANY_BUTTON_ACTION := &"buckdroid_any_button"
## script file -> property that is true while that screen waits for "any button"
const ANY_BUTTON_SCREENS := {"EndingManager.gd": "waitingForInput"}
const CURSOR_HOTSPOTS := {"point": Vector2(12, 0), "hover": Vector2(9, 0), "invalid": Vector2(12, 0)}
const ASSIST_RADII := [10.0, 20.0, 32.0]             # base pixels (the game draws at 960x540)
const ASSIST_DIRECTIONS := 12

var mode := "direct"
var cursor_speed := 1.0           # controls.ini cursor_speed: cursor movement per finger movement (0.25 - 4)
var cursor_size := 1.0            # controls.ini cursor_size: cursor image scale (0.5 - 3)
var tap_assist := false           # controls.ini tap_assist
var look_speed := 1.0             # controls.ini look_speed

const LOOK_ACTION := &"free look toggle"
const LOOK_SCALE := 1.0           # base pixels of finger movement -> game mouse units (the game turns 0.25 degree each); doubled after playtest
var _touching := {}               # finger index -> position
var _look := false
var _look_accum := Vector2.ZERO
var _look_suppress := false       # after a look: ignore the fingers until all are up

var _queue: Array = []             # [{frames_left: int, event: InputEvent}]
var _finger_down := false
var _press_sent := false
var _release_pending: InputEvent = null
var _last_pos := Vector2.ZERO
var _debug := OS.get_cmdline_user_args().has("--bd-touch-debug")
var _overlay_touch := false       # the finger went down on one of our own boxes (BuckdroidChat.consume_tap)

# relative mode
var _cursor := Vector2(480, 270)   # game base coordinates
var _rel_start_ms := 0
var _rel_moved := 0.0

# game nodes found as they enter the tree
var _any_screens: Array[Node] = []
var _cursor_manager: Node = null
var _interaction_manager: Node = null
var _raycast_camera: Camera3D = null  # the game's MouseRaycast camera

# cursor overlay
var _layer: CanvasLayer
var _cursor_rect: TextureRect
var _fallback_texture: Texture2D
var _fallback_hotspot := Vector2.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000       # run before the game's _process so queued events land at the start of a frame
	if not InputMap.has_action(ANY_BUTTON_ACTION):
		InputMap.add_action(ANY_BUTTON_ACTION)
	get_tree().node_added.connect(_on_node_added)
	_build_cursor_overlay()
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings:
		settings.controls_changed.connect(_read_settings)
	_read_settings()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-touch-mode="):
			mode = arg.trim_prefix("--bd-touch-mode=")
	print("[buckdroid] touch mode=%s cursor_speed=%.2f cursor_size=%.2f" % [mode, cursor_speed, cursor_size])


func _read_settings() -> void:
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings == null:
		return
	var m: String = settings.get_value("controls", "touch_mode")
	mode = m if m in ["direct", "relative"] else "direct"
	cursor_speed = clampf(settings.get_float("controls", "cursor_speed", 1.0), 0.25, 4.0)
	cursor_size = clampf(settings.get_float("controls", "cursor_size", 1.0), 0.5, 3.0)
	tap_assist = settings.get_value("controls", "tap_assist") == "on"
	look_speed = clampf(settings.get_float("controls", "look_speed", 1.0), 0.25, 3.0)


# --- input ---------------------------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _debug and (event is InputEventScreenTouch or event is InputEventMouseButton):
		print("[bd-touch] in ", event)
	if (event is InputEventScreenTouch or event is InputEventScreenDrag) and _handle_look(event):
		return
	if mode == "relative":
		_input_relative(event)
	else:
		_input_direct(event)


## Our own boxes (chat, lobby ID entry) take a tap before the game sees it as a click.
func _overlay_tap(pos: Vector2) -> bool:
	var chat := get_node_or_null(^"/root/BuckdroidChat")
	return chat != null and chat.consume_tap(pos)


func _input_direct(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.index == 0 and (_overlay_touch or (event.pressed and _overlay_tap(event.position))):
		_overlay_touch = event.pressed
		return
	if event is InputEventScreenDrag and event.index == 0 and _overlay_touch:
		return
	if event is InputEventScreenTouch and event.index == 0:
		if event.pressed:
			_finger_down = true
			_press_sent = false
			_release_pending = null
			_move_to(event.position)
			_queue.append({"frames_left": HOVER_FRAMES, "event": _button(event.position, true),
					"base_pos": event.position, "assist": tap_assist})
			_notify_any_button()
		elif _finger_down:
			_finger_down = false
			var release := _button(event.position, false)
			if _press_sent:
				_queue.append({"frames_left": 0, "event": release})
			else:
				_release_pending = release
	elif event is InputEventScreenDrag and event.index == 0:
		_move_to(event.position, event.relative, event.velocity)


func _input_relative(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.index == 0:
		if event.pressed:
			_finger_down = true
			_rel_start_ms = Time.get_ticks_msec()
			_rel_moved = 0.0
		elif _finger_down:
			_finger_down = false
			if _rel_moved < TAP_SLOP and Time.get_ticks_msec() - _rel_start_ms <= TAP_TIME_MS:
				if _overlay_tap(_cursor):
					return
				# The cursor has been resting on its target, so the game already knows what is under it.
				_press_sent = false
				_queue.append({"frames_left": 0, "event": _button(_cursor, true)})
				_queue.append({"frames_left": 2, "event": _button(_cursor, false)})
				_notify_any_button()
	elif event is InputEventScreenDrag and event.index == 0:
		_rel_moved += event.relative.length()
		var size := get_viewport().get_visible_rect().size
		_cursor = (_cursor + event.relative * cursor_speed).clamp(Vector2.ZERO, size - Vector2.ONE)
		_move_to(_cursor, event.relative * cursor_speed)


## Two fingers: look around (see header). Returns true when the event belongs to a look and must not act as a tap.
func _handle_look(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touching[event.index] = event.position
			if _touching.size() >= 2 and not _look and not _look_suppress and InputMap.has_action(LOOK_ACTION):
				_start_look()
				return true
		else:
			_touching.erase(event.index)
			if _look:
				_end_look()
				return true
			if _look_suppress:
				if _touching.is_empty():
					_look_suppress = false
				return true
		return _look or _look_suppress
	if event is InputEventScreenDrag:
		_touching[event.index] = event.position
		if _look:
			_look_accum += event.relative / 2.0   # two fingers: their average movement
			return true
		return _look_suppress
	return false


func _start_look() -> void:
	# The first finger's tap must not happen: drop it if it is still waiting, finish it if it was already pressed.
	_queue = _queue.filter(func(item): return not (item.event is InputEventMouseButton))
	if _press_sent and _finger_down:
		_queue.append({"frames_left": 0, "event": _button(_last_pos_base(), false)})
	_finger_down = false
	_release_pending = null
	_look = true
	_look_accum = Vector2.ZERO
	var a := InputEventAction.new()
	a.action = LOOK_ACTION
	a.pressed = true
	Input.parse_input_event(a)


func _end_look() -> void:
	_look = false
	_look_suppress = not _touching.is_empty()
	var a := InputEventAction.new()
	a.action = LOOK_ACTION
	a.pressed = false
	Input.parse_input_event(a)


func _last_pos_base() -> Vector2:
	return get_tree().root.get_final_transform().affine_inverse() * _last_pos


func _process(_delta: float) -> void:
	if _look and _look_accum != Vector2.ZERO:
		# One movement event a frame (the game keeps only the last one it sees before turning the camera).
		var m := InputEventMouseMotion.new()
		m.position = _last_pos
		m.global_position = _last_pos
		m.relative = _look_accum * LOOK_SCALE * look_speed
		_look_accum = Vector2.ZERO
		Input.parse_input_event(m)
	var still: Array = []
	for item in _queue:
		if item.frames_left > 0:
			item.frames_left -= 1
			still.append(item)
			continue
		if item.has("base_pos"):
			var verdict := _check_press(item)
			if verdict == "retry":
				still.append(item)
				continue
		if _debug:
			print("[bd-touch] send ", item.event)
		Input.parse_input_event(item.event)
		if item.event is InputEventMouseButton and item.event.pressed:
			_press_sent = true
			if _release_pending:
				still.append({"frames_left": 1, "event": _release_pending})
				_release_pending = null
	_queue = still
	_update_cursor()


## Events reach _input already in the game's base resolution; Input.parse_input_event expects window pixels.
func _to_window(pos: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * pos


func _move_to(pos: Vector2, relative := Vector2.ZERO, velocity := Vector2.ZERO) -> void:
	pos = _to_window(pos)
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	m.relative = relative if relative != Vector2.ZERO else pos - _last_pos
	m.velocity = velocity
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if (_press_sent and _finger_down and mode == "direct") else 0
	_last_pos = pos
	Input.parse_input_event.call_deferred(m)


func _button(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	pos = _to_window(pos)
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.position = pos
	b.global_position = pos
	b.pressed = pressed
	b.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	return b


# --- bigger hit areas ------------------------------------------------------------------------------------------------

## Decides what to do with a press about to be sent: "send", or "retry" when the pointer was moved to an assisted
## target (the press waits until the game has noticed what is under the pointer).
func _check_press(item: Dictionary) -> String:
	var branch = _hover_branch()
	if branch == null and item.get("assist", false):
		item["assist"] = false
		var target = _find_assist_target(item["base_pos"])
		if target != null:
			_move_to(target)
			item["event"] = _button(target, true)
			item["base_pos"] = target
			item["frames_left"] = HOVER_FRAMES
			if _release_pending:
				_release_pending = _button(target, false)
			return "retry"
	return "send"


## The game's current usable hover target (InteractionBranch), or null.
func _hover_branch():
	if not is_instance_valid(_interaction_manager):
		return null
	var branch = _interaction_manager.get("activeInteractionBranch")
	if branch == null or not is_instance_valid(branch):
		return null
	if branch.get("interactionAllowed") != true or branch.get("interactionInvalid") == true:
		return null
	return branch


## Nearest point around base_pos whose raycast hits an object the game can interact with right now.
func _find_assist_target(base_pos: Vector2):
	if not is_instance_valid(_raycast_camera) or not _raycast_camera.is_inside_tree():
		return null
	if is_instance_valid(_cursor_manager) and _cursor_manager.get("cursor_visible") == false:
		return null
	for r in ASSIST_RADII:
		for k in ASSIST_DIRECTIONS:
			var a := TAU * k / ASSIST_DIRECTIONS
			var p: Vector2 = base_pos + Vector2(cos(a), sin(a)) * r
			if _usable_at(p):
				return p
	return null


func _usable_at(p: Vector2) -> bool:
	var space := _raycast_camera.get_world_3d().direct_space_state
	var from := _raycast_camera.project_ray_origin(p)
	var to := _raycast_camera.project_position(p, 20000)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	if hit.is_empty() or hit.collider == null:
		return false
	var parent: Node = hit.collider.get_parent()
	if parent == null:
		return false
	for c in parent.get_children():
		var sc: Script = c.get_script()
		if sc and sc.resource_path.get_file() == "InteractionBranch.gd":
			return c.get("interactionAllowed") == true and c.get("interactionInvalid") != true
	return false


# --- "press any button" screens ------------------------------------------------------------------------------------

func _on_node_added(node: Node) -> void:
	var s: Script = node.get_script()
	if s == null:
		return
	var file := s.resource_path.get_file()
	if ANY_BUTTON_SCREENS.has(file):
		_any_screens.append(node)
	elif file == "CursorManager.gd":
		_cursor_manager = node
	elif file == "InteractionManager.gd":
		_interaction_manager = node
	elif file == "MouseRaycast.gd":
		_raycast_camera = node


func _notify_any_button() -> void:
	var waiting := false
	var i := 0
	while i < _any_screens.size():
		var n := _any_screens[i]
		if not is_instance_valid(n) or not n.is_inside_tree():
			_any_screens.remove_at(i)
			continue
		if n.get(ANY_BUTTON_SCREENS[n.get_script().resource_path.get_file()]) == true:
			waiting = true
		i += 1
	if not waiting:
		return
	var press := InputEventAction.new()
	press.action = ANY_BUTTON_ACTION
	press.pressed = true
	var release := InputEventAction.new()
	release.action = ANY_BUTTON_ACTION
	release.pressed = false
	_queue.append({"frames_left": 0, "event": press})
	_queue.append({"frames_left": 1, "event": release})
	if _debug:
		print("[bd-touch] any-button screen waiting: sent ", ANY_BUTTON_ACTION)


# --- cursor overlay (relative mode) --------------------------------------------------------------------------------

func _build_cursor_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 128
	add_child(_layer)
	_cursor_rect = TextureRect.new()
	_cursor_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_rect.visible = false
	_layer.add_child(_cursor_rect)
	var path: String = ProjectSettings.get_setting("display/mouse_cursor/custom_image", "")
	if not path.is_empty() and ResourceLoader.exists(path):
		_fallback_texture = load(path)
		_fallback_hotspot = ProjectSettings.get_setting("display/mouse_cursor/custom_image_hotspot", Vector2.ZERO)


func _update_cursor() -> void:
	var show := mode == "relative"
	var state := "point"
	if show and is_instance_valid(_cursor_manager):
		var cv = _cursor_manager.get("cursor_visible")
		if cv != null:
			show = bool(cv)
	if show and is_instance_valid(_interaction_manager):
		var branch = _interaction_manager.get("activeInteractionBranch")
		if branch != null and is_instance_valid(branch) and branch.get("interactionAllowed") == true:
			state = "invalid" if branch.get("interactionInvalid") == true else "hover"
	var tex: Texture2D = null
	var hotspot := Vector2.ZERO
	if is_instance_valid(_cursor_manager):
		tex = _cursor_manager.get("cursor_" + state)
		hotspot = CURSOR_HOTSPOTS[state]
	if tex == null:
		tex = _fallback_texture
		hotspot = _fallback_hotspot
	_cursor_rect.visible = show and tex != null
	if _cursor_rect.visible:
		_cursor_rect.texture = tex
		_cursor_rect.size = tex.get_size()
		_cursor_rect.scale = Vector2.ONE * cursor_size
		_cursor_rect.position = _cursor - hotspot * cursor_size
