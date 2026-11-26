## BuckdroidBack - original code, part of Buckdroid Roulette.
##
## Android back button / back gesture, and an on-screen MENU button (a house at the top left) that does the same in the
## Tap and Trackpad touch modes (Buttons mode has its own MENU button on the pad, which also lands here).
## Android's default (close the app at once) is switched off by the installer (application/config/quit_on_go_back =
## false). Instead:
##   - in the main menu: press back twice within BACK_WINDOW seconds to quit;
##   - in the multiplayer lobby: press back twice to leave to the main menu, through the game's own "return to main
##     menu" (MP_LobbyUI.ExitToMainMenu, which also leaves the lobby);
##   - in a multiplayer match: back opens (and closes) the game's in-game menu, as Escape does on the PC; its
##     "disconnect" button and confirmation leave the match. The multiplayer scenes react to the "exit game" key
##     press as an input event, so one is sent (holding the action, as below, did nothing there: tester report);
##   - anywhere else (single player): press back twice to leave to the main menu, using the game's own "hold to exit"
##     action, which a gesture cannot hold, so the hold is performed for the player.
## A hint tells the player what the second press will do.
extends Node

const BACK_WINDOW := 2.5           # seconds within which the second press counts
const MENU_SCENE := "res://scenes/menu.tscn"
const LOBBY_SCENE := "res://multiplayer/scenes/mp_lobby.tscn"
const MATCH_SCENE := "res://multiplayer/scenes/mp_main.tscn"
const EXIT_ACTION := &"exit game"  # the game's hold-to-exit action
const EXIT_HOLD := 2.4             # the game needs a little over 2 s of holding

var _armed_ms := -100000
var _layer: CanvasLayer
var _button: Button
var _pad_mode := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	_pad_mode = settings != null and settings.get_value("controls", "touch_mode") == "pad"
	if OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--bd-menu-button"):
		_build_menu_button.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()


func _on_back() -> void:
	var scene := get_tree().current_scene
	var path: String = scene.scene_file_path if scene else ""
	var toast := get_node_or_null(^"/root/BuckdroidToast")
	if path == MATCH_SCENE:
		_armed_ms = -100000
		_send_exit_press()             # the game's in-game menu
		return
	var in_menu := path == MENU_SCENE
	var now := Time.get_ticks_msec()
	if now - _armed_ms > int(BACK_WINDOW * 1000.0):
		_armed_ms = now
		if toast:
			toast.show_text("Press back again to quit" if in_menu else "Press back again to leave to the menu", BACK_WINDOW)
		return
	_armed_ms = -100000
	if toast:
		toast.hide_text()
	if in_menu:
		get_tree().quit()
	elif path == LOBBY_SCENE:
		var ui := _find_by_script(scene, "MP_LobbyUI.gd")
		if ui and ui.has_method(&"ExitToMainMenu"):
			ui.ExitToMainMenu()
		else:
			_send_exit_press()
	elif InputMap.has_action(EXIT_ACTION):
		Input.action_press(EXIT_ACTION)
		await get_tree().create_timer(EXIT_HOLD, true, false, true).timeout
		Input.action_release(EXIT_ACTION)


## A press and release of the game's "exit game" key as input events (the multiplayer scripts read events, not the
## held state).
func _send_exit_press() -> void:
	if not InputMap.has_action(EXIT_ACTION):
		return
	var a := InputEventAction.new()
	a.action = EXIT_ACTION
	a.pressed = true
	Input.parse_input_event(a)
	var r := InputEventAction.new()
	r.action = EXIT_ACTION
	r.pressed = false
	Input.parse_input_event.call_deferred(r)


static func _find_by_script(n: Node, file: String) -> Node:
	if n == null:
		return null
	var sc: Script = n.get_script()
	if sc and sc.resource_path.get_file() == file:
		return n
	for c in n.get_children():
		var r := _find_by_script(c, file)
		if r:
			return r
	return null


# --- the on-screen MENU button (Tap and Trackpad modes) ---------------------------------------------------------------
# (user request: a quit button in every control mode.) Same place and look as the pad's MENU button: a house in a
# translucent circle at the top left. Taps reach it through BuckdroidChat's overlay routing, so they never also click
# the game behind it.
func _build_menu_button() -> void:
	if _pad_mode:
		return                          # the pad has its own MENU button
	_layer = CanvasLayer.new()
	_layer.layer = 56
	add_child(_layer)
	_button = Button.new()
	_button.flat = true
	_button.focus_mode = Control.FOCUS_NONE
	_button.position = Vector2(22, 22)
	_button.size = Vector2(52, 52)
	_button.pressed.connect(_on_back)
	_button.draw.connect(_draw_house)
	_layer.add_child(_button)
	var chat := get_node_or_null(^"/root/BuckdroidChat")
	if chat:
		chat.register(_button)


func _draw_house() -> void:
	var c := _button.size / 2.0
	_button.draw_circle(c, 25.0, Color(0, 0, 0, 0.35))
	_button.draw_arc(c, 25.0, 0.0, TAU, 40, Color(1, 1, 1, 0.55), 2.0, true)
	var w := Color(1, 1, 1, 0.8)
	var roof := PackedVector2Array([c + Vector2(-13, -1), c + Vector2(0, -13), c + Vector2(13, -1)])
	_button.draw_polyline(roof, w, 2.5, true)
	_button.draw_rect(Rect2(c + Vector2(-9, -1), Vector2(18, 13)), w, false, 2.5)
	_button.draw_rect(Rect2(c + Vector2(-3, 5), Vector2(6, 7)), w, true)

