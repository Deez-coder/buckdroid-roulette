## Steam stub - original code, part of Buckdroid Roulette.
##
## The PC game's engine has GodotSteam compiled in, which gives scripts a global `Steam` object. Our engine build does
## not (Steam does not exist on Android), so the installer registers this script as an autoload named "Steam". Game
## scripts then compile and run unchanged against it.
##
## It is an offline Steam: no account, no network, never "logged on". Achievements are forwarded to the Platform
## autoload, which keeps them on the device, and so is the leaderboard (this device's best score only). Lobby and P2P functions answer "nothing there" and never emit their
## signals, so the multiplayer code (which is unreachable anyway, see BuckdroidBoot) has nothing to react to.
##
## It only provides the names the supported game version uses (see docs/MULTIPLAYER_NOTES.md for the list and where
## they are called). Constants carry the public Steamworks enum values.
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

const PLAYER_NAME := "Player"

# --- core ---------------------------------------------------------------------------------------------------------
func steamInit(_retrieve_stats := true, _app_id := 0, _embed_callbacks := false) -> Dictionary:
	return {"status": 20, "verbal": "Steam is not available on this platform (offline)."}

func run_callbacks() -> void:
	pass

func loggedOn() -> bool:
	return false

func getSteamID() -> int:
	return 0

func getPersonaName() -> String:
	return PLAYER_NAME

func getFriendPersonaName(_steam_id: int) -> String:
	return PLAYER_NAME

func getPlayerAvatar(_size := 2, _steam_id := 0) -> void:
	pass

func isSteamRunningOnSteamDeck() -> bool:
	return false

func activateGameOverlayInviteDialog(_lobby_id: int) -> void:
	pass

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

# --- lobbies and P2P: unavailable --------------------------------------------------------------------------------
func createLobby(_type := 2, _max_members := 2) -> void:
	pass

func joinLobby(_lobby_id: int) -> void:
	pass

func leaveLobby(_lobby_id: int) -> void:
	pass

func requestLobbyList() -> void:
	pass

func addRequestLobbyListDistanceFilter(_filter: int) -> void:
	pass

func addRequestLobbyListResultCountFilter(_count: int) -> void:
	pass

func getLobbyData(_lobby_id: int, _key: String) -> String:
	return ""

func setLobbyData(_lobby_id: int, _key: String, _value: String) -> bool:
	return false

func setLobbyJoinable(_lobby_id: int, _joinable: bool) -> bool:
	return false

func setLobbyType(_lobby_id: int, _type: int) -> bool:
	return false

func setLobbyMemberLimit(_lobby_id: int, _limit: int) -> bool:
	return false

func getLobbyOwner(_lobby_id: int) -> int:
	return 0

func getNumLobbyMembers(_lobby_id: int) -> int:
	return 0

func getLobbyMemberByIndex(_lobby_id: int, _index: int) -> int:
	return 0

func acceptP2PSessionWithUser(_steam_id: int) -> bool:
	return false

func allowP2PPacketRelay(_allow: bool) -> bool:
	return false

func closeP2PSessionWithUser(_steam_id: int) -> bool:
	return false

func getAvailableP2PPacketSize(_channel := 0) -> int:
	return 0

func readP2PPacket(_size: int, _channel := 0) -> Dictionary:
	return {}

func sendP2PPacket(_steam_id: int, _data: PackedByteArray, _send_type := 2, _channel := 0) -> bool:
	return false

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
