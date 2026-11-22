## BuckdroidRender - original code, part of Buckdroid Roulette.
##
## Rendering adjustments that must be applied to the running game rather than as project settings.
##
## 1. 32-bit positional shadow atlas on Android. On the tested Adreno 750 the default 16-bit atlas loses most of the
##    shadows from the game's omni lights; the matching project setting alone did not take effect.
##
## 2. Shadow optimizer. Shadows are almost the entire GPU cost of the game's 3D scenes on phones (Galaxy S24 Ultra,
##    Forward+: 26 ms per frame with shadows, 7 ms without). Every shadow-casting omni light draws its shadow as a cube
##    (6 passes). The optimizer:
##      - skips shadows for lights that are currently at zero brightness (the muzzle flash and item-effect lights sit
##        at zero most of the time). Invisible light, invisible shadow: no visual change.
##      - in "mixed" mode draws the weaker fill lights with dual-paraboloid shadows (2 passes) and keeps cube shadows
##        for the strong key lights that shape the dealer's face; in "paraboloid" mode every omni light uses 2 passes.
##    Modes: "cube" (original look), "mixed", "paraboloid". Desktop default "cube"; Android default below.
##    Override for testing: --bd-shadow-mode=<mode>. The game never changes these light settings itself.
##
##    Measured on the Galaxy S24 Ultra (Forward+), frame rate at the dealer intro / idle table:
##      cube 39 / 43 fps (dealer's face matches the PC), mixed 60 / 71 fps (face very close, same shading pattern),
##      paraboloid - / 96 fps (shadow pattern on the face visibly shifts). Hence "mixed" as the Android default.
##
## 3. 60 fps cap on Android (see _ready).
##
## Phase 5 turns this into the Low / Medium / High presets.
extends Node

const KEY_LIGHT_ENERGY := 15.0      # omni lights at or above this initial energy count as key lights
const ZERO_ENERGY := 0.01
const ANDROID_DEFAULT_MODE := "mixed"

var is_android := OS.get_name() == "Android"
var shadow_mode := ANDROID_DEFAULT_MODE if is_android else "cube"
var skip_zero_energy := is_android

var _lights: Array[Light3D] = []    # lights that cast shadows in the game's own setup
var _key := {}                      # instance id -> true for key lights


func _ready() -> void:
	# graphics.ini (BuckdroidSettings): shadow_mode = cube | mixed | paraboloid, fps_cap = 30 | 60 | 0
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	var ini_mode: String = settings.get_value("graphics", "shadow_mode") if settings else ""
	if ini_mode in ["cube", "mixed", "paraboloid"]:
		shadow_mode = ini_mode
		skip_zero_energy = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-shadow-mode="):
			shadow_mode = arg.trim_prefix("--bd-shadow-mode=")
			skip_zero_energy = true
	var root := get_tree().root
	if is_android or OS.get_cmdline_user_args().has("--bd-mobile-render"):
		root.positional_shadow_atlas_16_bits = false
	# 60 fps cap on Android by default: phones with 120 Hz screens would otherwise render twice as many frames for no
	# visible gain in this slow-paced game, and run hotter. graphics.ini fps_cap or --bd-fps-cap=<n> override it
	# (30 roughly halves the GPU work; 0 = unlimited).
	if is_android:
		Engine.max_fps = 60
	var ini_cap: String = settings.get_value("graphics", "fps_cap") if settings else ""
	if ini_cap.is_valid_int():
		Engine.max_fps = int(ini_cap)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-fps-cap="):
			Engine.max_fps = int(arg.trim_prefix("--bd-fps-cap="))
	print("[buckdroid] shadow atlas size=%d 16-bit=%s, shadow mode=%s, skip zero-energy=%s, fps cap=%d" % [
			root.positional_shadow_atlas_size, root.positional_shadow_atlas_16_bits, shadow_mode, skip_zero_energy,
			Engine.max_fps])
	process_priority = 1000          # after animations have set this frame's light energy
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is Light3D:
		_register.call_deferred(node)


func _register(light: Light3D) -> void:
	if not is_instance_valid(light) or not light.shadow_enabled or _lights.has(light):
		return
	_lights.append(light)
	if light is OmniLight3D and light.light_energy >= KEY_LIGHT_ENERGY:
		_key[light.get_instance_id()] = true
	_apply_mode(light)


func set_shadow_mode(mode: String) -> void:
	shadow_mode = mode
	for l in _lights:
		if is_instance_valid(l):
			_apply_mode(l)
	print("[buckdroid] shadow mode=", mode)


func _apply_mode(light: Light3D) -> void:
	if not light is OmniLight3D:
		return
	var paraboloid := shadow_mode == "paraboloid" or (shadow_mode == "mixed" and not _key.has(light.get_instance_id()))
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID if paraboloid else OmniLight3D.SHADOW_CUBE


func _process(_delta: float) -> void:
	if not skip_zero_energy:
		return
	var i := 0
	while i < _lights.size():
		var l := _lights[i]
		if not is_instance_valid(l):
			_lights.remove_at(i)
			continue
		var want := l.light_energy > ZERO_ENERGY
		if l.shadow_enabled != want:
			l.shadow_enabled = want
		i += 1
