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
	_check_lobby_focus(scene)


# --- lobby ID on the lobby screen: shown as a short code, typed in, pasted with or without spaces --------------------------
# (user requests: read the ID without pasting it somewhere; type an ID in; spaces in a pasted ID must not matter; a
# shorter ID.) The lobby ID is shown, copied and typed as a 12-character code (LobbyCode, e.g. 7K3Q-M9XD-2PHT); the
# 18-digit number still works everywhere.
const LobbyCode := preload("res://buckdroid/net/lobby_code.gd")
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
	# Back from another app (where the code or ID was copied, often from a chat message): make the clipboard hold the
	# bare 18 digits, so the game's own paste button accepts it (it takes exactly 18 characters). Read only then, not
	# continuously (Android shows a notice whenever an app reads the clipboard).
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and _on_lobby_screen:
		var c := DisplayServer.clipboard_get().strip_edges()
		var digits := _digits_only(c)
		if c.length() <= 40 and digits.length() == LOBBY_ID_DIGITS and digits != c and _only_id_characters(c):
			DisplayServer.clipboard_set(digits)
		elif c.length() <= 20:
			var from_code: int = LobbyCode.decode(c)
			if from_code != 0:
				DisplayServer.clipboard_set(str(from_code))


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
	_watch_copy_button(scene)
	# While typing on a phone, keep the entry box above the on-screen keyboard.
	if _panel.visible:
		var chat := get_node_or_null(^"/root/BuckdroidChat")
		var kb: float = chat.keyboard_top() if chat and _entry.has_focus() else 1e9
		var half_h := 95.0
		var centre := get_viewport().get_visible_rect().size.y / 2.0
		var shift := minf(0.0, kb - 8.0 - (centre + half_h))
		shift = maxf(shift, 8.0 - (centre - half_h))
		_panel.offset_top = -half_h + shift
		_panel.offset_bottom = half_h + shift
	var gs := get_node_or_null(^"/root/GlobalSteam")
	var id: int = gs.LOBBY_ID if gs else 0
	if id == _code_shown:
		return
	_code_shown = id
	_code_label.visible = id != 0
	_code_label.text = "LOBBY CODE\n" + (LobbyCode.encode(id) if id != 0 else "")


# The game's own "COPY LOBBY ID" puts the 18 digits on the clipboard. Our handler is connected to the same button's
# "pressed" signal (after the game's), and a moment later (so two clipboard writes cannot land out of order on a phone)
# puts the short code there instead and says so in the game's message line. (The first version watched that message's
# text; on the tester's phone the digits stayed on the clipboard.)
var _copy_hooked_scene: Node
const CODE_COPIED := "LOBBY CODE COPIED"


func _watch_copy_button(scene: Node) -> void:
	if scene == _copy_hooked_scene:
		return
	for n in scene.find_children("*", "Node", true, false):
		var sc: Script = n.get_script()
		if sc and sc.resource_path.get_file() == "MP_ButtonClassMain.gd" and n.get("alias") == "copy lobby id":
			var b = n.get("button")
			if b is BaseButton:
				b.pressed.connect(_copy_code_after_game, CONNECT_DEFERRED)
				_copy_hooked_scene = scene
				return


func _copy_code_after_game() -> void:
	await get_tree().create_timer(0.2, true, false, true).timeout
	var gs := get_node_or_null(^"/root/GlobalSteam")
	if gs == null or gs.LOBBY_ID == 0:
		return
	DisplayServer.clipboard_set(LobbyCode.encode(gs.LOBBY_ID))
	var lm := _find_lobby_manager(get_tree().current_scene)
	var msg: Label = lm.get("ui_copypaste_console_pop") as Label if lm else null
	if msg:
		msg.text = CODE_COPIED


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
		_type_button.text = "TYPE A LOBBY CODE"
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
		title.text = "TYPE THE LOBBY CODE"
		box.add_child(title)
		_entry = LineEdit.new()
		_entry.placeholder_text = "12-letter code (or the 18 digits)"
		_entry.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT     # codes have letters
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
		# Taps on these go to them only, not also to the game's lobby buttons behind (BuckdroidChat routes them).
		var chat := get_node_or_null(^"/root/BuckdroidChat")
		if chat:
			for c: Control in [_type_button, _panel, _entry, join, cancel]:
				chat.register(c)
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
	var id: int = LobbyCode.parse(_entry.text)
	if id == 0:
		_entry_note.text = "A lobby code has 12 letters and digits, like 7K3Q-M9XD-2PHT."
		return
	var lm := _find_lobby_manager(get_tree().current_scene)
	if lm == null:
		_entry_note.text = "The lobby screen is not ready yet."
		return
	_panel.visible = false
	lm.join_lobby(id)


func _find_lobby_manager(n: Node) -> Node:
	return _find_by_script(n, "MP_LobbyManager.gd")


func _find_by_script(n: Node, file: String) -> Node:
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


# --- controller / on-screen buttons on the lobby screen after a match ------------------------------------------------
# (tester report: back in the lobby after a match, the on-screen buttons did nothing.) The game picks the first lobby
# button for controller navigation only when a lobby is joined or left; coming back from a match reloads the lobby
# screen while still in the lobby, so nothing has the focus and the d-pad has nothing to move from. The first press
# then selects the game's own first lobby button (it is used for that press only, so it never presses a button).
## The game marks the controller as in use on the first press (its MP_ControllerManager) and may take that press for
## itself, so also check after it: controller in use, nothing focused -> the first lobby button.
var _controller_manager: Node
func _check_lobby_focus(scene: Node) -> void:
	if not _on_lobby_screen or (_panel and _panel.visible) or Engine.get_process_frames() % 6 != 0:
		return
	if _controller_manager == null or not is_instance_valid(_controller_manager) or not scene.is_ancestor_of(_controller_manager):
		_controller_manager = _find_by_script(scene, "MP_ControllerManager.gd")
		if _controller_manager == null:
			return
	var cursor = _controller_manager.get("cursor")
	if cursor == null or not cursor.get("controller_active") or get_viewport().gui_get_focus_owner() != null:
		return
	_focus_first_lobby_button()


func _focus_first_lobby_button() -> bool:
	var ui := _find_by_script(get_tree().current_scene, "MP_LobbyUI.gd")
	if ui == null or not ui.has_method(&"GetFirstUIFocus"):
		return false
	var first = ui.GetFirstUIFocus()
	if first is Control and first.is_visible_in_tree():
		first.grab_focus()
		return true
	return false


func _input(event: InputEvent) -> void:
	if not _on_lobby_screen or not event.is_pressed() or event.is_echo():
		return
	var nav := event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5) 			or (event is InputEventKey and (event.is_action("ui_up") or event.is_action("ui_down") or event.is_action("ui_left") or event.is_action("ui_right")))
	if not nav or get_viewport().gui_get_focus_owner() != null or (_panel and _panel.visible):
		return
	if _focus_first_lobby_button():
		get_viewport().set_input_as_handled()


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
