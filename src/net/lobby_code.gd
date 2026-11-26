## LobbyCode - original code, part of Buckdroid Roulette (GPL-3.0-or-later).
##
## Short lobby codes: the 18-digit lobby ID written in Crockford's base32, as 12 characters in groups of four
## (e.g. 7K3Q-M9XD-2PHT). Exactly the same number, just shorter: the game and BuckdroidNet keep using the number, the
## code is only for showing, copying and typing. Crockford's alphabet has no I, L, O or U, ignores case, and reads a
## mistyped O as 0 and I or L as 1, so codes are easy to read out and type on a phone. (User request; base32 rather
## than base62 because upper and lower case would matter in base62.) The code keeps all of the ID's randomness: the ID
## also locates and protects the lobby's connection setup, so it is not made any shorter.

const ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const LENGTH := 12                       # 32^12 > 10^18, enough for every 18-digit ID
const ID_MIN := 100000000000000000
const ID_MAX := 999999999999999999


## "7K3Q-M9XD-2PHT" for an 18-digit lobby ID.
static func encode(id: int) -> String:
	var out := ""
	var v := id
	for i in LENGTH:
		out = ALPHABET[v & 31] + out
		v >>= 5
	return "%s-%s-%s" % [out.substr(0, 4), out.substr(4, 4), out.substr(8, 4)]


## The lobby ID in a code (dashes, spaces and case do not matter), or 0 if it is not a valid code.
static func decode(code: String) -> int:
	var t := code.strip_edges().to_upper().replace("-", "").replace(" ", "")
	if t.length() != LENGTH:
		return 0
	var v := 0
	for ch in t:
		match ch:
			"O": ch = "0"
			"I", "L": ch = "1"
		var d := ALPHABET.find(ch)
		if d < 0:
			return 0
		v = (v << 5) | d
	return v if v >= ID_MIN and v <= ID_MAX else 0


## A lobby ID from what a player typed or pasted: a code, or the 18 digits (spaces or dashes allowed). 0 if neither.
static func parse(text: String) -> int:
	var t := text.strip_edges()
	if t.length() > 40:
		return 0
	var digits := ""
	var only_digits := true
	for ch in t:
		if ch >= "0" and ch <= "9":
			digits += ch
		elif not ch in " -.\t":
			only_digits = false
	if only_digits and digits.length() == 18:
		return int(digits)
	return decode(t)
