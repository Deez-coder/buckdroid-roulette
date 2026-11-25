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
	if script_path.is_empty() and OS.get_name() == "Android":
		# On a phone (no command line): <app files>/dev/script.txt, shots and log lines into <app files>/dev/out
		var parts := OS.get_user_data_dir().split("/", false)
		var dev := "/storage/emulated/0/Android/data/%s/files/dev" % (parts[parts.size() - 2] if parts.size() >= 2 else "")
		if FileAccess.file_exists(dev.path_join("script.txt")):
			script_path = dev.path_join("script.txt")
			_out = dev.path_join("out")
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
	var keep_touch := false
	for raw in _steps:
		if raw.strip_edges() == "keep_touch":   # the user plays; leave their touch mode alone
			keep_touch = true
	if has_steps and touch and not keep_touch:
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
			"callscript":  # callscript <script file> <method> [args]: call a game script's method (numbers become ints)
				var target := _find_by_script(get_tree().root, p[1])
				if target == null:
					_log("callscript: no node with script " + p[1])
				else:
					var args := []
					for a in p.slice(3):
						args.append(int(a) if a.is_valid_int() else a)
					_log("callscript %s.%s%s -> %s" % [p[1], p[2], args, target.callv(p[2], args)])
			"savelobby":  # savelobby <file>: write the current lobby ID (multiplayer tests with two copies)
				var gs := get_node_or_null(^"/root/GlobalSteam")
				var lid: int = gs.LOBBY_ID if gs else 0
				var f := FileAccess.open(p[1], FileAccess.WRITE)
				if f:
					f.store_string(str(lid))
				_log("lobby %d saved to %s" % [lid, p[1]])
			"joinsaved":  # joinsaved <file>: wait (up to 60 s) for a saved lobby ID, then join it through the game
				var waited := 0.0
				while not FileAccess.file_exists(p[1]) and waited < 60.0:
					await get_tree().create_timer(0.5, true, false, true).timeout
					waited += 0.5
				var lid := int(FileAccess.get_file_as_string(p[1]).strip_edges())
				var lm := _find_by_script(get_tree().root, "MP_LobbyManager.gd")
				_log("joining lobby %d (lobby manager %s)" % [lid, lm != null])
				if lm:
					lm.join_lobby(lid)
			"pos":  # pos <name substring, + for spaces>: class and world position of every 3D node whose name contains it
				var pn := p[1].replace("+", " ")
				for n in get_tree().current_scene.find_children("*" + pn + "*", "Node3D", true, false):
					_log("pos %s %s %s visible=%s" % [n.get_class(), n.name, n.global_position, n.is_visible_in_tree()])
			"castmask":  # castmask <light name prefix> <parent name prefix> <on|off>: whether geometry under scene children whose
				# name starts with the parent prefix casts shadows for lights whose name starts with the light prefix
				# (layer 20 + shadow_caster_mask; + for spaces)
				var lp := p[1].replace("+", " ")
				var gp := p[2].replace("+", " ")
				var bit := 1 << 19
				var marked := 0
				for c in get_tree().current_scene.get_children():
					if String(c.name).begins_with(gp):
						for g in c.find_children("*", "GeometryInstance3D", true, false):
							g.layers |= bit
							marked += 1
				var lights := 0
				for l in get_tree().current_scene.find_children(lp + "*", "Light3D", true, false):
					if p[3] == "off":
						l.shadow_caster_mask &= ~bit
					else:
						l.shadow_caster_mask |= bit
					lights += 1
				_log("castmask: %d objects, %d lights, %s" % [marked, lights, p[3]])
			"twofinger":  # twofinger <dx> <dy> <shot name>: two fingers down at the centre, drag by (dx, dy) base pixels in 20
				# steps, take a shot while they are still down, then lift them (multiplayer look-around test)
				var c0 := Vector2(440, 300)
				var c1 := Vector2(520, 300)
				for idx in 2:
					var t := InputEventScreenTouch.new()
					t.index = idx
					t.position = _to_window(c0 if idx == 0 else c1)
					t.pressed = true
					Input.parse_input_event(t)
					await get_tree().process_frame
				var step := Vector2(float(p[1]), float(p[2])) / 20.0
				for i in 20:
					for idx in 2:
						var d := InputEventScreenDrag.new()
						d.index = idx
						var base := (c0 if idx == 0 else c1) + step * (i + 1)
						d.position = _to_window(base)
						d.relative = step
						Input.parse_input_event(d)
					await get_tree().process_frame
				await get_tree().create_timer(0.3).timeout
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(_out.path_join(p[3] + ".png"))
				for idx in 2:
					var t := InputEventScreenTouch.new()
					t.index = idx
					t.position = _to_window(c0 + step * 20)
					t.pressed = false
					Input.parse_input_event(t)
				_log("twofinger %s %s done" % [p[1], p[2]])
			"lightmask":  # lightmask <light name prefix> <on|off>: whether those lights light visual layer 20 (light_cull_mask)
				var lmp := p[1].replace("+", " ")
				var nl := 0
				for l in get_tree().current_scene.find_children(lmp + "*", "Light3D", true, false):
					if p[2] == "off":
						l.light_cull_mask &= ~(1 << 19)
					else:
						l.light_cull_mask |= (1 << 19)
					nl += 1
				_log("lightmask %s %s (%d lights)" % [lmp, p[2], nl])
			"inputmap":  # inputmap <action, + for spaces>: the events bound to an action
				var an := p[1].replace("+", " ")
				if InputMap.has_action(an):
					for ev in InputMap.action_get_events(an):
						_log("inputmap %s: %s" % [an, ev.as_text()])
				else:
					_log("inputmap: no action " + an)
			"camturn":  # camturn <yaw degrees> <pitch degrees>: look around with a temporary camera at the game camera's place
				# (the game sets its own camera every frame); "camturn reset" gives the view back to the game's camera
				var game_cam: Camera3D = get_meta("bd_game_cam") if has_meta("bd_game_cam") else get_viewport().get_camera_3d()
				if has_meta("bd_test_cam"):
					var old: Camera3D = get_meta("bd_test_cam")
					if is_instance_valid(old):
						old.queue_free()
					remove_meta("bd_test_cam")
				if p[1] == "reset":
					if is_instance_valid(game_cam):
						game_cam.make_current()
					remove_meta("bd_game_cam")
				elif game_cam:
					set_meta("bd_game_cam", game_cam)
					var tc := Camera3D.new()
					get_tree().current_scene.add_child(tc)
					tc.fov = game_cam.fov
					tc.near = game_cam.near
					tc.far = game_cam.far
					tc.global_transform = game_cam.global_transform
					tc.global_basis = Basis(Vector3.UP, deg_to_rad(float(p[1]))) * tc.global_basis
					tc.rotate_object_local(Vector3.RIGHT, deg_to_rad(float(p[2])))
					tc.make_current()
					set_meta("bd_test_cam", tc)
					_log("camturn %s %s: looking %s" % [p[1], p[2], -tc.global_basis.z])
			"netcut":  # netcut: break this copy's WebRTC connections, as a mobile network dropping them would
				var netc := get_node_or_null(^"/root/BuckdroidNet")
				if netc:
					for pp in netc._peers.values():
						pp.pc.close()
					_log("netcut: closed %d connections" % netc._peers.size())
			"net":  # net: log the multiplayer state
				var net := get_node_or_null(^"/root/BuckdroidNet")
				var gs := get_node_or_null(^"/root/GlobalSteam")
				if net:
					_log("net: lobby %d host %s owner %d members %s | game: LOBBY_ID %s HOST_ID %s MEMBERS %s" % [net.lobby_id,
							net.is_host, net.owner_id, net.members, gs.LOBBY_ID if gs else "?", gs.HOST_ID if gs else "?",
							gs.LOBBY_MEMBERS if gs else "?"])
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
			"remesh":  # remesh <name substring, _ for spaces | *>: rebuild matching meshes from their own arrays in the
				# running engine's current format (tests whether a newer engine's on-load upgrade of old meshes is at fault)
				var rn := p[1].replace("_", " ").to_lower()
				var rc := 0
				var t0 := Time.get_ticks_msec()
				for mi in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):
					if mi.mesh is ArrayMesh and (rn == "*" or String(mi.name).to_lower().contains(rn)):
						var old: ArrayMesh = mi.mesh
						var nm := ArrayMesh.new()
						for s in old.get_surface_count():
							var flags := 0
							if old.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS:
								flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
							nm.add_surface_from_arrays(old.surface_get_primitive_type(s), old.surface_get_arrays(s), [], {}, flags)
							nm.surface_set_material(s, old.surface_get_material(s))
						nm.custom_aabb = old.custom_aabb
						mi.mesh = nm
						rc += 1
				_log("remesh %s: %d meshes in %d ms" % [rn, rc, Time.get_ticks_msec() - t0])
			"procscan":  # procscan <frames>: for every script whose nodes run _process, pause those nodes for <frames>
				# frames and log how much the per-frame script time drops (finds the expensive game scripts)
				var groups := {}
				for nd in get_tree().root.find_children("*", "Node", true, false):
					if nd.is_processing() and nd.get_script() != null and nd != self:
						var sp: String = nd.get_script().resource_path
						if not groups.has(sp):
							groups[sp] = []
						groups[sp].append(nd)
				var frames := int(p[1])
				var measure := func() -> float:
					var tot := 0.0
					for i in frames:
						await get_tree().process_frame
						tot += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
					return tot / frames
				var results := []
				await measure.call()   # warm-up window, discarded
				for sp in groups:
					var before: float = await measure.call()
					for nd in groups[sp]:
						if is_instance_valid(nd):
							nd.set_process(false)
					var during: float = await measure.call()
					for nd in groups[sp]:
						if is_instance_valid(nd):
							nd.set_process(true)
					var after: float = await measure.call()
					results.append([(before + after) / 2.0 - during, sp, groups[sp].size()])
				results.sort_custom(func(a, b): return a[0] > b[0])
				for r in results.slice(0, 15):
					_log("procscan %.2f ms  %s  (%d nodes)" % [r[0], r[1], r[2]])
				_log("procscan done: %d scripts" % groups.size())
			"treescan":  # treescan <frames>: pause each top-level child of the scene (and each autoload) in turn and log how
				# much per-frame process time drops; covers scripts, animations and engine-internal processing alike
				var tops: Array = get_tree().current_scene.get_children()
				for c in get_tree().root.get_children():
					if c != get_tree().current_scene and c != self:
						tops.append(c)
				var tm := func() -> float:
					var tot := 0.0
					for i in int(p[1]):
						await get_tree().process_frame
						tot += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
					return tot / int(p[1])
				await tm.call()
				var res := []
				for c in tops:
					if not is_instance_valid(c):
						continue
					var b: float = await tm.call()
					var old_mode: int = c.process_mode
					c.process_mode = Node.PROCESS_MODE_DISABLED
					var d: float = await tm.call()
					c.process_mode = old_mode
					var a: float = await tm.call()
					res.append([(b + a) / 2.0 - d, String(c.name)])
				res.sort_custom(func(x, y): return x[0] > y[0])
				for r in res.slice(0, 12):
					_log("treescan %.2f ms  %s" % [r[0], r[1]])
				_log("treescan done: %d parts" % res.size())
			"animscan":  # animscan <frames>: per-frame process time with all AnimationPlayers/AnimationTrees paused vs running,
				# and the number of playing players, to see what engine-side animation costs
				var mixers := []
				for nd in get_tree().root.find_children("*", "AnimationMixer", true, false):
					if nd.active:
						mixers.append(nd)
				var playing := 0
				for m in mixers:
					if m is AnimationPlayer and m.is_playing():
						playing += 1
				var am := func() -> float:
					var tot := 0.0
					for i in int(p[1]):
						await get_tree().process_frame
						tot += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
					return tot / int(p[1])
				await am.call()
				var on1: float = await am.call()
				for m in mixers:
					m.active = false
				var off: float = await am.call()
				for m in mixers:
					m.active = true
				var on2: float = await am.call()
				_log("animscan: %d active mixers (%d players playing): process %.2f ms running, %.2f ms paused" % [
						mixers.size(), playing, (on1 + on2) / 2.0, off])
			"perfmon":  # perfmon <seconds> <label>: average CPU time per frame spent in scripts (_process), physics and
				# rendering setup, from Godot's own monitors; separates script cost from GPU-bound waiting
				var pm_end := Time.get_ticks_msec() + int(float(p[1]) * 1000.0)
				var vp_rid := get_viewport().get_viewport_rid()
				RenderingServer.viewport_set_measure_render_time(vp_rid, true)
				var sums := [0.0, 0.0, 0.0, 0.0]
				var n := 0
				while Time.get_ticks_msec() < pm_end:
					await get_tree().process_frame
					sums[0] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
					sums[1] += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
					sums[2] += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid) + RenderingServer.get_frame_setup_time_cpu()
					sums[3] += Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
					n += 1
				_log("perfmon %s: process %.2f ms, physics %.2f ms, render cpu %.2f ms, navigation %.2f ms (%d frames)" % [
						p[2] if p.size() > 2 else "", sums[0] / n, sums[1] / n, sums[2] / n, sums[3] / n, n])
			"skintest":  # skintest <exact mesh name, + for spaces> <refresh|noskin|noskel|info>: skinning experiments
				for mi in get_tree().current_scene.find_children("*", "MeshInstance3D", true, false):
					if String(mi.name) != p[1].replace("+", " "):
						continue
					match p[2]:
						"refresh":
							var sp: NodePath = mi.skeleton
							mi.skeleton = NodePath()
							mi.skeleton = sp
						"noskin":
							mi.skin = null
						"noskel":
							mi.skeleton = NodePath()
					var skn = mi.get_node_or_null(mi.skeleton)
					_log("skintest %s %s: skeleton=%s (%s) skin=%s binds=%d gpos=%s scale=%s" % [mi.get_path(), p[2], mi.skeleton,
							skn.get_class() if skn else "none", mi.skin != null, mi.skin.get_bind_count() if mi.skin else 0,
							mi.global_position, mi.global_transform.basis.get_scale()])
			"lightoff":  # lightoff <exact light name> <true|false>: hide a light by its exact name (underscores kept)
				for l in get_tree().current_scene.find_children("*", "Light3D", true, false):
					if String(l.name) == p[1].replace("+", " "):
						l.visible = p[2] != "true"
						_log("lightoff %s = %s" % [l.get_path(), p[2]])
			"geodump":  # geodump <file name>: every 3D object's path, visibility, world position and scale, into <out>/<file>
				# (compare two engine versions at the same moment of a script)
				var gf := FileAccess.open(_out.path_join(p[1]), FileAccess.WRITE)
				for n in get_tree().current_scene.find_children("*", "Node3D", true, false):
					var gt: Transform3D = n.global_transform
					gf.store_line("%s|%s|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f" % [get_tree().current_scene.get_path_to(n), n.is_visible_in_tree(),
							gt.origin.x, gt.origin.y, gt.origin.z, gt.basis.get_scale().x, gt.basis.get_scale().y, gt.basis.get_scale().z])
				gf.close()
				_log("geodump " + p[1])
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
			"watch":  # watch <name substring, _ for spaces> <frames>: log every frame where a matching mesh's visible or
				# transparency changes (for one-frame flicker hunts)
				var wn := p[1].replace("_", " ").to_lower()
				var nodes := []
				for g in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if String(g.name).to_lower().contains(wn) or str(g.get_path()).to_lower().contains(wn):
						nodes.append(g)
				var last := {}
				_log("watch: %d nodes matching '%s'" % [nodes.size(), wn])
				for f in int(p[2]):
					for g in nodes:
						if not is_instance_valid(g):
							continue
						var state := "vis=%s tr=%.2f" % [g.is_visible_in_tree(), g.transparency]
						var key: int = g.get_instance_id()
						if last.get(key, "") != state:
							if last.has(key):
								_log("watch frame %d %s: %s -> %s" % [Engine.get_process_frames(), g.name, last[key], state])
							last[key] = state
					await get_tree().process_frame
				_log("watch done")
			"burst":  # burst <frames> <name substring>: save every rendered frame (small JPG) and log the scene state of
				# matching meshes each frame, to tell rendering glitches from the game actually hiding things
				var bn := p[2].replace("_", " ").to_lower()
				var bnodes := []
				for g in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if str(g.get_path()).to_lower().contains(bn):
						bnodes.append(g)
				var bdir := _out.path_join("burst")
				DirAccess.make_dir_recursive_absolute(bdir)
				for f in int(p[1]):
					await RenderingServer.frame_post_draw
					var img := get_viewport().get_texture().get_image()
					img.resize(480, 270, Image.INTERPOLATE_BILINEAR)
					img.save_jpg(bdir.path_join("f%04d.jpg" % f), 0.85)
					var vis := 0
					for g in bnodes:
						if is_instance_valid(g) and g.is_visible_in_tree() and g.transparency < 0.99:
							vis += 1
					_log("burst %d frame %d visible_matching=%d" % [f, Engine.get_process_frames(), vis])
				_log("burst done")
			"watchall":  # watchall <seconds>: while the user plays, log every frame where any mesh's visibility toggles or
				# its transparency jumps by more than 0.5 in one frame, plus frame hitches, with wall-clock milliseconds
				# so a screen recording can be lined up. Rescans the scene once a second (objects come and go).
				var deadline := Time.get_ticks_msec() + int(float(p[1]) * 1000.0)
				var states := {}
				var nodes: Array = []
				var rescan_at := 0
				var last_us := Time.get_ticks_usec()
				_log("watchall start unix_ms=%d" % int(Time.get_unix_time_from_system() * 1000.0))
				while Time.get_ticks_msec() < deadline:
					if Time.get_ticks_msec() >= rescan_at:
						nodes = get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false)
						rescan_at = Time.get_ticks_msec() + 1000
					var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
					for g in nodes:
						if not is_instance_valid(g):
							continue
						var key: int = g.get_instance_id()
						var v: bool = g.is_visible_in_tree()
						var tr: float = g.transparency
						if states.has(key):
							var old: Array = states[key]
							if old[0] != v or absf(old[1] - tr) > 0.5:
								_log("watchall %d %s vis %s->%s tr %.2f->%.2f" % [now_ms, g.name, old[0], v, old[1], tr])
						states[key] = [v, tr]
					await get_tree().process_frame
					var us := Time.get_ticks_usec()
					if us - last_us > 50000:
						_log("watchall %d hitch %.0f ms" % [now_ms, (us - last_us) / 1000.0])
					last_us = us
				_log("watchall done")
			"vsync":  # vsync <on|off>: off lets the frame rate run free, so GPU time reflects the real work (with vsync at
				# 60 Hz the phone lowers its GPU clock and GPU time per frame reads flat)
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if p[1] == "on" else DisplayServer.VSYNC_DISABLED)
				_log("vsync " + p[1])
			"nodeprocess":  # nodeprocess <autoload name> <true|false>: pause an autoload's per-frame work (e.g. the shadow
				# optimizer, which would otherwise switch shadows back on during an experiment)
				var nd := get_node_or_null(NodePath("/root/" + p[1]))
				if nd:
					nd.set_process(p[2] == "true")
				_log("process %s = %s" % [p[1], p[2]])
			"unshade":  # unshade <name substring, _ for spaces>: matching meshes get unshaded copies of their materials,
				# matching Label3Ds are logged and set unshaded (tells lighting/shadow faults from objects being skipped)
				var un := p[1].replace("_", " ").to_lower()
				var count := 0
				for g in get_tree().current_scene.find_children("*", "GeometryInstance3D", true, false):
					if not str(g.get_path()).to_lower().contains(un):
						continue
					if g is Label3D:
						_log("unshade label %s shaded=%s" % [g.name, g.shaded])
						g.shaded = false
						count += 1
					elif g is MeshInstance3D and g.mesh:
						for s in g.mesh.get_surface_count():
							var m = g.get_active_material(s)
							if m is BaseMaterial3D:
								var m2: BaseMaterial3D = m.duplicate()
								m2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
								g.set_surface_override_material(s, m2)
						count += 1
				_log("unshade %s: %d objects" % [un, count])
			"flipdemo":  # flipdemo <times>: camera on the health display, then turns the shell tray open and shut <times>
				# times (the game's own "show shells"/"hide shells"), to reproduce the one-frame vanish of transparent objects
				var sp: Node = null
				for n in get_tree().current_scene.find_children("*", "Node", true, false):
					var scr: Script = n.get_script()
					if scr and scr.resource_path.ends_with("/ShellSpawner.gd"):
						sp = n
						break
				if sp == null:
					_log("flipdemo: no ShellSpawner")
				else:
					sp.camera.BeginLerp("health counter")
					await get_tree().create_timer(2.0).timeout
					_log("flipdemo start unix_ms=%d" % int(Time.get_unix_time_from_system() * 1000.0))
					for k in int(p[1]):
						sp.anim_compartment.play("show shells")
						await get_tree().create_timer(0.8).timeout
						sp.anim_compartment.play("hide shells")
						await get_tree().create_timer(0.8).timeout
					_log("flipdemo done")
			"watchrender":  # watchrender <seconds>: per frame, the renderer's own counts for the main view (objects,
				# draw calls, primitives). Logs every frame while the shell compartment turns (round start), plus any
				# one-frame dip anywhere, to tell objects dropped by culling (counts dip) from GPU-side drops.
				var deadline := Time.get_ticks_msec() + int(float(p[1]) * 1000.0)
				var vp_rid := get_viewport().get_viewport_rid()
				var comp: Node3D = get_tree().current_scene.find_child("compartment_shells", true, false)
				var hist := []  # [frame, objects, draws, prims, rot]
				var rest_rot := 0.0
				var moving_until := 0
				_log("watchrender start compartment=%s" % (comp.get_path() if comp else "none"))
				while Time.get_ticks_msec() < deadline:
					await RenderingServer.frame_post_draw
					var T := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
					var o := RenderingServer.viewport_get_render_info(vp_rid, T, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
					var d := RenderingServer.viewport_get_render_info(vp_rid, T, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
					var pr := RenderingServer.viewport_get_render_info(vp_rid, T, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
					var rot := comp.rotation.z if comp else 0.0
					var f := Engine.get_frames_drawn()
					hist.append([f, o, d, pr, rot])
					if hist.size() > 3:
						hist.pop_front()
					if absf(rot - rest_rot) > 0.001:
						moving_until = f + 3
						rest_rot = rot
					if f <= moving_until:
						_log("watchrender %d obj=%d draws=%d prims=%d rot=%.3f" % [f, o, d, pr, rot])
					elif hist.size() == 3 and hist[1][1] < hist[0][1] - 2 and hist[1][1] < hist[2][1] - 2:
						_log("watchrender dip %s" % [hist])
				_log("watchrender done")
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
					var ret = target.call(p[2], p[3]) if p.size() > 3 else target.call(p[2])
					if ret != null:
						_log("call %s.%s -> %s" % [p[1], p[2], ret])
				else:
					_log("call: %s.%s not found" % [p[1], p[2]])
			"texinfo":  # texinfo <name substring>: materials and texture formats of matching meshes
				_texinfo(p[1].to_lower())
			"vp":  # vp <viewport property> <value>
				get_viewport().set(p[1], str_to_var(p[2]))
				_log("viewport %s = %s" % [p[1], get_viewport().get(p[1])])
			"keep_touch":
				pass
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
