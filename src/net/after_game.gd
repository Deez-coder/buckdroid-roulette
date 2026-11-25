extends Node
## Part of BuckdroidNet (GPL-3.0-or-later): runs after every game script each frame (process_priority 1000) and lets
## BuckdroidNet hand over waiting packets and keep the Wi-Fi mode in step (see session.gd, "latency").


func _process(_delta: float) -> void:
	get_parent()._after_game()
