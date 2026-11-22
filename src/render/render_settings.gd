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
##    "adaptive" (optional, NOT the default): like "mixed", plus the table's fill lights drop their shadows while the dealer's
##      head isn't on screen. Those shadows only visibly shape his face; at the table view they make no visible
##      difference. S24 Ultra, idle table, uncapped: mixed 13.1 ms GPU, adaptive 9.5-9.9 ms (about 27% less); the
##      dealer intro and the empty table look the same as mixed. BUT items placed on the table lose their shadows
##      while the dealer is off screen (playtest report): those fill lights also cast the items' shadows. Kept as an
##      option for weak phones only.
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

const MODES := ["cube", "mixed", "adaptive", "key_only", "paraboloid"]
const DEALER_HEAD_NODE := &"dealer head mesh"   # the dealer's head mesh in the game's main scene
const HEAD_RADIUS_FRACTION := 0.17               # drawn head radius / bounding-box half diagonal (calibrated)
const DEALER_VIEW_MARGIN := 0.1                  # fraction of the head's size added around it (shadows switch on the same frame)
const CAMERA_NEAR_DEALER := 60.0                 # world units (table camera ~34, bathroom ~190); farther: no change
const TABLE_FILL_RADIUS := 30.0                  # world units from the dealer's head that count as the table's fill lights

var _dealer: MeshInstance3D = null
var _dealer_was_on_screen := true
var _on_screen_frame := -1

var is_android := OS.get_name() == "Android"
var shadow_mode := ANDROID_DEFAULT_MODE if is_android else "cube"
var skip_zero_energy := is_android

var _lights: Array[Light3D] = []    # lights that cast shadows in the game's own setup
var _key := {}                      # instance id -> true for key lights


func _ready() -> void:
	# graphics.ini (BuckdroidSettings): shadow_mode = cube | mixed | paraboloid, fps_cap = 30 | 60 | 0
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	var ini_mode: String = settings.get_value("graphics", "shadow_mode") if settings else ""
	if ini_mode in MODES:
		shadow_mode = ini_mode
		skip_zero_energy = true
	# shadow_softness (0 = hard edges ... 5 = softest; Godot's default 2) and shadow_resolution (shadow atlas size).
	# Applied at startup, before shaders compile, so they cost no hitch.
	var softness: String = settings.get_value("graphics", "shadow_softness") if settings else ""
	if softness.is_valid_int():
		RenderingServer.positional_soft_shadow_filter_set_quality(clampi(int(softness), 0, 5))
		RenderingServer.directional_soft_shadow_filter_set_quality(clampi(int(softness), 0, 5))
	var resolution: String = settings.get_value("graphics", "shadow_resolution") if settings else ""
	if resolution.is_valid_int() and int(resolution) in [1024, 2048, 4096, 8192]:
		get_tree().root.positional_shadow_atlas_size = int(resolution)
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
	elif node is GeometryInstance3D and _is_shadow_excluded(node):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_excluded_count += 1
		if _excluded_count == 1 or _excluded_count % 8 == 0:
			print("[buckdroid] shadow casting off for %d indicator meshes (latest: %s)" % [_excluded_count, node.name])
	elif node is MeshInstance3D and node.name == DEALER_HEAD_NODE:
		_track_dealer.call_deferred(node)


## Shadow caching fix. Godot only redraws a light's shadow when a shadow-casting object in its range changes, but the
## game's 32 small blinking indicator lights inside the table devices are toggled by script many times a second.
## Each toggle counted as a change, so every table light redrew its whole shadow map every frame (found with the
## engine diagnostic in engine/patches/0001). Those meshes are tiny glowing indicators whose shadows can't be seen;
## with shadow casting off, their blinking no longer touches any shadow and Godot's own caching works again.
## Applies on every platform: it changes nothing visible and saves work everywhere.
const SHADOW_EXCLUDED_PREFIXES := ["tabletop interior blinker"]
var _excluded_count := 0


func _is_shadow_excluded(node: Node) -> bool:
	var n := String(node.name)
	for prefix in SHADOW_EXCLUDED_PREFIXES:
		if n.begins_with(prefix):
			return true
	return false


func _register(light: Light3D) -> void:
	if not is_instance_valid(light) or not light.shadow_enabled or _lights.has(light):
		return
	_lights.append(light)
	if light is OmniLight3D and light.light_energy >= KEY_LIGHT_ENERGY:
		_key[light.get_instance_id()] = true
	_apply_mode(light)


func set_shadow_mode(mode: String) -> void:
	shadow_mode = mode
	skip_zero_energy = true
	for l in _lights:
		if is_instance_valid(l):
			_apply_mode(l)
	print("[buckdroid] shadow mode=", mode)


func _apply_mode(light: Light3D) -> void:
	if not light is OmniLight3D:
		return
	var is_key := _key.has(light.get_instance_id())
	var paraboloid := shadow_mode == "paraboloid" or (shadow_mode in ["mixed", "adaptive"] and not is_key)
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID if paraboloid else OmniLight3D.SHADOW_CUBE


## adaptive mode: is this fill light's shadow needed right now? The fill lights around the table only visibly shape the
## dealer (his face loses its shading without them) and make no visible difference to the table view. So their
## shadows stay on while the dealer's head is on screen (or within the margin around it), and are off otherwise.
## Only while the camera is near the dealer: a light without its shadow shines through walls, so elsewhere (the
## bathroom, the balcony) nothing changes.
func _fill_shadow_needed(light: OmniLight3D) -> bool:
	if not is_instance_valid(_dealer):
		return true
	var head := _dealer_center()
	# The game's world is built at a large scale: the table spans about 14 units, the player's camera sits about
	# 34 units from the dealer, the bathroom camera about 190. The six table fill lights are 16-29 units away and
	# reach his (large) head.
	if light.global_position.distance_to(head) > TABLE_FILL_RADIUS:
		return true                     # not one of the table's fill lights
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.global_position.distance_to(head) > CAMERA_NEAR_DEALER:
		return true
	return _dealer_on_screen(cam)


## Whether the dealer's head overlaps the picture: its centre is projected into the viewport and treated as a circle
## of the head's real size (plus DEALER_VIEW_MARGIN). Exact and cheap; computed once per frame.
## (Godot's VisibleOnScreenNotifier3D reported the head as visible in the table view, where it isn't.)
func _dealer_on_screen(cam: Camera3D) -> bool:
	var frame := Engine.get_process_frames()
	if frame == _on_screen_frame:
		return _dealer_was_on_screen
	_on_screen_frame = frame
	var on_screen := false
	var center := _dealer_center()
	if _dealer.is_visible_in_tree() and not cam.is_position_behind(center):
		var radius := _dealer_radius() * (1.0 + DEALER_VIEW_MARGIN)
		var p := cam.unproject_position(center)
		var edge := cam.unproject_position(center + cam.global_transform.basis.x * radius)
		var r_px := p.distance_to(edge)
		var view := get_viewport().get_visible_rect()
		on_screen = view.grow(r_px).has_point(p)
		if on_screen != _dealer_was_on_screen:
			print("[buckdroid] adaptive shadows: dealer on screen=%s (head at %s, radius %.0f px)" % [on_screen, p, r_px])
	elif _dealer_was_on_screen:
		print("[buckdroid] adaptive shadows: dealer on screen=false (hidden or behind the camera)")
	_dealer_was_on_screen = on_screen
	return on_screen


## Centre of the head's bounding box in world space (a rigged mesh's origin can sit far from the visible head).
func _dealer_center() -> Vector3:
	return _dealer.global_transform * _dealer.get_aabb().get_center()


## Radius of the head as drawn, in world units. The rig's bounding box is far larger than the visible head (its half
## diagonal is about 7.4 units; the drawn head is about 1.2 units across its radius, measured on screen in the intro),
## so a fraction of it is used.
func _dealer_radius() -> float:
	return (_dealer.global_transform.basis.get_scale() * _dealer.get_aabb().size).length() / 2.0 * HEAD_RADIUS_FRACTION


func _track_dealer(mesh: MeshInstance3D) -> void:
	_dealer = mesh
	print("[buckdroid] adaptive shadows: tracking the dealer's head (radius %.1f units)" % _dealer_radius())
	var skel := mesh.get_parent() as Skeleton3D
	if skel:
		var names := []
		for b in skel.get_bone_count():
			names.append("%s@%s" % [skel.get_bone_name(b), (skel.global_transform * skel.get_bone_global_pose(b)).origin])
		print("[buckdroid] dealer bones: ", names)


func _process(_delta: float) -> void:
	if not skip_zero_energy:
		return
	var i := 0
	while i < _lights.size():
		var l := _lights[i]
		if not is_instance_valid(l):
			_lights.remove_at(i)
			continue
		# key_only: only the strong key lights keep shadows (the fill lights' shadows barely show; see header)
		var is_fill := l is OmniLight3D and not _key.has(l.get_instance_id())
		var fill_off := is_fill and (shadow_mode == "key_only" or (shadow_mode == "adaptive" and not _fill_shadow_needed(l)))
		var want := l.light_energy > ZERO_ENERGY and not fill_off
		if l.shadow_enabled != want:
			l.shadow_enabled = want
		i += 1
