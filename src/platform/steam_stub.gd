## Steam stub - original code, part of Buckdroid Roulette.
##
## The PC game's engine has GodotSteam compiled in, which gives scripts a global `Steam` object. Our engine build does
## not (Steam does not exist on Android), so the installer registers this script as an autoload named "Steam". Game
## scripts then compile and run unchanged against it.
##
## No Steam account and no Steam servers. Achievements are forwarded to the Platform autoload, which keeps them on the
## device, and so is the leaderboard (this device's best score only). Lobbies and P2P packets run on our own
## peer-to-peer layer (BuckdroidNet, src/net/session.gd): it reports "logged on" when that layer is available, and the
## player's ID and name are the random ID and nickname BuckdroidNet keeps on this device.
##
## It only provides the names the supported game version uses (see docs/MULTIPLAYER.md for the list and where they are
## called). Constants carry the public Steamworks enum values.
extends Node

# --- signals the game connects to ---------------------------------------------------------------------------------
signal avatar_loaded(avatar_id: int, size: int, data: PackedByteArray)
signal join_requested(lobby_id: int, steam_id: int)
signal leaderboard_find_result(handle: int, found: int)
signal leaderboard_score_uploaded(success: int, handle: int, score_details: Dictionary)
signal leaderboard_scores_downloaded(message: String, handle: int, result: Array)
signal lobby_chat_update(lobby_id: int, changed_id: int, making_change_id: int, chat_state: int)
signal lobby_created(connect: int, lobby_id: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal p2p_session_connect_fail(steam_id: int, session_error: int)
signal p2p_session_request(remote_id: int)
signal persona_state_change(steam_id: int, flags: int)

# --- constants (Steamworks enum values) ---------------------------------------------------------------------------
const LOBBY_TYPE_FRIENDS_ONLY := 1
const LOBBY_TYPE_PUBLIC := 2
const LEADERBOARD_DATA_REQUEST_GLOBAL := 0
const LEADERBOARD_DATA_REQUEST_GLOBAL_AROUND_USER := 1
const LEADERBOARD_DATA_REQUEST_FRIENDS := 2
const P2P_SEND_RELIABLE := 2
const CHAT_ROOM_ENTER_RESPONSE_SUCCESS := 1
const CHAT_ROOM_ENTER_RESPONSE_DOESNT_EXIST := 2
const CHAT_ROOM_ENTER_RESPONSE_NOT_ALLOWED := 3
const CHAT_ROOM_ENTER_RESPONSE_FULL := 4
const CHAT_ROOM_ENTER_RESPONSE_ERROR := 5
const CHAT_ROOM_ENTER_RESPONSE_BANNED := 6
const CHAT_ROOM_ENTER_RESPONSE_LIMITED := 7
const CHAT_ROOM_ENTER_RESPONSE_CLAN_DISABLED := 8
const CHAT_ROOM_ENTER_RESPONSE_COMMUNITY_BAN := 9
const CHAT_ROOM_ENTER_RESPONSE_MEMBER_BLOCKED_YOU := 10
const CHAT_ROOM_ENTER_RESPONSE_YOU_BLOCKED_MEMBER := 11
const CHAT_MEMBER_STATE_CHANGE_ENTERED := 1
const CHAT_MEMBER_STATE_CHANGE_LEFT := 2
const CHAT_MEMBER_STATE_CHANGE_KICKED := 8
const CHAT_MEMBER_STATE_CHANGE_BANNED := 16

const LOBBY_DISTANCE_FILTER_CLOSE := 0
const LOBBY_DISTANCE_FILTER_DEFAULT := 1
const LOBBY_DISTANCE_FILTER_FAR := 2
const LOBBY_DISTANCE_FILTER_WORLDWIDE := 3
const PLAYER_NAME := "Player"

var _net: Node


func _ready() -> void:
	_net = get_node_or_null(^"/root/BuckdroidNet")
	if _net:
		_net.lobby_created.connect(func(ok: bool, id: int) -> void: lobby_created.emit(1 if ok else 0, id))
		_net.lobby_joined.connect(func(id: int, response: int) -> void: lobby_joined.emit(id, 0, false, response))
		_net.member_changed.connect(func(id: int, member: int, state: int) -> void:
			lobby_chat_update.emit(id, member, member, state)
			persona_state_change.emit(member, 1))
		_net.lobby_list.connect(func(ids: Array) -> void: lobby_match_list.emit(ids))


func _mp() -> bool:
	return _net != null and _net.available

# --- core ---------------------------------------------------------------------------------------------------------
func steamInit(_retrieve_stats := true, _app_id := 0, _embed_callbacks := false) -> Dictionary:
	return {"status": 20, "verbal": "Steam is not available on this platform (offline)."}

func run_callbacks() -> void:
	pass

func loggedOn() -> bool:
	return _mp()

func getSteamID() -> int:
	return _net.my_id if _net else 0

func getPersonaName() -> String:
	return _net.my_name if _net else PLAYER_NAME

func getFriendPersonaName(steam_id: int) -> String:
	return _net.member_name(steam_id) if _net else PLAYER_NAME

func getPlayerAvatar(_size := 2, _steam_id := 0) -> void:
	pass

func isSteamRunningOnSteamDeck() -> bool:
	return false

func activateGameOverlayInviteDialog(lobby_id: int) -> void:
	# No Steam overlay: copy the short lobby code (src/net/lobby_code.gd) so it can be sent to friends; pasted back,
	# BuckdroidBoot turns it into the 18 digits the game's "join with ID" expects.
	if lobby_id != 0:
		var code: String = load("res://buckdroid/net/lobby_code.gd").encode(lobby_id)
		DisplayServer.clipboard_set(code)
		var toast := get_node_or_null(^"/root/BuckdroidToast")
		if toast and toast.has_method("show_text"):
			toast.show_text("Lobby code copied: " + code)

# --- achievements / stats: kept on the device by the Platform layer ----------------------------------------------
func setAchievement(api_name: String) -> bool:
	_platform_call("unlock_achievement", api_name)
	return true

func clearAchievement(api_name: String) -> bool:
	_platform_call("clear_achievement", api_name)
	return true

func storeStats() -> bool:
	return true

# --- leaderboards: an offline board holding this device's best score ---------------------------------------------
const LOCAL_BOARD_HANDLE := 1

func setLeaderboardDetailsMax(max_details: int) -> int:
	return max_details

func findLeaderboard(_name: String) -> void:
	call_deferred("emit_signal", "leaderboard_find_result", LOCAL_BOARD_HANDLE, 1)

func uploadLeaderboardScore(score: int, keep_best := true, details := PackedInt32Array(), _handle := 0) -> void:
	var changed = _platform_get("submit_local_score", [score, keep_best, details], false)
	call_deferred("emit_signal", "leaderboard_score_uploaded", 1, LOCAL_BOARD_HANDLE,
			{"score": score, "score_changed": int(changed), "new_rank": 1, "prev_rank": 1})

func downloadLeaderboardEntries(_start: int, _end: int, _type := 0, _handle := 0) -> void:
	call_deferred("emit_signal", "leaderboard_scores_downloaded", "ok", LOCAL_BOARD_HANDLE, _local_entries())

func getLeaderboardEntryCount(_handle := 0) -> int:
	return _local_entries().size()

func _local_entries() -> Array:
	var best = _platform_get("local_best_score", [], null)
	if best == null:
		return []
	return [{"score": best.score, "steam_id": 0, "global_rank": 1, "ugc_handle": 0, "details": best.details}]

# --- lobbies and P2P: our peer-to-peer layer (BuckdroidNet) ------------------------------------------------------
func createLobby(_type := 2, max_members := 2) -> void:
	if _net:
		_net.create_lobby(max_members)

func joinLobby(lobby_id: int) -> void:
	if _net:
		_net.join_lobby(lobby_id)
	else:
		lobby_joined.emit.call_deferred(lobby_id, 0, false, CHAT_ROOM_ENTER_RESPONSE_ERROR)

func leaveLobby(_lobby_id: int) -> void:
	if _net:
		_net.leave_lobby()

func requestLobbyList() -> void:
	if _net:
		_net.request_lobby_list()
	else:
		lobby_match_list.emit.call_deferred([])

func addRequestLobbyListDistanceFilter(_filter: int) -> void:
	pass

func addRequestLobbyListResultCountFilter(_count: int) -> void:
	pass

func getLobbyData(lobby_id: int, key: String) -> String:
	if not _net:
		return ""
	if lobby_id == _net.lobby_id:
		return str(_net.lobby_data.get(key, ""))
	var f: Dictionary = _net.found_lobby(lobby_id)     # lobbies found on the local network
	if key == "member_count" and not f.is_empty():
		return str(f.members)
	if key == "player_limit" and not f.is_empty():
		return str(f.limit)
	return ""

func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
	if _net and lobby_id == _net.lobby_id and _net.is_host:
		_net.set_data(key, value)
		return true
	return false

func setLobbyJoinable(lobby_id: int, joinable: bool) -> bool:
	if _net and lobby_id == _net.lobby_id and _net.is_host:
		_net.joinable = joinable
		return true
	return false

func setLobbyType(lobby_id: int, _type: int) -> bool:
	return _net != null and lobby_id == _net.lobby_id and _net.is_host

func setLobbyMemberLimit(lobby_id: int, limit: int) -> bool:
	if _net and lobby_id == _net.lobby_id and _net.is_host:
		_net.set_limit(limit)
		return true
	return false

func getLobbyOwner(lobby_id: int) -> int:
	return _net.owner_id if _net and lobby_id == _net.lobby_id else 0

func getNumLobbyMembers(lobby_id: int) -> int:
	return _net.members.size() if _net and lobby_id == _net.lobby_id else 0

func getLobbyMemberByIndex(lobby_id: int, index: int) -> int:
	if _net and lobby_id == _net.lobby_id and index >= 0 and index < _net.members.size():
		return _net.members[index].id
	return 0

func acceptP2PSessionWithUser(_steam_id: int) -> bool:
	return _mp()

func allowP2PPacketRelay(_allow: bool) -> bool:
	return _mp()

func closeP2PSessionWithUser(_steam_id: int) -> bool:
	return _mp()

func getAvailableP2PPacketSize(_channel := 0) -> int:
	return _net.available_packet_size() if _net else 0

func readP2PPacket(_size: int, _channel := 0) -> Dictionary:
	return _net.read_packet() if _net else {}

func sendP2PPacket(steam_id: int, data: PackedByteArray, _send_type := 2, _channel := 0) -> bool:
	return _net.send_game(steam_id, data) if _net else false

# --- helpers ------------------------------------------------------------------------------------------------------
func _platform_get(method: String, args: Array, fallback):
	var platform := get_node_or_null(^"/root/BuckdroidPlatform")
	if platform and platform.has_method(method):
		return platform.callv(method, args)
	return fallback

func _platform_call(method: String, arg) -> void:
	var platform := get_node_or_null(^"/root/BuckdroidPlatform")
	if platform and platform.has_method(method):
		platform.call(method, arg)
