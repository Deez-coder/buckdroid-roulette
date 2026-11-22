## BuckdroidTouch - original code, part of Buckdroid Roulette.
##
## Turns touches into the mouse events the game was written for, in the order the game needs.
##
## The game picks what is under the pointer over two frames (a camera raycast, then the interaction lookup) and only
## acts on a click if something was already under the pointer. Godot's built-in touch-to-mouse emulation sends the
## pointer move and the button press together, so every tap on a 3D object would miss. This adapter replaces it
## (input_devices/pointing/emulate_mouse_from_touch is set to false by the installer): on touch down it moves the
## pointer, waits HOVER_FRAMES frames, then presses; the release always follows its press. Only the first finger
## acts as the mouse.
extends Node

const HOVER_FRAMES := 3          # frames between the pointer move and the press (3 frames = 50 ms at 60 fps)

var _queue: Array = []           # [{frames_left: int, event: InputEvent}]
var _finger_down := false
var _press_sent := false
var _release_pending: InputEvent = null
var _last_pos := Vector2.ZERO
var _debug := OS.get_cmdline_user_args().has("--bd-touch-debug")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000     # run before the game's _process so queued events land at the start of a frame


func _input(event: InputEvent) -> void:
	if _debug and (event is InputEventScreenTouch or event is InputEventMouseButton):
		print("[bd-touch] in ", event)
	if event is InputEventScreenTouch and event.index == 0:
		if event.pressed:
			_finger_down = true
			_press_sent = false
			_release_pending = null
			_move_to(event.position)
			_queue.append({"frames_left": HOVER_FRAMES, "event": _button(event.position, true)})
		elif _finger_down:
			_finger_down = false
			var release := _button(event.position, false)
			if _press_sent:
				_queue.append({"frames_left": 0, "event": release})
			else:
				_release_pending = release
	elif event is InputEventScreenDrag and event.index == 0:
		_move_to(event.position, event.relative, event.velocity)


func _process(_delta: float) -> void:
	var still: Array = []
	for item in _queue:
		if item.frames_left > 0:
			item.frames_left -= 1
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
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if _press_sent else 0
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
