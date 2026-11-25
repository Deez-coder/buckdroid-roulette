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
const MAX_LINES := 100
const SEND_INTERVAL := 1.0
const POPUP_SECONDS := 4.0

var enabled := true
var _net: Node
var _overlay: Array[Control] = []
var _layer: CanvasLayer
var _button: Button
var _panel: PanelContainer
var _log: Label
var _scroll: ScrollContainer          # the message list scrolls (drag it with a finger, or the mouse wheel)
var _drag_scroll := false             # a finger that went down on the list scrolls it
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
	# After the game's own handler (deferred): see _on_focus_changed.
	get_viewport().gui_focus_changed.connect(_on_focus_changed, CONNECT_DEFERRED)
	_key_guard = Node.new()
	_key_guard.name = "BuckdroidKeyGuard"
	_key_guard.set_script(_KeyGuard)
	get_tree().root.add_child.call_deferred(_key_guard)


# --- typing ------------------------------------------------------------------------------------------------------------
# This game's input map binds Backspace to "ui_cancel" and has no keys for Godot's text-editing actions
# (ui_text_backspace, ui_text_delete, ui_text_submit, ...). In a LineEdit, ui_cancel ends the editing and closes the
# phone keyboard, and Samsung's keyboard sends a Backspace by itself while typing (when it corrects or capitalises the
# word being typed), so the keyboard closed at the first letter and Backspace never deleted (tester report on the S24
# Ultra; the log showed no focus change, only the game asking Android to hide the keyboard). While one of our text
# fields is being typed in, BuckdroidKeyGuard (the root's last child, so its _input comes before every game script's)
# hands every key here: characters, Backspace, Delete, arrows, Home/End, Enter and paste are done on the field
# directly, and the key goes no further (the game does not react to keys typed into the chat either).
const _KeyGuard := preload("res://buckdroid/ui/key_guard.gd")
var _key_guard: Node


func _guard_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var field := get_viewport().gui_get_focus_owner() as LineEdit
	if field == null or not _overlay.has(field) or not field.is_editing() or not field.is_visible_in_tree():
		return
	get_viewport().set_input_as_handled()
	if not event.pressed:
		return
	var k: Key = event.keycode
	match k:
		KEY_BACKSPACE:
			if field.has_selection():
				field.delete_text(field.get_selection_from_column(), field.get_selection_to_column())
			elif field.caret_column > 0:
				field.delete_text(field.caret_column - 1, field.caret_column)
		KEY_DELETE:
			if field.has_selection():
				field.delete_text(field.get_selection_from_column(), field.get_selection_to_column())
			elif field.caret_column < field.text.length():
				field.delete_text(field.caret_column, field.caret_column + 1)
		KEY_LEFT:
			field.caret_column = maxi(0, field.caret_column - 1)
		KEY_RIGHT:
			field.caret_column = mini(field.text.length(), field.caret_column + 1)
		KEY_HOME:
			field.caret_column = 0
		KEY_END:
			field.caret_column = field.text.length()
		KEY_ENTER, KEY_KP_ENTER:
			if not event.echo:
				field.text_submitted.emit(field.text)
		KEY_ESCAPE, KEY_BACK:          # stop typing (Android Back while the keyboard is up)
			_letting_go = true
			field.release_focus()
			_letting_go = false
		_:
			if (event.ctrl_pressed or event.meta_pressed) and k == KEY_V:
				field.insert_text_at_caret(DisplayServer.clipboard_get().strip_escapes())
			elif event.unicode >= 32 and not event.ctrl_pressed and not event.alt_pressed:
				field.insert_text_at_caret(char(event.unicode))
				field.text_changed.emit(field.text)


func _process_key_guard() -> void:
	# Scene changes add the new scene after it: move it back to the end so it stays first in line for keys.
	var root := get_tree().root
	if _key_guard and _key_guard.is_inside_tree() and root.get_child(root.get_child_count() - 1) != _key_guard:
		root.move_child(_key_guard, root.get_child_count() - 1)


# --- focus: keep the game's controller code off our boxes --------------------------------------------------------------
# The game's MP_ControllerManager remembers every control that gets the focus (previousFocus) and, while the controller
# is in use (always the case in Buttons mode, where the on-screen pad is a controller), takes that focus away again on
# the next mouse movement or click. A movement arrives as soon as the phone starts typing, so in Buttons mode the chat
# field lost the focus at the first letter and the keyboard closed (tester report; reproduced on the PC). When one of
# our boxes gets the focus, the game's remembered control is set back to its own last one.
var _game_focus: Control
var _letting_go := false               # our own code is taking the focus off a box (closing, tap elsewhere)
var _refocus_times: Array[float] = []


## Safety net: while the chat is open, its text field loses the focus only through the player (CLOSE, a tap elsewhere).
## Anything else (some other game code) gets the focus taken back, so typing goes on; logged to find the cause.
## At most 3 times in 2 seconds, so it can never fight another control in a loop.
func _on_entry_focus_lost() -> void:
	if _letting_go or not _panel.visible or not _layer.visible:
		return
	var now := Time.get_ticks_msec() / 1000.0
	_refocus_times = _refocus_times.filter(func(t: float) -> bool: return now - t < 2.0)
	var taker := get_viewport().gui_get_focus_owner()
	print("[buckdroid] chat field lost the focus to %s" % (str(taker.get_path()) if taker else "nothing"))
	if _refocus_times.size() >= 3:
		return
	_refocus_times.append(now)
	_refocus.call_deferred()


func _refocus() -> void:
	if _panel.visible and _layer.visible and not _entry.has_focus():
		_entry.grab_focus()
var _controller_managers: Array = []
var _cm_scene: Node


func _on_focus_changed(c: Control) -> void:
	if c == null or not is_instance_valid(c):
		return
	if not _is_overlay(c):
		_game_focus = c
		return
	var scene := get_tree().current_scene
	if scene != _cm_scene:
		_cm_scene = scene
		_controller_managers = []
		if scene:
			for n in scene.find_children("*", "Node", true, false):
				var sc: Script = n.get_script()
				if sc and sc.resource_path.get_file() == "MP_ControllerManager.gd":
					_controller_managers.append(n)
	var keep: Control = _game_focus if is_instance_valid(_game_focus) and _game_focus.is_inside_tree() else null
	for cm in _controller_managers:
		if is_instance_valid(cm) and _is_overlay(cm.get("previousFocus")):
			cm.set("previousFocus", keep)


func _is_overlay(c) -> bool:
	if not (c is Control) or not is_instance_valid(c):
		return false
	for o in _overlay:
		if is_instance_valid(o) and (o == c or o.is_ancestor_of(c)):
			return true
	return false


# --- overlay taps ----------------------------------------------------------------------------------------------------
func register(c: Control) -> void:
	if not _overlay.has(c):
		_overlay.append(c)
		if c is LineEdit:
			c.gui_input.connect(_on_field_key.bind(c))


## The game's input map has no keys for "ui_text_submit" (Godot's Enter-in-a-text-field action), so Enter (and the
## phone keyboard's Send/Done key, which arrives as Enter) never submitted our text fields. Done here for our fields
## only; the game's own input map stays as it is.
func _on_field_key(event: InputEvent, field: LineEdit) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		if InputMap.has_action(&"ui_text_submit") and InputMap.event_is_action(event, &"ui_text_submit"):
			return                      # the engine already handles it
		field.text_submitted.emit(field.text)
		field.accept_event()


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
				_letting_go = true
				c.release_focus()       # focusing again brings the keyboard back after it was closed
				_letting_go = false
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
		_letting_go = true
		focused.release_focus()
		_letting_go = false
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
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(0, 190)
	box.add_child(_scroll)
	_log = Label.new()
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_scroll.add_child(_log)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	_entry = LineEdit.new()
	_entry.max_length = 200
	_entry.placeholder_text = "Message"
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.text_submitted.connect(func(_t: String) -> void: _send())
	_entry.focus_exited.connect(_on_entry_focus_lost)
	_entry.keep_editing_on_text_submit = true      # Enter sends and the keyboard stays for the next message
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
	_process_key_guard()
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
	if _scroll.custom_minimum_size.y != log_h:
		_scroll.custom_minimum_size.y = log_h
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
		_refresh_log(true)
	else:
		_letting_go = true
		_entry.release_focus()
		_letting_go = false
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


func _refresh_log(to_end := false) -> void:
	# Stay at the newest message unless the player scrolled up to read older ones.
	var bar := _scroll.get_v_scroll_bar()
	var at_end := to_end or _scroll.scroll_vertical >= int(bar.max_value - bar.page) - 4
	_log.text = "\n".join(_lines)
	if at_end:
		_scroll_to_end.call_deferred()


func _scroll_to_end() -> void:
	await get_tree().process_frame          # the label's new height is known one frame later
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


## A finger on our boxes (BuckdroidTouch hands over the touches that consume_tap took): one that goes down on the
## message list and moves scrolls it. pos is in the game's base coordinates.
func overlay_drag(pos: Vector2, relative: Vector2, started: bool) -> void:
	if started:
		_drag_scroll = _panel.visible and _scroll.get_global_rect().has_point(pos)
		return
	if _drag_scroll:
		_scroll.scroll_vertical -= int(round(relative.y))


## Whether pos (base coordinates) is on the open message list (trackpad mode: a finger put down there scrolls the list
## instead of moving the cursor).
func on_message_list(pos: Vector2) -> bool:
	return _layer.visible and _panel.visible and _scroll.get_global_rect().has_point(pos)


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
	# The list's scroll bar in the same colour: a thin bar, so it is clear the list scrolls.
	var bar := _scroll.get_v_scroll_bar()
	var track := StyleBoxFlat.new()
	track.bg_color = Color(color, 0.15)
	track.content_margin_left = 3
	track.content_margin_right = 3
	bar.add_theme_stylebox_override(&"scroll", track)
	for key in [&"grabber", &"grabber_highlight", &"grabber_pressed"]:
		var g := StyleBoxFlat.new()
		g.bg_color = color if key != &"grabber" else Color(color, 0.7)
		bar.add_theme_stylebox_override(key, g)


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
