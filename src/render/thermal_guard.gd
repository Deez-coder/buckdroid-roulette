extends Node
## BuckdroidThermal - original code, part of Buckdroid Roulette.
##
## Reads Android's thermal headroom (PowerManager.getThermalHeadroom: about 1.0 means the phone is about to throttle)
## and thermal status through Godot's built-in AndroidRuntime plugin, and gently eases the 3D resolution only when the
## phone gets close to throttling, the approach Google recommends for games (ADPF). Normal play is untouched.
##
## graphics.ini: thermal_guard = on (default) | off. With "off" the values are still read for telemetry.
## Polls every 10 s (Android returns NaN when asked more than about once a second).

const POLL_SECONDS := 10.0
const STEP_DOWN_AT := 0.95     # headroom at or above this: lower the 3D resolution one step
const STEP_UP_BELOW := 0.80    # headroom below this for RECOVER_SECONDS: raise it one step
const RECOVER_SECONDS := 60.0
const STEP := 0.1
const MIN_SCALE := 0.7

var headroom := -1.0           # last reading, -1 = unknown
var status := -1               # PowerManager.THERMAL_STATUS_*, -1 = unknown
var eased_steps := 0           # how many resolution steps are currently taken away
var enabled := true

var _power = null              # android.os.PowerManager (JavaObject)
var _timer := 0.0
var _cool_time := 0.0
var _user_scale := 1.0


func _ready() -> void:
	if OS.get_name() != "Android" or not Engine.has_singleton("AndroidRuntime"):
		set_process(false)
		return
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings:
		enabled = settings.get_value("graphics", "thermal_guard") != "off"
		var s: String = settings.get_value("graphics", "render_scale")
		_user_scale = clampf(float(s), 0.5, 1.0) if s.is_valid_float() else 1.0
	var runtime = Engine.get_singleton("AndroidRuntime")
	var context = runtime.getApplicationContext() if runtime else null
	_power = context.getSystemService("power") if context else null
	if _power == null:
		push_warning("Buckdroid: PowerManager not available; thermal guard off")
		set_process(false)
		return
	print("[buckdroid] thermal guard: %s" % ("on" if enabled else "off (reading only)"))
	_read()


func _process(delta: float) -> void:
	_timer += delta
	if _timer < POLL_SECONDS:
		return
	_timer = 0.0
	_read()
	if not enabled or headroom < 0.0:
		return
	if headroom >= STEP_DOWN_AT:
		_cool_time = 0.0
		if _user_scale - (eased_steps + 1) * STEP >= MIN_SCALE - 0.001:
			eased_steps += 1
			_apply("headroom %.2f" % headroom)
	elif headroom < STEP_UP_BELOW and eased_steps > 0:
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
	var scale := maxf(MIN_SCALE, _user_scale - eased_steps * STEP)
	var root := get_tree().root
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = scale
	print("[buckdroid] thermal guard: 3D scale %.2f (%s)" % [scale, reason])
