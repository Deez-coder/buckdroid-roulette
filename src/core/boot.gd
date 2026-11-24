## BuckdroidBoot - original code, part of Buckdroid Roulette.
##
## Runs before the game's own autoloads and watches every scene the game enters, so platform changes can be made
## from outside the game's scripts. Today it does one thing:
##   - when multiplayer cannot work (the WebRTC GDExtension behind BuckdroidNet is missing), the main menu's Multiplayer
##     button is greyed out, cannot be pressed or focused, and says "Coming soon". Otherwise it is left alone and the
##     game's multiplayer runs on our peer-to-peer layer (see docs/MULTIPLAYER.md).
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
	_update_lobby_code(scene)


# --- the lobby ID as text on the lobby screen (user request: readable without pasting it somewhere) --------------------
const LOBBY_SCENE := "res://multiplayer/scenes/mp_lobby.tscn"
var _code_layer: CanvasLayer
var _code_label: Label
var _code_shown := -1


func _update_lobby_code(scene: Node) -> void:
	var gs := get_node_or_null(^"/root/GlobalSteam")
	var id: int = gs.LOBBY_ID if gs and scene and scene.scene_file_path == LOBBY_SCENE else 0
	if id == _code_shown:
		return
	_code_shown = id
	if id == 0:
		if _code_layer:
			_code_layer.visible = false
		return
	if _code_layer == null or not is_instance_valid(_code_layer):
		_code_layer = CanvasLayer.new()
		_code_layer.layer = 50
		add_child(_code_layer)
		_code_label = Label.new()
		_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_code_label.anchor_left = 1.0
		_code_label.anchor_right = 1.0
		_code_label.offset_left = -430
		_code_label.offset_right = -30
		_code_label.offset_top = 78
		_code_label.offset_bottom = 138
		_code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_code_layer.add_child(_code_label)
	# The lobby screen's own look: its font and green, found on one of its labels.
	# (its text is in buttons and labels with their own font: take the first one that does not use the default font)
	for n in scene.find_children("*", "Control", true, false):
		if not (n is Label or n is Button or n is RichTextLabel):
			continue
		var font_name := &"normal_font" if n is RichTextLabel else &"font"
		var color_name := &"default_color" if n is RichTextLabel else &"font_color"
		var f: Font = n.get_theme_font(font_name)
		if f == null or f == ThemeDB.fallback_font:
			continue
		_code_label.add_theme_font_override(&"font", f)
		_code_label.add_theme_color_override(&"font_color", n.get_theme_color(color_name))
		break
	_code_label.add_theme_font_size_override(&"font_size", 22)
	var digits := str(id)
	var groups := PackedStringArray()
	for i in range(0, digits.length(), 4):
		groups.append(digits.substr(i, 4))
	_code_label.text = "LOBBY ID\n" + " ".join(groups)
	_code_layer.visible = true


func _on_scene_changed(scene: Node) -> void:
	if not is_instance_valid(scene):
		return
	if scene.scene_file_path == MENU_SCENE:
		var net := get_node_or_null(^"/root/BuckdroidNet")
		if net == null or not net.available:
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
