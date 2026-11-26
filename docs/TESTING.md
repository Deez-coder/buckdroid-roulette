# Testing Buckdroid Roulette (1.0.0, 2026-11-25)

For people trying the app. It contains no part of Buckshot Roulette: you need your own copy from Steam.

## What you need
- An Android phone, 64-bit (arm64), Android 7 or newer with Vulkan. Only tested on a Galaxy S24 Ultra so far.
- Buckshot Roulette from Steam, version **v2.2.0 (hotfix 6)** (other versions are refused at setup).
- About 1.2 GB free while setting up, 0.8 GB afterwards.

## Install and set up
1. Install the APK (allow installing from this source when Android asks).
2. On your PC, open the game's folder (Steam: right-click the game > Manage > Browse local files) and copy
   `Buckshot Roulette.exe` to the phone.
3. Open Buckdroid Roulette, tap "Pick Buckshot Roulette.exe" and choose the file. Setup takes a couple of minutes;
   everything stays on the phone.
4. Tap Play. You can delete the .exe afterwards.
5. After installing a newer version, the first start updates the game's scripts (about a minute), then the game opens.

## Multiplayer
- One player hosts a table (Multiplayer). The 18-digit lobby ID is shown at the top right ("Copy lobby ID" copies
  it). The others join with the game's "join with pasted ID", or tap "TYPE A LOBBY ID" and type it. Spaces don't
  matter either way. Everyone needs the same test build.
- Same Wi-Fi works best; over mobile data most networks work, some strict ones do not (the app says so).
- Look around: two fingers (one finger on an empty spot in Buttons mode, or a controller's left trigger + stick).
- Players in a lobby can see each other's internet address, as in any peer-to-peer game.
- Chat: tap CHAT (top right, in the lobby and during a match). New messages show briefly under the button while the
  box is closed; drag the message list to scroll; Enter or the keyboard's Send key sends. Chat can be turned off in the
  launcher (Game tab, Multiplayer).
- The lobby buttons, the lobby ID box and the chat work in every control mode, Buttons mode included.
- The performance overlay (Graphics: FPS counter) shows the ping while in a lobby.

## Known issues
- The phone gets warmer in multiplayer than in single player; the heat guard eases graphics when it gets hot.
  "Cooler shadows" (Graphics) runs cooler with almost no visible difference.
- The screen can still switch to 120 Hz briefly while touching (some phones).
- In the multiplayer lobby the cursor is hidden for a few seconds while the lobby's intro plays (as on PC).

## Reporting problems
Say what phone you have, what you did, and what happened, and send the logs: launcher -> About -> Report a problem ->
**Export logs** saves a zip to Downloads and opens the share menu. It holds the game's logs, the settings and the phone
model, no game files or passwords (it does include your multiplayer name, player ID and lobby IDs).
Graphics -> Advanced -> "Performance log" adds performance and heat logs if asked for them.
