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


# --- lobby ID on the lobby screen: shown as text, typed in, pasted with or without spaces ---------------------------------
# (user requests: read the ID without pasting it somewhere; type an ID in; spaces in a pasted ID must not matter)
const LOBBY_SCENE := "res://multiplayer/scenes/mp_lobby.tscn"
const LOBBY_ID_DIGITS := 18          # the game's "join with pasted ID" accepts exactly 18 characters
var _code_layer: CanvasLayer
var _code_label: Label
var _type_button: Button
var _panel: PanelContainer
var _entry: LineEdit
var _entry_note: Label
var _code_shown := -1
var _on_lobby_screen := false


func _notification(what: int) -> void:
	# Back from another app (where the ID was copied, often from a chat message with spaces): make the clipboard hold
	# the bare 18 digits, so the game's paste button accepts it. Read only then, not continuously (Android shows a
	# notice whenever an app reads the clipboard).
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and _on_lobby_screen:
		var c := DisplayServer.clipboard_get().strip_edges()
		var digits := _digits_only(c)
		if c.length() <= 40 and digits.length() == LOBBY_ID_DIGITS and digits != c and _only_id_characters(c):
			DisplayServer.clipboard_set(digits)


static func _digits_only(t: String) -> String:
	var out := ""
	for ch in t:
		if ch >= "0" and ch <= "9":
			out += ch
	return out


static func _only_id_characters(t: String) -> bool:
	for ch in t:
		if not (ch >= "0" and ch <= "9") and not ch in " -.\t":
			return false
	return true


func _update_lobby_code(scene: Node) -> void:
	var on_screen := scene != null and is_instance_valid(scene) and scene.scene_file_path == LOBBY_SCENE
	if on_screen != _on_lobby_screen:
		_on_lobby_screen = on_screen
		if on_screen:
			_build_lobby_ui(scene)
		elif _code_layer:
			_code_layer.visible = false
			_panel.visible = false
	if not on_screen:
		_code_shown = -1
		return
	var gs := get_node_or_null(^"/root/GlobalSteam")
	var id: int = gs.LOBBY_ID if gs else 0
	if id == _code_shown:
		return
	_code_shown = id
	_code_label.visible = id != 0
	var digits := str(id)
	var groups := PackedStringArray()
	for k in range(0, digits.length(), 3):
		groups.append(digits.substr(k, 3))
	_code_label.text = "LOBBY ID\n" + " ".join(groups)


func _build_lobby_ui(scene: Node) -> void:
	if _code_layer == null or not is_instance_valid(_code_layer):
		_code_layer = CanvasLayer.new()
		_code_layer.layer = 50
		add_child(_code_layer)
		_code_label = Label.new()
		_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_place(_code_label, -430, 78, -30, 138)
		_code_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_code_layer.add_child(_code_label)
		_type_button = Button.new()
		_type_button.text = "TYPE A LOBBY ID"
		_type_button.flat = true
		_type_button.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_place(_type_button, -330, 142, -30, 172)
		_type_button.pressed.connect(_open_entry)
		_code_layer.add_child(_type_button)
		_panel = PanelContainer.new()
		_panel.anchor_left = 0.5
		_panel.anchor_right = 0.5
		_panel.anchor_top = 0.5
		_panel.anchor_bottom = 0.5
		_panel.offset_left = -230
		_panel.offset_right = 230
		_panel.offset_top = -95
		_panel.offset_bottom = 95
		var box := VBoxContainer.new()
		box.add_theme_constant_override(&"separation", 10)
		_panel.add_child(box)
		var title := Label.new()
		title.text = "TYPE THE LOBBY ID"
		box.add_child(title)
		_entry = LineEdit.new()
		_entry.placeholder_text = "18 digits, spaces are fine"
		_entry.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
		_entry.max_length = 40
		_entry.text_submitted.connect(func(_t: String) -> void: _join_typed())
		box.add_child(_entry)
		_entry_note = Label.new()
		box.add_child(_entry_note)
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 24)
		var join := Button.new()
		join.text = "JOIN"
		join.pressed.connect(_join_typed)
		var cancel := Button.new()
		cancel.text = "CANCEL"
		cancel.pressed.connect(func() -> void: _panel.visible = false)
		row.add_child(join)
		row.add_child(cancel)
		box.add_child(row)
		_code_layer.add_child(_panel)
	_style_like_lobby(scene)
	_code_layer.visible = true
	_panel.visible = false
	_code_label.visible = false


static func _place(c: Control, left: float, top: float, right: float, bottom: float) -> void:
	c.anchor_left = 1.0
	c.anchor_right = 1.0
	c.offset_left = left
	c.offset_top = top
	c.offset_right = right
	c.offset_bottom = bottom


## The lobby screen's own look (its font and green), taken from the first of its texts that has its own font.
func _style_like_lobby(scene: Node) -> void:
	var font: Font = null
	var color := Color(0.3, 1.0, 0.3)
	for n in scene.find_children("*", "Control", true, false):
		if not (n is Label or n is Button or n is RichTextLabel):
			continue
		var f: Font = n.get_theme_font(&"normal_font" if n is RichTextLabel else &"font")
		if f == null or f == ThemeDB.fallback_font:
			continue
		font = f
		color = n.get_theme_color(&"default_color" if n is RichTextLabel else &"font_color")
		break
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(0, 0, 0, 0.92)
	frame.border_color = color
	frame.set_border_width_all(2)
	frame.set_content_margin_all(14)
	_panel.add_theme_stylebox_override(&"panel", frame)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0, 0, 0)
	field.border_color = color
	field.set_border_width_all(1)
	field.set_content_margin_all(6)
	_entry.add_theme_stylebox_override(&"normal", field)
	_entry.add_theme_stylebox_override(&"focus", field)
	for c in _code_layer.find_children("*", "Control", true, false):
		if c is Label or c is Button or c is LineEdit:
			if font:
				c.add_theme_font_override(&"font", font)
			c.add_theme_font_size_override(&"font_size", 22 if c == _code_label else 20)
			for key in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
				c.add_theme_color_override(key, color)
	_entry.add_theme_color_override(&"font_placeholder_color", color.darkened(0.5))
	_entry_note.add_theme_font_size_override(&"font_size", 16)


func _open_entry() -> void:
	_entry.text = ""
	_entry_note.text = ""
	_panel.visible = true
	_entry.grab_focus()


func _join_typed() -> void:
	var digits := _digits_only(_entry.text)
	if digits.length() != LOBBY_ID_DIGITS:
		_entry_note.text = "A lobby ID has %d digits (%d typed)." % [LOBBY_ID_DIGITS, digits.length()]
		return
	var lm := _find_lobby_manager(get_tree().current_scene)
	if lm == null:
		_entry_note.text = "The lobby screen is not ready yet."
		return
	_panel.visible = false
	lm.join_lobby(int(digits))


func _find_lobby_manager(n: Node) -> Node:
	if n == null:
		return null
	var sc: Script = n.get_script()
	if sc and sc.resource_path.get_file() == "MP_LobbyManager.gd":
		return n
	for c in n.get_children():
		var r := _find_lobby_manager(c)
		if r:
			return r
	return null


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
