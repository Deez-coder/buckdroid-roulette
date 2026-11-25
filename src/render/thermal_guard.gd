extends Node
## BuckdroidThermal - original code, part of Buckdroid Roulette.
##
## Reads Android's thermal headroom (PowerManager.getThermalHeadroom: about 1.0 means the phone is about to throttle)
## and thermal status through Godot's built-in AndroidRuntime plugin, and eases the GPU load only when the phone gets
## close to throttling, the approach Google recommends for games (ADPF). Normal play is untouched.
##
## Steps, cheapest-looking first (measured on a Galaxy S24 Ultra in a multiplayer match, GPU 14.0 ms per frame):
##   1. shadow resolution halved (12.6 ms, -10%; screenshots look the same; no hitch),
##   2. frame rate limit 50, 3. frame rate limit 40 (work falls with the frame rate),
##   4+. 3D resolution down in 10% steps to 70% (only -3% per step on that phone: the load is lighting, not pixels).
## One step down per check (10 s) while hot, one step back up per minute once cooled. Steps that would not lower
## anything (the player already chose lower values) are skipped.
##
## graphics.ini: thermal_guard = on (default) | off. With "off" the values are still read for telemetry.
##               thermal_guard_level = 0.80 - 0.99 (default 0.90): the headroom at which it steps in; it steps back up
##               after a minute below that level minus 0.10. (0.95 let a multiplayer match reach Android's "moderate"
##               throttling before the guard ever acted; 0.90 acts just before that.)
## Polls every 10 s (Android returns NaN when asked more than about once a second).

const POLL_SECONDS := 10.0
const DEFAULT_LEVEL := 0.90    # headroom at or above this: lower the 3D resolution one step (thermal_guard_level)
const RECOVER_MARGIN := 0.10   # headroom below level - margin for RECOVER_SECONDS: raise it one step
const RECOVER_SECONDS := 60.0
const STEP := 0.1
const MIN_SCALE := 0.7

var headroom := -1.0           # last reading, -1 = unknown
var status := -1               # PowerManager.THERMAL_STATUS_*, -1 = unknown
var eased_steps := 0           # how many steps are currently taken (see header)
var enabled := true
var step_down_at := DEFAULT_LEVEL
var step_up_below := DEFAULT_LEVEL - RECOVER_MARGIN

var _power = null              # android.os.PowerManager (JavaObject)
var _timer := 0.0
var _cool_time := 0.0
var _user_scale := 1.0
var _base_atlas := 0
var _base_fps := 0
const FPS_STEPS := [50, 40]


func _ready() -> void:
	if OS.get_name() != "Android" or not Engine.has_singleton("AndroidRuntime"):
		set_process(false)
		return
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings:
		enabled = settings.get_value("graphics", "thermal_guard") != "off"
		var lv: String = settings.get_value("graphics", "thermal_guard_level")
		if lv.is_valid_float():
			step_down_at = clampf(float(lv), 0.80, 0.99)
			step_up_below = step_down_at - RECOVER_MARGIN
		var s: String = settings.get_value("graphics", "render_scale")
		_user_scale = clampf(float(s), 0.5, 1.0) if s.is_valid_float() else 1.0
	var runtime = Engine.get_singleton("AndroidRuntime")
	var context = runtime.getApplicationContext() if runtime else null
	_power = context.getSystemService("power") if context else null
	if _power == null:
		push_warning("Buckdroid: PowerManager not available; thermal guard off")
		set_process(false)
		return
	print("[buckdroid] thermal guard: %s, steps in at headroom %.2f" % ["on" if enabled else "off (reading only)", step_down_at])
	_read()
	_capture_base.call_deferred()


## The player's own settings (applied by BuckdroidRender before this runs): what the steps go down from and back to.
func _capture_base() -> void:
	_base_atlas = get_tree().root.positional_shadow_atlas_size
	_base_fps = Engine.max_fps


func _max_steps() -> int:
	var scale_steps := int(round((_user_scale - MIN_SCALE) / STEP))
	return 1 + FPS_STEPS.size() + maxi(scale_steps, 0)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < POLL_SECONDS:
		return
	_timer = 0.0
	_read()
	if not enabled or headroom < 0.0:
		return
	if headroom >= step_down_at:
		_cool_time = 0.0
		if eased_steps < _max_steps():
			eased_steps += 1
			_apply("headroom %.2f" % headroom)
	elif headroom < step_up_below and eased_steps > 0:
		_cool_time += POLL_SECONDS
		if _cool_time >= RECOVER_SECONDS:
			_cool_time = 0.0
			eased_steps -= 1
			_apply("cooled to headroom %.2f" % headroom)
	else:
		_cool_time = 0.0


func _read() -> void:
	var h = _power.getThermalHeadroom(10)   # forecast 10 s ahead
	if typeof(h) == TYPE_FLOAT and not is_nan(h):
		headroom = h
	var st = _power.getCurrentThermalStatus()
	if typeof(st) == TYPE_INT:
		status = st


func _apply(reason: String) -> void:
	var root := get_tree().root
	# 1: shadow resolution
	var atlas := _base_atlas / 2 if eased_steps >= 1 and _base_atlas >= 2048 else _base_atlas
	if root.positional_shadow_atlas_size != atlas:
		root.positional_shadow_atlas_size = atlas
	# 2, 3: frame rate limit (never above the player's own limit; 0 = unlimited)
	var fps := _base_fps
	var fps_step := eased_steps - 1
	if fps_step >= 1:
		var cap: int = FPS_STEPS[mini(fps_step, FPS_STEPS.size()) - 1]
		fps = cap if _base_fps == 0 else mini(_base_fps, cap)
	Engine.max_fps = fps
	# 4+: 3D resolution
	var scale_steps := maxi(0, eased_steps - 1 - FPS_STEPS.size())
	var scale := maxf(MIN_SCALE, _user_scale - scale_steps * STEP)
	if not is_equal_approx(root.scaling_3d_scale, scale):
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		root.scaling_3d_scale = scale
	print("[buckdroid] thermal guard: step %d - shadow atlas %d, fps limit %d, 3D scale %.2f (%s)" % [eased_steps, atlas,
			fps, scale, reason])


## Tests (the dev test driver: "call BuckdroidThermal force_step <n>"): apply step n as if the phone were that hot.
func force_step(n: String) -> void:
	if _base_fps == 0 and _base_atlas == 0:
		_capture_base()
	eased_steps = clampi(int(n), 0, _max_steps())
	_apply("forced for a test")
