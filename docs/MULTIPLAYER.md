# Multiplayer plan (recon 2026-11-24)

Goal (user decision): online multiplayer between phones, peer-to-peer, by room code, plus local Wi-Fi play and an in-game
chat. No Steam: Android has no Steam client, and this project never fakes or bypasses Steam logins, so play with PC Steam
players is out of scope.

## What the game asks for (recon of the game's own scripts, local only)

The game does **not** use Godot's high-level multiplayer (no `@rpc`, no MultiplayerPeer). Everything goes through
GodotSteam calls, almost all in four scripts:

| Area | Steam calls | Where |
| --- | --- | --- |
| Lobbies | `createLobby`, `joinLobby`, `leaveLobby`, `getNumLobbyMembers`, `getLobbyMemberByIndex`, `getLobbyOwner`, `setLobbyData`/`getLobbyData`, `setLobbyType`, `setLobbyJoinable`, `setLobbyMemberLimit`; signals `lobby_created`, `lobby_joined` (with Steam's enter-response codes), `lobby_chat_update` (entered / left / kicked) | MP_LobbyManager |
| Traffic | `sendP2PPacket(target, bytes, P2P_SEND_RELIABLE, channel)`, `getAvailableP2PPacketSize`, `readP2PPacket`, `acceptP2PSessionWithUser`, `closeP2PSessionWithUser`, `allowP2PPacketRelay`; signals `p2p_session_request`, `p2p_session_connect_fail` | MP_PacketManager |
| Public list | `requestLobbyList`, distance and count filters, `lobby_match_list` | MP_Matchmaking |
| Names, invites | `getFriendPersonaName`, `getPlayerAvatar` / `avatar_loaded`, `activateGameOverlayInviteDialog`, `join_requested`, `persona_state_change` | several |

How the game uses them:
- **Star around the host.** Clients send to the host (`send_p2p_packet_directly_to_host` / `_through_host`) and the host
  forwards to everyone. A client already drops packets that are not from the host, and everyone drops packets from
  kicked players (`USER_ID_LIST_TO_IGNORE`).
- **Packets** are `var_to_bytes(Dictionary)`, GZIP-compressed, sent reliable. The receiver decompresses with no size limit
  and decodes with `bytes_to_var` (objects not allowed, so no code can arrive this way).
- **Joining by code already exists:** the lobby screen has "copy lobby ID" and "join with pasted ID" (clipboard). A room
  code can therefore simply *be* the lobby ID the game shows and pastes.
- The game has its own version check between host and clients, and kicking by the host.
- Leaderboards and achievements are separate (single player) and stay stubbed.

**Consequence:** the whole network layer can live in our Steam replacement (`src/platform/steam_stub.gd` and new code
behind it). The game's scripts stay unchanged; the game "thinks" it is talking to Steam.

## Design

### Connections: direct, phone to phone
- **WebRTC data channels** (Godot's WebRTC API, with the official `webrtc-native` GDExtension, MIT, built from source
  for arm64 and added to the APK). One reliable, ordered channel for game packets (= `P2P_SEND_RELIABLE`), one for chat
  and our own control messages.
- **Topology:** every client connects to the host only (the game's own star). All game traffic travels directly between
  the phones; nothing passes through a server of ours or anyone else's.
- **Getting through routers:** ICE with public STUN servers (Google, Cloudflare). Works for most home Wi-Fi and many mobile
  networks. Where both sides sit behind strict carrier NAT, a direct path is impossible: the app says so plainly. An
  advanced setting accepts the player's own TURN relay; there is no relay by default.

### Room codes and signalling (the only part that touches third parties)
- The host's lobby gets a **room code**: 10 characters of base32 (50 random bits), shown and copied by the game's own
  "copy lobby ID" button (the code encodes into the 64-bit lobby ID the game expects).
- To find each other, phones exchange a few messages (WebRTC offer and answer) through **public signalling points**,
  several at once for redundancy: public WebTorrent trackers (made for exactly this) and public MQTT brokers over
  secure WebSockets. Nothing to host or pay for.
- **The signalling points learn nothing useful:** the room is addressed by `SHA-256("buckdroid" + code)`, never the code,
  and every message is encrypted and authenticated with a key derived from the code (AES-256-CBC + HMAC-SHA-256,
  encrypt-then-MAC, from Godot's Crypto classes). A relay can drop messages but cannot read, forge or redirect them.
- **No man in the middle:** the WebRTC offer and answer carry each side's DTLS certificate fingerprint. Since those
  messages are authenticated with the room key, a connection only completes with someone who knows the code.

### Local Wi-Fi play
- Same lobby code flow, plus discovery: the host announces its lobby on the local network (UDP broadcast, port in the
  dynamic range), and the game's own lobby list (`requestLobbyList`) shows lobbies on this network. Signalling then runs
  directly over the local network, so local play works without internet.
- The internet lobby list stays empty (no public lobby directory: avoids strangers and abuse).

### Security and safety
- **Encrypted end to end:** WebRTC always encrypts (DTLS 1.2+, SRTP not used); signalling is encrypted as above.
- **Only invited players:** joining needs the room code; the host's game can kick (the game's own button), and a kicked
  player's ID is refused on reconnect for that lobby.
- **Untrusted input:** before handing a packet to the game, our layer checks size (max 64 KB compressed) and decompresses
  it itself with a limit (max 1 MB) so a hostile peer cannot send a GZIP bomb into the game's unlimited decompress.
  Per-peer rate limits (packets per second, bytes per second); a peer over the limit is dropped.
- **Identity:** each install gets a random 64-bit player ID (stored in the app folder) and the player's chosen nickname
  (launcher setting). No accounts, no phone numbers, no Steam data.
- **Privacy note (in the app):** as in any peer-to-peer game, the players in a lobby can see each other's IP address,
  and the public signalling points see that a device asked for some room. No game content or chat goes through them.
- Stays within the hard rules: our code only, no game assets, nothing about DRM.

### Consistency
- Reliable ordered channels match what the game expects from Steam reliable packets.
- Heartbeats every 2 s; a peer silent for 10 s counts as gone, reported to the game as `lobby_chat_update` LEFT.
- Network changes (Wi-Fi to mobile data): ICE restart within a 15 s grace period before counting the peer as gone.
- Our handshake carries the protocol version and the converted game's version (from versions.json); mismatches are
  refused with a clear message before the game's own version check.
- Host leaves: Steam would pick a new owner; with a star the lobby ends cleanly for everyone, with a message. Host
  migration (clients reconnecting to a new host) is a later step.

### In-game chat
- A small chat button in the lobby and during a multiplayer match opens a chat box (last 50 messages, text field).
- Messages go over the chat channel to the host, which forwards them (same star). Plain text only (no BBCode or links
  rendered), 200 characters, 1 message per second per player, shown with the sender's nickname.
- Per-player mute; a launcher setting turns chat off entirely.

## Steps
1. **Spike:** build `webrtc-native` for Android arm64 and Windows, load it from our payload in the converted game, and
   connect the phone to the PC build over a local test (proves the GDExtension loads on 4.6 and the data channel works).
2. **Steam replacement, lobbies and packets:** emulate the calls above over a transport interface, first with a local
   loopback transport for tests (two game instances on the PC), then WebRTC.
3. **Local Wi-Fi:** discovery and local signalling. Test phone and PC on the same network.
4. **Room codes:** public signalling with encryption; test phone on mobile data with the PC on home Wi-Fi.
5. **Security limits, heartbeats, reconnects.**
6. **Chat.**
7. Launcher: nickname, chat on/off, optional TURN server; remove the current multiplayer lock in BuckdroidBoot.

## Open questions to verify during the spike
- `webrtc-native` on Godot 4.6 (GDExtension compatibility) and loading a GDExtension that is not in the APK's original
  extension list (it must be in `res://.godot/extension_list.cfg` of the converted pack and its `.so` in the APK).
- Whether the game's multiplayer scenes run on 4.6 as they are (the 4.6 adaptations relaxed some exports already).
- Terms of use of each public signalling service; keep the list configurable.
