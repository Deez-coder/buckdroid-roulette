## BuckdroidBack - original code, part of Buckdroid Roulette.
##
## Android back button / back gesture. Android's default (close the app at once) is switched off by the installer
## (application/config/quit_on_go_back = false). Instead:
##   - in the main menu: press back twice within BACK_WINDOW seconds to quit;
##   - anywhere else: press back twice to leave to the main menu, using the game's own "hold to exit" action, which
##     a gesture cannot hold, so the hold is performed for the player.
## A hint tells the player what the second press will do.
extends Node

const BACK_WINDOW := 2.5           # seconds within which the second press counts
const MENU_SCENE := "res://scenes/menu.tscn"
const EXIT_ACTION := &"exit game"  # the game's hold-to-exit action
const EXIT_HOLD := 2.4             # the game needs a little over 2 s of holding

var _armed_ms := -100000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()


func _on_back() -> void:
	var scene := get_tree().current_scene
	var in_menu := scene != null and scene.scene_file_path == MENU_SCENE
	var now := Time.get_ticks_msec()
	var toast := get_node_or_null(^"/root/BuckdroidToast")
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
	elif InputMap.has_action(EXIT_ACTION):
		Input.action_press(EXIT_ACTION)
		await get_tree().create_timer(EXIT_HOLD, true, false, true).timeout
		Input.action_release(EXIT_ACTION)
