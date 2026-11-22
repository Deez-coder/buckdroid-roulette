## BuckdroidBoot - original code, part of Buckdroid Roulette.
##
## Runs before the game's own autoloads and watches every scene the game enters, so platform changes can be made
## from outside the game's scripts. Today it does one thing:
##   - multiplayer is unavailable in this port: the main menu's Multiplayer button is greyed out, cannot be pressed
##     or focused, and says "Coming soon". (The game's multiplayer needs Steam lobbies; see docs/MULTIPLAYER_NOTES.md.)
## The game keeps running as its Steam edition (GlobalVariables.using_steam stays true); the Steam stub answers.
extends Node

const MENU_SCENE := "res://scenes/menu.tscn"
const MULTIPLAYER_BUTTON := "button_multiplayer"              # Control in the menu scene
const MULTIPLAYER_BUTTON_LOGIC := "button class_multiplayer"  # its ButtonClass child
const COMING_SOON := "COMING SOON"

var _scene: Node


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	if scene != _scene:
		_scene = scene
		if scene:
			_on_scene_changed.call_deferred(scene)


func _on_scene_changed(scene: Node) -> void:
	if not is_instance_valid(scene):
		return
	if scene.scene_file_path == MENU_SCENE:
		_disable_multiplayer_button(scene)


func _disable_multiplayer_button(scene: Node) -> void:
	var button := scene.find_child(MULTIPLAYER_BUTTON, true, false) as Control
	if button == null:
		push_warning("Buckdroid: multiplayer button not found; the menu layout may have changed")
		return
	var logic := button.find_child(MULTIPLAYER_BUTTON_LOGIC, true, false)
	if logic:
		for c in logic.get_signal_connection_list(&"is_pressed"):
			logic.disconnect(&"is_pressed", c.callable)
		logic.set("isActive", false)
	button.modulate = Color(1, 1, 1, 0.35)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if button is BaseButton:
		button.disabled = true
	if button.has_node("BuckdroidComingSoon"):
		return
	# A small note to the right of the (centred) button text, in the button's own font.
	var font := button.get_theme_font(&"font")
	var font_size := button.get_theme_font_size(&"font_size")
	var text_width := 0.0
	if "text" in button and font:
		text_width = font.get_string_size(tr(button.text), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var note := Label.new()
	note.name = "BuckdroidComingSoon"
	note.text = COMING_SOON
	if font:
		note.add_theme_font_override(&"font", font)
	note.add_theme_font_size_override(&"font_size", maxi(8, font_size / 2))
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.size = Vector2(200, button.size.y)
	note.position = Vector2(button.size.x / 2.0 + text_width / 2.0 + 6.0, 0)
	button.add_child(note)
