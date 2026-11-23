extends Node
## Buckdroid Roulette - compatibility fixes for running the game (made with Godot 4.1) on a newer Godot 4.x engine.
## Original code, MIT/GPL per the project license; contains no game code or assets.
##
## 1. Skinned meshes lose their skeleton. In Godot 4.1 MeshInstance3D.skeleton defaulted to NodePath(".."), so the
##    game's scenes never store it for meshes that sit directly under their Skeleton3D. Newer engines default to an
##    empty path, read the missing value as "no skeleton", and draw those meshes unanimated in their bind pose: the
##    corridor smoker vanishes below the floor and the dealer's head loses its pose. Fix: an empty skeleton path on a
##    mesh whose parent is a Skeleton3D is set back to "..", the 4.1 meaning.
## 2. Broken shadow meshes. Newer engines upgrade 4.1 mesh data when loading; for some meshes the separate
##    position-only shadow mesh comes out wrong and the object shadows itself (a dark box over the player's briefcase
##    hatch). Fix: each shadow mesh is rebuilt once from its own vertex arrays in the running engine's format.

var _rebuilt := {}   # original shadow mesh instance id -> rebuilt ArrayMesh
var _fixed_skeletons := 0


func _enter_tree() -> void:
	if Engine.get_version_info().hex < 0x040200:
		set_process(false)
		return
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D:
		_fix_mesh_instance.call_deferred(node)


func _fix_mesh_instance(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi):
		return
	if mi.skeleton.is_empty() and mi.get_parent() is Skeleton3D:
		mi.skeleton = NodePath("..")
		_fixed_skeletons += 1
	var mesh := mi.mesh as ArrayMesh
	if mesh and mesh.shadow_mesh:
		mesh.shadow_mesh = _rebuild(mesh.shadow_mesh)


func _rebuild(old: ArrayMesh) -> ArrayMesh:
	var key := old.get_instance_id()
	if _rebuilt.has(key):
		return _rebuilt[key]
	if _rebuilt.values().has(old):
		return old   # already one of ours
	var fresh := ArrayMesh.new()
	for s in old.get_surface_count():
		fresh.add_surface_from_arrays(old.surface_get_primitive_type(s), old.surface_get_arrays(s))
	_rebuilt[key] = fresh
	return fresh
