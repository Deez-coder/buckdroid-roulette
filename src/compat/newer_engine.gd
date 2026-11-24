extends Node
## Buckdroid Roulette - compatibility fixes for running the game (made with Godot 4.1) on a newer Godot 4.x engine.
## Original project code; contains no game code or assets.
##
## 1. Skinned meshes lose their skeleton. In Godot 4.1 MeshInstance3D.skeleton defaulted to NodePath(".."), so the
##    game's scenes never store it for meshes that sit directly under their Skeleton3D. Newer engines default to an
##    empty path, read the missing value as "no skeleton", and draw those meshes unanimated in their bind pose: the
##    corridor smoker vanishes below the floor and the dealer's head loses its pose. Fix: an empty skeleton path on a
##    mesh whose parent is a Skeleton3D is set back to "..", the 4.1 meaning. (Verified on 4.6.3.)
## 2. Broken shadow meshes. Newer engines upgrade 4.1 mesh data when loading; for some meshes the separate
##    position-only shadow mesh comes out wrong and the object shadows itself (a dark box over the player's briefcase
##    hatch). Changing a loaded mesh's shadow_mesh in place crashes 4.6, so instead each mesh with a shadow mesh is
##    replaced by a fresh copy built from its own vertex arrays (and a fresh shadow mesh), once per mesh resource.

var _fix_skeletons := true
var _fix_shadow_meshes := true
var _fresh := {}          # original mesh instance id -> fresh ArrayMesh
var _fixed_skeletons := 0
var _rebuild_ms := 0


func _enter_tree() -> void:
	if Engine.get_version_info().hex < 0x040200:
		return
	# Dev switches to test the fixes one at a time.
	_fix_skeletons = not OS.get_cmdline_user_args().has("--bd-compat-no-skeleton")
	_fix_shadow_meshes = not OS.get_cmdline_user_args().has("--bd-compat-no-shadowmesh")
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D:
		_fix_mesh_instance.call_deferred(node)


func _fix_mesh_instance(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi):
		return
	if _fix_skeletons and mi.skeleton.is_empty() and mi.get_parent() is Skeleton3D:
		mi.skeleton = NodePath("..")
		_fixed_skeletons += 1
	var mesh := mi.mesh as ArrayMesh
	if _fix_shadow_meshes and mesh and mesh.shadow_mesh and mesh.get_blend_shape_count() == 0:
		mi.mesh = _fresh_copy(mesh)


func _fresh_copy(old: ArrayMesh) -> ArrayMesh:
	var key := old.get_instance_id()
	if _fresh.has(key):
		return _fresh[key]
	var t0 := Time.get_ticks_usec()
	var fresh := ArrayMesh.new()
	for s in old.get_surface_count():
		var flags := 0
		if old.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS:
			flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		fresh.add_surface_from_arrays(old.surface_get_primitive_type(s), old.surface_get_arrays(s), [], {}, flags)
		fresh.surface_set_material(s, old.surface_get_material(s))
		fresh.surface_set_name(s, old.surface_get_name(s))
	fresh.custom_aabb = old.custom_aabb
	var old_shadow := old.shadow_mesh
	if old_shadow:
		var shadow := ArrayMesh.new()
		for s in old_shadow.get_surface_count():
			shadow.add_surface_from_arrays(old_shadow.surface_get_primitive_type(s), old_shadow.surface_get_arrays(s))
		fresh.shadow_mesh = shadow
	_fresh[key] = fresh
	_fresh[fresh.get_instance_id()] = fresh   # a fresh copy is never copied again
	_rebuild_ms += (Time.get_ticks_usec() - t0) / 1000
	return fresh


func stats() -> String:
	return "skeleton paths fixed: %d, meshes rebuilt: %d in %d ms" % [_fixed_skeletons, _fresh.size() / 2, _rebuild_ms]
