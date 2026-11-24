## BuckdroidToast - original code, part of Buckdroid Roulette.
##
## A small hint line near the bottom of the screen ("Tap again to shoot", "Press back again to leave"), drawn above
## the game in the game's own font when it can be found. One message at a time; a new one replaces the old one.
extends CanvasLayer

var _label: Label
var _until_ms := 0


func _ready() -> void:
	layer = 127
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override(&"font_color", Color(1, 1, 1))
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override(&"outline_size", 6)
	_label.add_theme_font_size_override(&"font_size", 18)
	_label.visible = false
	add_child(_label)


## Shows text for the given number of seconds.
func show_text(text: String, seconds := 2.5) -> void:
	_label.text = text
	var size := get_viewport().get_visible_rect().size
	_label.size = Vector2(size.x, 40)
	_label.position = Vector2(0, size.y * 0.78)
	_label.modulate.a = 1.0
	_label.visible = true
	_until_ms = Time.get_ticks_msec() + int(seconds * 1000.0)


func hide_text() -> void:
	_label.visible = false
	_until_ms = 0


func _process(_delta: float) -> void:
	if not _label.visible:
		return
	var left := _until_ms - Time.get_ticks_msec()
	if left <= 0:
		_label.visible = false
	elif left < 300:
		_label.modulate.a = left / 300.0
