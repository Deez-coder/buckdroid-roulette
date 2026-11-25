extends Node
## BuckdroidChat - original code, part of Buckdroid Roulette (GPL-3.0-or-later).
##
## In-game chat for multiplayer, and the input routing for our own on-screen boxes.
##
## Chat: a CHAT button on the lobby screen and during a match (only while in a lobby; multiplayer.ini chat = on, the
## default). It opens a small box with the last messages, a text field and SEND. Messages travel over BuckdroidNet
## (to the host, which forwards them; 200 characters, plain text, one per second). While the box is closed, a new
## message shows for a few seconds under the button and the button counts unread messages.
##
## Overlay taps: the game reads mouse clicks in _input, before any of our boxes would see them, so a tap on one of our
## boxes would also click the game behind it (an item on the table, a lobby button). Our boxes register here;
## BuckdroidTouch asks consume_tap() before it turns a tap into a mouse click, and a tap on a registered box is handled
## here only (a button is pressed, a text field gets the focus and the keyboard). The same boxes are passed to the
## on-screen pad (TouchPad.setPassRects) so they also work in Buttons mode, and on menu and lobby screens the pad lets
## every tap through (TouchPad.setPassThrough), so the game's own lobby buttons work in every control mode.

const LOBBY_SCENE := "res://multiplayer/scenes/mp_lobby.tscn"
const MATCH_SCENE := "res://multiplayer/scenes/mp_main.tscn"
const MENU_SCENES := ["res://scenes/menu.tscn", LOBBY_SCENE]
const MAX_LINES := 40
const SHOWN_LINES := 9
const SEND_INTERVAL := 1.0
const POPUP_SECONDS := 4.0

var enabled := true
var _net: Node
var _overlay: Array[Control] = []
var _layer: CanvasLayer
var _button: Button
var _panel: PanelContainer
var _log: Label
var _entry: LineEdit
var _popup: Label
var _lines: Array[String] = []
var _unread := 0
var _last_send := -10.0
var _popup_until := 0.0
var _scene_path := ""
var _styled_for := ""
var _pad = null                     # JavaClass com.buckdroid.roulette.TouchPad (Android, Buttons mode)
var _pad_check := 0.0
var _pad_rects := PackedFloat32Array()
var _pad_all := false


func _ready() -> void:
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings:
		enabled = settings.get_value("multiplayer", "chat").to_lower() != "off"
	_net = get_node_or_null(^"/root/BuckdroidNet")
	if _net and _net.has_signal("chat_received"):
		_net.chat_received.connect(_on_chat)
	if OS.get_name() == "Android" and ClassDB.class_exists("JavaClassWrapper"):
		var w = JavaClassWrapper.wrap("com.buckdroid.roulette.TouchPad")
		if w:
			_pad = w
	_build()


# --- overlay taps ----------------------------------------------------------------------------------------------------
func register(c: Control) -> void:
	if not _overlay.has(c):
		_overlay.append(c)


## A tap at pos (the game's 960x540 coordinates). True when it landed on one of our boxes and was handled here.
func consume_tap(pos: Vector2) -> bool:
	var hit_any := false
	for i in range(_overlay.size() - 1, -1, -1):
		var c := _overlay[i]
		if not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		if not c.get_global_rect().has_point(pos):
			continue
		hit_any = true
		if c is LineEdit:
			if c.has_focus():
				c.release_focus()       # focusing again brings the keyboard back after it was closed
			c.grab_focus()
			return true
		if c is BaseButton and not c.disabled:
			c.pressed.emit()
			return true
	if hit_any:
		return true                     # a tap on a box's background: swallowed
	# A tap elsewhere ends typing.
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit and _overlay.has(focused):
		focused.release_focus()
		DisplayServer.virtual_keyboard_hide()
	return false


# --- chat ------------------------------------------------------------------------------------------------------------
func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 55
	add_child(_layer)
	_button = Button.new()
	_button.text = "CHAT"
	_button.flat = true
	_button.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_button.pressed.connect(_toggle)
	_layer.add_child(_button)
	_popup = Label.new()
	_popup.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_popup.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_popup)
	_panel = PanelContainer.new()
	_layer.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 8)
	_panel.add_child(box)
	var top := HBoxContainer.new()
	var title := Label.new()
	title.text = "CHAT"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var close := Button.new()
	close.text = "CLOSE"
	close.flat = true
	close.pressed.connect(_toggle)
	top.add_child(close)
	box.add_child(top)
	_log = Label.new()
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_log.custom_minimum_size = Vector2(0, 190)
	_log.clip_text = true
	box.add_child(_log)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	_entry = LineEdit.new()
	_entry.max_length = 200
	_entry.placeholder_text = "Message"
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.text_submitted.connect(func(_t: String) -> void: _send())
	row.add_child(_entry)
	var send := Button.new()
	send.text = "SEND"
	send.flat = true
	send.pressed.connect(_send)
	row.add_child(send)
	box.add_child(row)
	for c: Control in [_button, _panel, close, _entry, send]:
		register(c)
	_layer.visible = false
	_panel.visible = false


func _process(delta: float) -> void:
	var scene := get_tree().current_scene
	var path: String = scene.scene_file_path if scene else ""
	if path != _scene_path:
		_scene_path = path
		_place()
	var in_lobby: bool = _net != null and _net.lobby_id != 0
	var show := enabled and in_lobby and (path == LOBBY_SCENE or path == MATCH_SCENE)
	if show != _layer.visible:
		_layer.visible = show
		if not show:
			_panel.visible = false
	if show and _styled_for != path:
		_styled_for = path
		_style(scene)
	_popup.visible = show and not _panel.visible and Time.get_ticks_msec() / 1000.0 < _popup_until
	if _panel.visible:
		_lift_above_keyboard()
	_update_pad(delta, path)


## Our boxes sit at the top right: under the lobby ID on the lobby screen, in the corner during a match.
func _place() -> void:
	var y := 182.0 if _scene_path == LOBBY_SCENE else 12.0
	_set_rect(_button, -230, y, -30, y + 30)
	_set_rect(_popup, -430, y + 32, -30, y + 92)
	_set_rect(_panel, -440, y + 32, -20, y + 32 + 300)


## Where the on-screen keyboard starts, in the game's base coordinates (the base height when it is closed).
func keyboard_top() -> float:
	var base_h := get_viewport().get_visible_rect().size.y
	var kh := DisplayServer.virtual_keyboard_get_height()
	if kh <= 0:
		return base_h
	var screen_h := float(DisplayServer.window_get_size().y)
	return base_h - kh * base_h / maxf(screen_h, 1.0)


## While typing on a phone the keyboard covers the lower half: the box moves up so the text field stays visible (the
## message list gets shorter when there is not enough room).
func _lift_above_keyboard() -> void:
	var y := 182.0 if _scene_path == LOBBY_SCENE else 12.0
	var top := y + 32
	var log_h := 190.0
	var kb := keyboard_top()
	if _entry.has_focus() and kb < top + 300 + 8:
		log_h = clampf(kb - 8 - 110 - 8, 30.0, 190.0)
		top = maxf(8.0, kb - 8 - (log_h + 110))
	if _log.custom_minimum_size.y != log_h:
		_log.custom_minimum_size.y = log_h
	_panel.offset_left = -440
	_panel.offset_right = -20
	_panel.offset_top = top
	_panel.offset_bottom = top + log_h + 110


static func _set_rect(c: Control, left: float, top: float, right: float, bottom: float) -> void:
	c.anchor_left = 1.0
	c.anchor_right = 1.0
	c.offset_left = left
	c.offset_top = top
	c.offset_right = right
	c.offset_bottom = bottom


func _toggle() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_unread = 0
		_update_button()
		_refresh_log()
	else:
		_entry.release_focus()
		DisplayServer.virtual_keyboard_hide()


func _send() -> void:
	var text := _clean(_entry.text)
	if text == "" or _net == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_send < SEND_INTERVAL:
		return
	_last_send = now
	_entry.text = ""
	_net.send_chat(text)           # our own message comes back through chat_received


func _on_chat(sender_id: int, text: String) -> void:
	if not enabled:
		return
	text = _clean(text)
	if text == "":
		return
	var who: String = "You" if _net and sender_id == _net.my_id else (_net.member_name(sender_id) if _net else "Player")
	var line := "%s: %s" % [who, text]
	_lines.append(line)
	if _lines.size() > MAX_LINES:
		_lines.remove_at(0)
	if _panel.visible:
		_refresh_log()
	elif not (_net and sender_id == _net.my_id):
		_unread += 1
		_update_button()
		_popup.text = line
		_popup_until = Time.get_ticks_msec() / 1000.0 + POPUP_SECONDS


func _refresh_log() -> void:
	_log.text = "\n".join(_lines.slice(maxi(0, _lines.size() - SHOWN_LINES)))


func _update_button() -> void:
	_button.text = "CHAT (%d)" % _unread if _unread > 0 else "CHAT"


## Plain text only: no control characters, one line, at most 200 characters.
static func _clean(t: String) -> String:
	var out := ""
	for ch in t.strip_edges():
		if ch.unicode_at(0) >= 32:
			out += ch
	return out.substr(0, 200)


## The game's own look on that screen: its font and colour (first text with its own font), else a green terminal.
func _style(scene: Node) -> void:
	var font: Font = null
	var color := Color(0.35, 1.0, 0.35)
	if scene:
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
	frame.bg_color = Color(0, 0, 0, 0.88)
	frame.border_color = color
	frame.set_border_width_all(2)
	frame.set_content_margin_all(10)
	_panel.add_theme_stylebox_override(&"panel", frame)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0, 0, 0)
	field.border_color = color
	field.set_border_width_all(1)
	field.set_content_margin_all(6)
	_entry.add_theme_stylebox_override(&"normal", field)
	_entry.add_theme_stylebox_override(&"focus", field)
	for c in _layer.find_children("*", "Control", true, false):
		if c is Label or c is Button or c is LineEdit:
			if font:
				c.add_theme_font_override(&"font", font)
			c.add_theme_font_size_override(&"font_size", 18 if c == _log or c == _popup or c == _entry else 20)
			for key in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color"]:
				c.add_theme_color_override(key, color)
	_entry.add_theme_color_override(&"font_placeholder_color", color.darkened(0.5))
	_popup.add_theme_color_override(&"font_shadow_color", Color.BLACK)


# --- the on-screen pad (Buttons mode) ----------------------------------------------------------------------------------
func _update_pad(delta: float, path: String) -> void:
	if _pad == null:
		return
	_pad_check -= delta
	if _pad_check > 0.0:
		return
	_pad_check = 0.25
	var all := path in MENU_SCENES
	if all != _pad_all:
		_pad_all = all
		_pad.setPassThrough(all)
	# The pad measures parts of the whole screen; the game view may have bars at the sides, so go through window pixels.
	var to_window := get_tree().root.get_final_transform()
	var size := Vector2(DisplayServer.window_get_size())
	var rects := PackedFloat32Array()
	for c in _overlay:
		if is_instance_valid(c) and c.is_visible_in_tree():
			var r := c.get_global_rect()
			var a := to_window * r.position / size
			var b := to_window * r.end / size
			rects.append_array([a.x, a.y, b.x, b.y])
	if rects != _pad_rects:
		_pad_rects = rects
		_pad.setPassRects(rects)
