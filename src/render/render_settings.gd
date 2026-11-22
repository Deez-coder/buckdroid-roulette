## BuckdroidRender - original code, part of Buckdroid Roulette.
##
## Rendering settings that must be applied to the running window rather than as project settings.
##   - 32-bit positional shadow atlas on Android. On the tested Adreno 750 the default 16-bit atlas loses most of
##     the shadows from the game's omni lights; switching the root viewport to 32-bit at runtime brings them back
##     (same-frame experiment on the phone). The matching project setting alone did not take effect.
## Phase 5 will extend this into the Low / Medium / High presets.
extends Node

var is_android := OS.get_name() == "Android"


func _ready() -> void:
	var root := get_tree().root
	if is_android or OS.get_cmdline_user_args().has("--bd-mobile-render"):
		root.positional_shadow_atlas_16_bits = false
	print("[buckdroid] shadow atlas size=%d 16-bit=%s" % [root.positional_shadow_atlas_size,
			root.positional_shadow_atlas_16_bits])
