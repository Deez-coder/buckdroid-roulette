## BuckdroidPlatform - original code, part of Buckdroid Roulette.
##
## The single place that knows which platform the game runs on. Gameplay never calls it directly: the Steam stub
## and the Buckdroid autoloads do. On Android (and on desktop test builds without Steam) achievements are kept in
## user://buckdroid/achievements.cfg, and the best Double-or-Nothing score in user://buckdroid/scores.cfg.
extends Node

signal achievement_unlocked(api_name: String)

const DIR := "user://buckdroid"
const ACHIEVEMENTS_FILE := DIR + "/achievements.cfg"
const SCORES_FILE := DIR + "/scores.cfg"

var is_android := OS.get_name() == "Android"
var _achievements := ConfigFile.new()


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_achievements.load(ACHIEVEMENTS_FILE)  # a missing file just means none yet


func unlock_achievement(api_name: String) -> void:
	if _achievements.has_section_key("unlocked", api_name):
		return
	_achievements.set_value("unlocked", api_name, Time.get_unix_time_from_system())
	_achievements.save(ACHIEVEMENTS_FILE)
	achievement_unlocked.emit(api_name)


func clear_achievement(api_name: String) -> void:
	if _achievements.has_section_key("unlocked", api_name):
		_achievements.erase_section_key("unlocked", api_name)
		_achievements.save(ACHIEVEMENTS_FILE)


func unlocked_achievements() -> PackedStringArray:
	if not _achievements.has_section("unlocked"):
		return PackedStringArray()
	return _achievements.get_section_keys("unlocked")


## Offline leaderboard: the best Double-or-Nothing score on this device. Returns true when the stored score changed.
func submit_local_score(score: int, keep_best: bool, details: PackedInt32Array) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(SCORES_FILE)
	if keep_best and cfg.has_section_key("best", "score") and int(cfg.get_value("best", "score")) >= score:
		return false
	cfg.set_value("best", "score", score)
	cfg.set_value("best", "details", Array(details))
	cfg.save(SCORES_FILE)
	return true


func local_best_score():
	var cfg := ConfigFile.new()
	if cfg.load(SCORES_FILE) != OK or not cfg.has_section_key("best", "score"):
		return null
	return {"score": int(cfg.get_value("best", "score")), "details": cfg.get_value("best", "details", [0, 0])}
