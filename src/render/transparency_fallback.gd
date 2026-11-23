## BuckdroidTransparencyFallback - original code, part of Buckdroid Roulette.
##
## The game fades some objects in and out by animating GeometryInstance3D.transparency (the "DEALER" / "YOU" choice
## text, effects). On Android with Godot 4.1's Mobile renderer that property has no effect on the tested Adreno GPU,
## so those objects stayed visible all the time.
##
## This autoload finds every object whose transparency is driven by an AnimationPlayer (in each scene, and in
## anything instanced later) and hides it while it is fully transparent. The game's own visibility changes are
## respected: an object is only ever shown again by us if we were the ones who hid it.
## graphics.ini: transparency_fallback = auto | on | off. "auto" (default) turns it on only on Android with the
## Mobile or Compatibility renderer; Forward+ handles animated transparency itself, and this fallback can flicker
## (an animation may set the transparency after this check in the same frame, so a fading object can show fully
## opaque for one frame). "--bd-transparency-fallback" forces it on for testing.
extends Node

const OPAQUE_LIMIT := 0.999   # transparency at or above this counts as invisible

var enabled := false
var _targets: Array[GeometryInstance3D] = []
var _hidden_by_us := {}       # instance id -> true


func _ready() -> void:
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	var mode: String = settings.get_value("graphics", "transparency_fallback") if settings else ""
	var renderer: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "")
	match mode:
		"on":
			enabled = true
		"off":
			enabled = false
		_:
			enabled = OS.get_name() == "Android" and renderer != "forward_plus"
	if OS.get_cmdline_user_args().has("--bd-transparency-fallback"):
		enabled = true
	print("[buckdroid] transparency fallback: %s (setting %s, renderer %s)" % [enabled, mode if mode else "auto", renderer])
	if not enabled:
		set_process(false)
		return
	process_priority = 1000   # after the game and animations have run this frame
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is AnimationPlayer:
		_register_player.call_deferred(node)


func _register_player(player: AnimationPlayer) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	var root := player.get_node_or_null(player.root_node)
	if root == null:
		return
	for anim_name in player.get_animation_list():
		var anim := player.get_animation(anim_name)
		for t in anim.get_track_count():
			var path := anim.track_get_path(t)
			if path.get_concatenated_subnames() != "transparency":
				continue
			var target := root.get_node_or_null(NodePath(path.get_concatenated_names()))
			if target is GeometryInstance3D and not _targets.has(target):
				_targets.append(target)


func _process(_delta: float) -> void:
	var i := 0
	while i < _targets.size():
		var g := _targets[i]
		if not is_instance_valid(g):
			_targets.remove_at(i)
			continue
		var id := g.get_instance_id()
		if g.transparency >= OPAQUE_LIMIT:
			if g.visible:
				g.visible = false
				_hidden_by_us[id] = true
		elif _hidden_by_us.has(id):
			g.visible = true
			_hidden_by_us.erase(id)
		i += 1
