## BuckdroidTestDriver - original code, part of Buckdroid Roulette. DEVELOPMENT BUILDS ONLY (tools/build_patched_pck.py --dev).
##
## Plays a test script and saves screenshots, so touch and controller paths can be checked without a person.
## Start Godot with user arguments:  -- --bd-script=<file> --bd-out=<folder>
## Script: one step per line, '#' starts a comment. Coordinates are in the game's 960x540 base resolution.
##   wait <seconds>             shot <name>              log <text>
##   tap <x> <y>                touch press + release at a point (goes through touch-to-mouse emulation)
##   click <x> <y>              mouse click
##   joy <button index>         controller button press + release (device 0)
##   action <name>              InputMap action press + release
##   key <keycode>              key press + release (Godot keycode, e.g. 4194305 = Escape)
##   scene                      log the current scene
##   quit
extends Node

const BASE := Vector2(960, 540)

var _steps: PackedStringArray = []
var _out := "user://bd_shots"


func _ready() -> void:
	var script_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-script="):
			script_path = arg.trim_prefix("--bd-script=")
		elif arg.begins_with("--bd-out="):
			_out = arg.trim_prefix("--bd-out=")
	if script_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var text := FileAccess.get_file_as_string(script_path)
	_steps = text.split("\n")
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _run() -> void:
	for raw in _steps:
		var line := raw.split("#")[0].strip_edges()
		if line.is_empty():
			continue
		var p := line.split(" ", false)
		match p[0]:
			"wait":
				await get_tree().create_timer(float(p[1]), true, false, true).timeout
			"shot":
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				img.save_png(_out.path_join(p[1] + ".png"))
				_log("shot " + p[1])
			"log":
				_log(line.substr(4))
			"scene":
				var s := get_tree().current_scene
				_log("scene: " + (s.scene_file_path if s else "<none>"))
			"tap":
				await _touch(_to_window(Vector2(float(p[1]), float(p[2]))))
			"click":
				await _click(_to_window(Vector2(float(p[1]), float(p[2]))))
			"joy":
				await _joy(int(p[1]))
			"action":
				await _action(p[1])
			"key":
				await _key(int(p[1]))
			"inspect":
				_inspect(p[1])
			"mobile_settings":  # every project setting with a .mobile override, next to its base value
				for prop in ProjectSettings.get_property_list():
					var key: String = prop.name
					if key.ends_with(".mobile"):
						var base := key.trim_suffix(".mobile")
						_log("%s  base=%s  mobile=%s" % [base, ProjectSettings.get_setting(base), ProjectSettings.get_setting(key)])
			"lights":
				_lights(get_tree().current_scene)
			"setall":  # setall <Class> <property> <value as Godot literal>: rendering experiments
				var count := 0
				for n in get_tree().current_scene.find_children("*", p[1], true, false):
					n.set(p[2], str_to_var(p[3]))
					count += 1
				_log("setall %s.%s = %s on %d nodes" % [p[1], p[2], p[3], count])
			"texinfo":  # texinfo <name substring>: materials and texture formats of matching meshes
				_texinfo(p[1].to_lower())
			"vp":  # vp <viewport property> <value>
				get_viewport().set(p[1], str_to_var(p[2]))
				_log("viewport %s = %s" % [p[1], get_viewport().get(p[1])])
			"quit":
				_log("done")
				get_tree().quit()
				return
			_:
				_log("unknown step: " + line)


func _to_window(base_pos: Vector2) -> Vector2:
	var win := Vector2(get_window().size)
	var scale := minf(win.x / BASE.x, win.y / BASE.y)
	var offset := (win - BASE * scale) / 2.0
	return offset + base_pos * scale


func _touch(pos: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.index = 0
	t.position = pos
	t.pressed = true
	Input.parse_input_event(t)
	await get_tree().create_timer(0.08, true, false, true).timeout
	var r := t.duplicate()
	r.pressed = false
	Input.parse_input_event(r)
	await get_tree().process_frame


func _click(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	Input.parse_input_event(m)
	Input.warp_mouse(pos)
	for i in 3:  # like a real mouse: the pointer rests on the target for a few frames before the click
		await get_tree().process_frame
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.position = pos
	b.global_position = pos
	b.pressed = true
	b.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(b)
	await get_tree().create_timer(0.08, true, false, true).timeout
	var r := b.duplicate()
	r.pressed = false
	r.button_mask = 0
	Input.parse_input_event(r)
	await get_tree().process_frame


func _joy(button: int) -> void:
	var j := InputEventJoypadButton.new()
	j.device = 0
	j.button_index = button
	j.pressed = true
	Input.parse_input_event(j)
	await get_tree().create_timer(0.08, true, false, true).timeout
	var r := j.duplicate()
	r.pressed = false
	Input.parse_input_event(r)
	await get_tree().process_frame


func _action(name: String) -> void:
	var a := InputEventAction.new()
	a.action = name
	a.pressed = true
	Input.parse_input_event(a)
	await get_tree().create_timer(0.08, true, false, true).timeout
	var r := a.duplicate()
	r.pressed = false
	Input.parse_input_event(r)
	await get_tree().process_frame


func _key(code: int) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	Input.parse_input_event(k)
	await get_tree().create_timer(0.08, true, false, true).timeout
	var r := k.duplicate()
	r.pressed = false
	Input.parse_input_event(r)
	await get_tree().process_frame


## inspect <script file name>: prints, for the first node running that script, its exported node references:
## their class, visibility, materials (transparency settings, shader parameters) and AnimationPlayer tracks.
## For porting analysis on the developer's machine only.
func _inspect(script_file: String) -> void:
	var node := _find_by_script(get_tree().root, script_file)
	if node == null:
		_log("inspect: no node runs " + script_file)
		return
	_log("inspect " + script_file + " at " + str(node.get_path()))
	for prop in node.get_property_list():
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var v = node.get(prop.name)
		var items: Array = v if v is Array else [v]
		for it in items:
			if it is Node:
				_describe(prop.name, it, 0)


func _describe(label: String, n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth + 1)
	var line := "%s%s: %s %s" % [pad, label, n.get_class(), n.name]
	if n is CanvasItem or n is Node3D:
		line += " visible=" + str(n.visible)
	_log(line)
	if n is GeometryInstance3D:
		_log(pad + "  transparency=%s cast_shadow=%s" % [n.transparency, n.cast_shadow])
		_material(pad, "override", n.material_override)
		_material(pad, "overlay", n.material_overlay)
	if n is MeshInstance3D and n.mesh:
		for s in n.mesh.get_surface_count():
			_material(pad, "surface%d" % s, n.get_active_material(s))
	if n is Label3D:
		_log(pad + "  modulate=%s alpha_cut=%s" % [n.modulate, n.alpha_cut])
	if n is AnimationPlayer:
		for anim_name in n.get_animation_list():
			var a: Animation = n.get_animation(anim_name)
			for t in a.get_track_count():
				_log(pad + "  anim %s track %s type=%d" % [anim_name, a.track_get_path(t), a.track_get_type(t)])
	if depth < 2:
		for c in n.get_children():
			_describe("child", c, depth + 1)


func _material(pad: String, label: String, m: Material) -> void:
	if m == null:
		return
	if m is BaseMaterial3D:
		_log(pad + "  %s: %s transparency=%d blend=%d alpha=%.2f distance_fade=%d proximity_fade=%s depth_draw=%d no_depth_test=%s shading=%d" % [
				label, m.get_class(), m.transparency, m.blend_mode, m.albedo_color.a, m.distance_fade_mode,
				m.proximity_fade_enabled, m.depth_draw_mode, m.no_depth_test, m.shading_mode])
	elif m is ShaderMaterial:
		var params := []
		if m.shader:
			for u in m.shader.get_shader_uniform_list():
				params.append("%s=%s" % [u.name, m.get_shader_parameter(u.name)])
		_log(pad + "  %s: ShaderMaterial %s %s" % [label, m.shader.resource_path if m.shader else "<none>", ", ".join(params)])
	else:
		_log(pad + "  %s: %s" % [label, m.get_class()])


## lights: every Light3D in the scene with its shadow settings, plus the viewport's shadow atlas.
func _lights(root: Node) -> void:
	var vp := get_viewport()
	_log("shadow atlas size=%d 16bits=%s  rendering=%s" % [vp.positional_shadow_atlas_size,
			vp.positional_shadow_atlas_16_bits, ProjectSettings.get_setting("rendering/renderer/rendering_method")])
	for n in root.find_children("*", "Light3D", true, false):
		var l: Light3D = n
		var extra := ""
		if l is OmniLight3D:
			extra = "range=%.1f omni_mode=%d" % [l.omni_range, l.omni_shadow_mode]
		elif l is SpotLight3D:
			extra = "range=%.1f angle=%.0f" % [l.spot_range, l.spot_angle]
		elif l is DirectionalLight3D:
			extra = "dir_mode=%d" % l.directional_shadow_mode
		_log("  %s %s visible=%s energy=%.2f shadow=%s bias=%.3f blur=%.1f %s" % [l.get_class(), l.name,
				l.is_visible_in_tree(), l.light_energy, l.shadow_enabled, l.shadow_bias, l.shadow_blur, extra])


func _texinfo(needle: String) -> void:
	var seen := {}
	for n in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):
		var path := str(n.get_path()).to_lower()
		if not path.contains(needle) or n.mesh == null:
			continue
		_log("mesh %s visible=%s" % [n.get_path(), n.is_visible_in_tree()])
		for s in n.mesh.get_surface_count():
			var m: Material = n.get_active_material(s)
			if m == null or seen.has(m):
				continue
			seen[m] = true
			if m is BaseMaterial3D:
				_log("  surface%d %s shading=%d albedo=%s rough=%.2f metal=%.2f spec=%.2f normal=%s(%.2f) transparency=%d" % [
						s, m.resource_path.get_file(), m.shading_mode, m.albedo_color, m.roughness, m.metallic,
						m.metallic_specular, m.normal_enabled, m.normal_scale, m.transparency])
				for slot in ["albedo_texture", "roughness_texture", "normal_texture", "metallic_texture", "emission_texture"]:
					var t: Texture2D = m.get(slot)
					if t:
						var img := t.get_image()
						_log("    %s %s %dx%d fmt=%s mip=%s" % [slot, t.resource_path.get_file(), t.get_width(), t.get_height(),
								img.get_format() if img else "?", img.has_mipmaps() if img else "?"])
			else:
				_log("  surface%d %s" % [s, m.get_class()])


func _find_by_script(n: Node, script_file: String) -> Node:
	var s: Script = n.get_script()
	if s and s.resource_path.get_file() == script_file:
		return n
	for c in n.get_children():
		var r := _find_by_script(c, script_file)
		if r:
			return r
	return null


func _log(msg: String) -> void:
	print("[bd-test] ", msg)
