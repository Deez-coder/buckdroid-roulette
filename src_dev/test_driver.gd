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
var _hidden_overlays: Array[CanvasItem] = []
var _shadow_lights: Array[Light3D] = []


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
	# Test scripts tap exact positions, so they run in direct touch mode whatever controls.ini says (the file is left
	# alone). An empty script changes nothing, so the game plays normally. "touchmode <mode>" switches inside a script.
	var has_steps := false
	for raw in _steps:
		if not raw.split("#")[0].strip_edges().is_empty():
			has_steps = true
	var touch := get_node_or_null(^"/root/BuckdroidTouch")
	if has_steps and touch:
		touch.mode = "direct"
		_log("touch mode forced to direct for this test")
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
			"where":  # where <name substring with _ for spaces>: world positions of matching 3D nodes, and the camera
				var needle := p[1].replace("_", " ").to_lower()
				var cam := get_viewport().get_camera_3d()
				for n in get_tree().current_scene.find_children("*", "Node3D", true, false):
					if String(n.name).to_lower().contains(needle):
						var scr: Variant = cam.unproject_position(n.global_position) if cam else "-"
						_log("where %s: %s on screen at %s visible=%s %s" % [n.get_class(), n.global_position, scr,
								n.is_visible_in_tree(), n.get_path()])
				_log("where camera: %s %s" % [cam.global_position if cam else "none", cam.get_path() if cam else ""])
			"anims":  # anims: every AnimationPlayer that is playing right now, its animation and the tracks it drives
				for ap in get_tree().current_scene.find_children("*", "AnimationPlayer", true, false):
					if ap.is_playing():
						var a: Animation = ap.get_animation(ap.current_animation)
						var tracks := []
						if a:
							for t in mini(a.get_track_count(), 6):
								tracks.append(str(a.track_get_path(t)))
						_log("anim playing: %s '%s' loop=%s tracks=%s" % [ap.get_path(), ap.current_animation,
								a.loop_mode if a else "?", tracks])
				for pt in get_tree().current_scene.find_children("*", "GPUParticles3D", true, false):
					if pt.is_visible_in_tree() and pt.emitting:
						_log("particles emitting: %s" % pt.get_path())
			"pause":  # pause <AnimationPlayer name substring, _ for spaces> <true|false>
				var needle := p[1].replace("_", " ").to_lower()
				for ap in get_tree().current_scene.find_children("*", "AnimationPlayer", true, false):
					if String(ap.name).to_lower().contains(needle):
						ap.speed_scale = 0.0 if p[2] == "true" else 1.0
						_log("pause %s = %s" % [ap.get_path(), p[2]])
			"freeze":  # freeze <true|false>: pause every AnimationPlayer and particle system (rendering experiment)
				var frozen := p[1] == "true"
				for ap in get_tree().current_scene.find_children("*", "AnimationPlayer", true, false):
					ap.speed_scale = 0.0 if frozen else 1.0
				for pt in get_tree().current_scene.find_children("*", "GPUParticles3D", true, false):
					pt.speed_scale = 0.0 if frozen else 1.0
				_log("freeze = " + p[1])
			"renderinfo":  # renderinfo <label>: objects / primitives / draw calls for the visible pass and the shadow passes
				await RenderingServer.frame_post_draw
				var vp := get_viewport().get_viewport_rid()
				var info := []
				for t in [RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW]:
					info.append([RenderingServer.viewport_get_render_info(vp, t, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
							RenderingServer.viewport_get_render_info(vp, t, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
							RenderingServer.viewport_get_render_info(vp, t, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)])
				_log("renderinfo %s: visible objects=%d tris=%d draws=%d | shadows objects=%d tris=%d draws=%d" % [
						p[1] if p.size() > 1 else "", info[0][0], info[0][1], info[0][2], info[1][0], info[1][1], info[1][2]])
			"casters":  # casters: biggest shadow-casting meshes near the camera by triangle count
				var rows := []
				for mi in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):
					if mi.is_visible_in_tree() and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.mesh:
						var tris := 0
						for s in mi.mesh.get_surface_count():
							var arr: Array = mi.mesh.surface_get_arrays(s)
							var idx = arr[Mesh.ARRAY_INDEX]
							tris += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
						rows.append([tris, mi.mesh.get_surface_count(), mi.get_path()])
				rows.sort_custom(func(a, b): return a[0] > b[0])
				var total := 0
				for r in rows:
					total += r[0]
				_log("casters: %d visible shadow-casting meshes, %d triangles total" % [rows.size(), total])
				for r in rows.slice(0, 15):
					_log("  caster %d tris, %d surfaces: %s" % r)
			"castersnear":  # which shadow-casting meshes lie inside each shadowed light's range (what its shadow map draws)
				var meshes := []
				for mi in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):
					if mi.is_visible_in_tree() and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.mesh:
						var tris := 0
						for s in mi.mesh.get_surface_count():
							var arr: Array = mi.mesh.surface_get_arrays(s)
							var idx = arr[Mesh.ARRAY_INDEX]
							tris += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
						meshes.append([mi, tris, mi.global_transform * mi.get_aabb()])
				var union := {}
				for l in get_tree().current_scene.find_children("*", "OmniLight3D", true, false):
					if not (l.is_visible_in_tree() and l.shadow_enabled):
						continue
					var sphere_c: Vector3 = l.global_position
					var r: float = l.omni_range
					var n := 0
					var t := 0
					for m in meshes:
						var box: AABB = m[2]
						var closest := sphere_c.clamp(box.position, box.end)
						if closest.distance_to(sphere_c) <= r:
							n += 1
							t += m[1]
							union[m[0]] = m[1]
					_log("light %s (energy %.1f, range %.0f, mode %d): %d casters, %d tris" % [l.name, l.light_energy, r,
							l.omni_shadow_mode, n, t])
				var rows := []
				for k in union:
					rows.append([union[k], str(k.get_path()).trim_prefix("/root/main/")])
				rows.sort_custom(func(a, b): return a[0] > b[0])
				_log("casters inside any shadowed light's range: %d" % rows.size())
				for row in rows.slice(0, 25):
					_log("  %6d tris  %s" % row)
			"nodeinfo":  # nodeinfo <name substring, _ for spaces>: transform, world-space box, visibility, cast shadow
				var nd := p[1].replace("_", " ").to_lower()
				for n in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if String(n.name).to_lower().contains(nd):
						_log("nodeinfo %s: scale %s, world box %s, visible=%s self=%s cast_shadow=%d transparency=%.2f" % [
								n.get_path(), n.global_transform.basis.get_scale(), n.global_transform * n.get_aabb(),
								n.is_visible_in_tree(), n.visible, n.cast_shadow, n.transparency])
			"hide":  # hide <name substring, _ for spaces> <true|false>: toggle visibility (experiments)
				var hn := p[1].replace("_", " ").to_lower()
				for n in get_tree().current_scene.find_children("*", "Node3D", true, false):
					if String(n.name).to_lower() == hn:
						n.visible = p[2] != "true"
						_log("hide %s = %s" % [n.get_path(), p[2]])
			"changers":  # changers <frames>: geometry and lights whose transform, visibility or light settings change
				# while watched. Anything that changes inside a light's range forces that light's shadow to be redrawn.
				var watched := get_tree().current_scene.find_children("*", "VisualInstance3D", true, false)
				var first := {}
				var changed := {}
				for f in int(p[1]):
					for n in watched:
						if not is_instance_valid(n):
							continue
						var sig := [n.global_transform, n.is_visible_in_tree()]
						if n is Light3D:
							sig.append_array([n.light_energy, n.light_color, n.shadow_enabled])
						if n is GeometryInstance3D:
							sig.append_array([n.cast_shadow, n.transparency])
						if n is GPUParticles3D:
							sig.append(n.emitting)
						var id := n.get_instance_id()
						if not first.has(id):
							first[id] = sig
						elif first[id] != sig and not changed.has(id):
							changed[id] = n
					await get_tree().process_frame
				_log("changers: %d of %d visual nodes changed over %s frames" % [changed.size(), watched.size(), p[1]])
				for id in changed:
					var c: Node = changed[id]
					var what := c.get_class()
					if c is GeometryInstance3D:
						what += " cast_shadow=%d" % c.cast_shadow
					_log("  changed: %s %s" % [what, str(c.get_path()).trim_prefix("/root/main/")])
			"animmats":  # shadow-casting meshes whose material uses TIME (Godot then redraws every shadow they're in, every frame)
				var found := 0
				for mi in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if not (mi.is_visible_in_tree() and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF):
						continue
					var mats := []
					if mi.material_override:
						mats.append(mi.material_override)
					if mi is MeshInstance3D and mi.mesh:
						for s in mi.mesh.get_surface_count():
							mats.append(mi.get_active_material(s))
					for m in mats:
						var cur: Material = m
						while cur:
							if cur is ShaderMaterial and cur.shader and cur.shader.code.contains("TIME"):
								found += 1
								_log("animmat: %s uses TIME (%s) cast_shadow=%d" % [str(mi.get_path()).trim_prefix("/root/main/"),
										cur.shader.resource_path.get_file(), mi.cast_shadow])
							cur = cur.next_pass
				_log("animmats: %d" % found)
			"castshadow":  # castshadow <name prefix, _ for spaces> <0|1>: shadow casting for meshes whose name starts with it
				var pre := p[1].replace("_", " ")
				var cnt := 0
				for g in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if String(g.name).begins_with(pre):
						g.cast_shadow = int(p[2])
						cnt += 1
				_log("castshadow %s = %s on %d meshes" % [pre, p[2], cnt])
			"quadsub":  # quadsub <quadrant 0-3> <subdiv enum 0-6>: shadow atlas slots per quadrant (2 = 4 slots, 3 = 16, 4 = 64)
				get_viewport().set_positional_shadow_atlas_quadrant_subdiv(int(p[1]), int(p[2]))
				_log("shadow atlas quadrant %s subdiv = %s" % [p[1], p[2]])
			"fpscap":  # fpscap <n>: frame rate limit for this run (0 = none). With a cap the phone lowers its GPU clock,
				# so GPU time per frame stops reflecting the amount of work; measure costs uncapped.
				Engine.max_fps = int(p[1])
				_log("fps cap = " + p[1])
			"touchmode":  # touchmode <direct|relative>
				var tm := get_node_or_null(^"/root/BuckdroidTouch")
				if tm:
					tm.mode = p[1]
				_log("touch mode = " + p[1])
			"drag":  # drag <dx> <dy>: finger down, move by (dx, dy) base pixels in 10 steps, finger up (relative mode)
				await _drag(Vector2(float(p[1]), float(p[2])))
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
			"fps":  # fps <seconds> <label>: average / worst frame time and GPU time over a window
				await _fps(float(p[1]), p[2] if p.size() > 2 else "")
			"env":  # every WorldEnvironment's expensive features
				for we in get_tree().current_scene.find_children("*", "WorldEnvironment", true, false):
					var e: Environment = we.environment
					if e:
						_log("env %s: ssao=%s ssil=%s ssr=%s sdfgi=%s glow=%s vol_fog=%s fog=%s adjust=%s tonemap=%d bg=%d" % [
								we.get_path(), e.ssao_enabled, e.ssil_enabled, e.ssr_enabled, e.sdfgi_enabled, e.glow_enabled,
								e.volumetric_fog_enabled, e.fog_enabled, e.adjustment_enabled, e.tonemap_mode, e.background_mode])
			"envset":  # envset <property> <value>: on every WorldEnvironment's Environment
				for we in get_tree().current_scene.find_children("*", "WorldEnvironment", true, false):
					if we.environment:
						we.environment.set(p[1], str_to_var(p[2]))
				_log("envset %s = %s" % [p[1], p[2]])
			"overlays":  # overlays <true|false>: show/hide 2D nodes drawn with a ShaderMaterial (screen effects)
				var shown := p[1] == "true"
				if not shown:
					_hidden_overlays.clear()
					for ci in get_tree().current_scene.find_children("*", "CanvasItem", true, false):
						if ci.material is ShaderMaterial and ci.visible:
							ci.visible = false
							_hidden_overlays.append(ci)
				else:
					for ci in _hidden_overlays:  # only the ones this step hid
						if is_instance_valid(ci):
							ci.visible = true
				_log("overlays visible=%s (%d changed)" % [shown, _hidden_overlays.size()])
			"softshadow":  # softshadow <0-5>: soft shadow filter quality (positional + directional)
				RenderingServer.positional_soft_shadow_filter_set_quality(int(p[1]))
				RenderingServer.directional_soft_shadow_filter_set_quality(int(p[1]))
				_log("soft shadow quality = " + p[1])
			"shadowlist":  # remember every visible light that casts shadows right now, with an index
				_shadow_lights.clear()
				for n in get_tree().current_scene.find_children("*", "Light3D", true, false):
					if n.is_visible_in_tree() and n.shadow_enabled:
						_shadow_lights.append(n)
						_log("  shadow light %d: %s energy=%.2f range=%.1f" % [_shadow_lights.size() - 1, n.name,
								n.light_energy, n.omni_range if n is OmniLight3D else 0.0])
			"shadow":  # shadow <index|all|zero> <on|off>: only lights from the last shadowlist
				var on := p[2] == "on"
				var picked := 0
				for i in _shadow_lights.size():
					var l: Light3D = _shadow_lights[i]
					if not is_instance_valid(l):
						continue
					var parab: bool = l is OmniLight3D and l.omni_shadow_mode == OmniLight3D.SHADOW_DUAL_PARABOLOID
					if p[1] == "all" or (p[1] == "zero" and l.light_energy <= 0.01) or (p[1] == "parab" and parab) or p[1] == str(i):
						l.shadow_enabled = on
						picked += 1
				_log("shadow %s %s (%d lights)" % [p[1], p[2], picked])
			"omnimode":  # omnimode <0|1>: dual paraboloid (0) or cube (1) for the listed omni lights
				for l in _shadow_lights:
					if is_instance_valid(l) and l is OmniLight3D:
						l.omni_shadow_mode = int(p[1])
				_log("omni shadow mode = " + p[1])
			"call":  # call <autoload name> <method> [string arg]
				var target := get_node_or_null(NodePath("/root/" + p[1]))
				if target and target.has_method(p[2]):
					if p.size() > 3:
						target.call(p[2], p[3])
					else:
						target.call(p[2])
				else:
					_log("call: %s.%s not found" % [p[1], p[2]])
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


func _drag(delta: Vector2) -> void:
	var start := _to_window(BASE / 2.0)
	var scale := (_to_window(BASE) - _to_window(Vector2.ZERO)) / BASE
	var t := InputEventScreenTouch.new()
	t.index = 0
	t.position = start
	t.pressed = true
	Input.parse_input_event(t)
	await get_tree().process_frame
	var pos := start
	for i in 10:
		var d := InputEventScreenDrag.new()
		d.index = 0
		d.relative = delta / 10.0 * scale
		pos += d.relative
		d.position = pos
		Input.parse_input_event(d)
		await get_tree().process_frame
	var r := InputEventScreenTouch.new()
	r.index = 0
	r.position = pos
	r.pressed = false
	Input.parse_input_event(r)
	await get_tree().create_timer(0.3, true, false, true).timeout


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


func _fps(seconds: float, label: String) -> void:
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	var frames := 0
	var worst := 0.0
	var gpu_total := 0.0
	var cpu_total := 0.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	while Time.get_ticks_usec() - t0 < int(seconds * 1e6):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		frames += 1
		gpu_total += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		cpu_total += (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var avg_ms := (last - t0) / 1000.0 / maxi(frames, 1)
	_log("fps %s: %.1f fps avg (%.1f ms), worst frame %.1f ms, gpu %.1f ms avg, main loop %.2f ms, cap=%d" % [label,
			1000.0 / avg_ms, avg_ms, worst, gpu_total / maxi(frames, 1), cpu_total / maxi(frames, 1), Engine.max_fps])


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
