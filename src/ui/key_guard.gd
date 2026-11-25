extends Node
## Part of BuckdroidChat (GPL-3.0-or-later). Kept as the last child of the root, so its _input runs before every game
## script's (Godot calls _input from the last node to the first). While one of our text fields is being typed in, it
## hands the keys to BuckdroidChat (see chat.gd, "typing"), so neither the game nor Godot's own key actions see them.


func _input(event: InputEvent) -> void:
	get_parent().get_node(^"BuckdroidChat")._guard_input(event)
