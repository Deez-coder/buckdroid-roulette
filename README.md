# Buckdroid Roulette

I made Buckdroid Roulette so that people who own **Buckshot Roulette** on Steam can play their own copy on an Android
phone, single player and online multiplayer.

- **You need to own the game.** The app contains no part of Buckshot Roulette: no game files, art, audio, music, scripts or
  other content. You copy the game file from your own Steam installation to your phone, and the app converts it there.
- **Buy the game:** [Buckshot Roulette on Steam](https://store.steampowered.com/app/2835570/Buckshot_Roulette/).
- **Not affiliated** with Mike Klubnika, CRITICAL REFLEX or Valve. Buckshot Roulette is their work and trademark.
- Nothing converted on your phone is ever uploaded or shared by the app. Never share or publish converted game data.

## How it works

1. Install the Buckdroid Roulette app (the launcher APK; the only file I publish).
2. Copy `Buckshot Roulette.exe` from your Steam folder to the phone (Steam: right-click the game > Manage > Browse local
   files) and pick it in the app.
3. The app checks that it is a supported version, converts it for the phone (textures, settings, Android fixes) and
   stores the result in its own folder. This happens once and takes a few minutes.
4. Press Play.

Supported game version: Buckshot Roulette **v2.2.0 (hotfix 6)**, Steam, Windows (other versions are refused at setup). Phones: Android 7.0 or newer, 64-bit (arm64) with
Vulkan.

## Features

**The full game**
- The whole game as on PC, including Double or Nothing and the endings. The game's rules, items and dealer are
  never changed.
- PC-quality picture by default: the same renderer, lighting and shadows as the PC version.
- Saves are kept apart from the PC game's. Achievements and the Double or Nothing best score are kept on the phone.

**Online multiplayer**
- The game's own multiplayer mode works without Steam. Host a table, share the short lobby code (12 characters, like `7K3Q-M9XD-2PHT`), and the others paste or type it in. On the same Wi-Fi, lobbies are also found
  automatically.
- Players connect directly to each other (peer-to-peer, encrypted). There's no game server, and no account is needed.
- Short connection drops reconnect on their own; a player's seat is held for 20 seconds.
- In-game chat in the lobby and during a match, with your own nickname (set in the launcher). Chat can be turned off.
- Low latency: the phone's low-latency Wi-Fi mode is used while in a lobby, and the ping shows in the performance
  overlay.
- Note: as in any peer-to-peer game, players in a lobby can see each other's internet address.

**Controls**
- Three touch modes:
  - **Tap**: tap what you want to use.
  - **Trackpad**: drag a cursor, tap to click.
  - **Buttons**: an on-screen controller with a layout editor.
- Real controllers work too.
- Look around at the multiplayer table with two fingers (one finger on an empty spot in Buttons mode). The look speed
  can be adjusted.
- The phone's Back button works in the game's menus.

**Launcher**
- One-tap setup from your own game file, with progress shown, and quick updates when the app is updated.
- A home-screen shortcut that starts the game directly, with the game's own icon (taken from your copy).
- Graphics, performance, controls and multiplayer settings, all explained on screen.
- **Heat guard**: when the phone gets hot, the game eases the graphics step by step so it doesn't overheat. You can
  choose when it steps in, or turn it off.

## Lower-end phones

The default settings are set up to look as close to the original PC game as possible, and that is heavy: I tuned them
on a high-end phone (Galaxy S24 Ultra). On a mid-range or lower-end phone you will probably need to adjust the
graphics settings: open the launcher's **Graphics** page and pick the **Medium** or **Low** preset at the top (High is the default),
or lower single settings until the game runs smoothly. Roughly from most to least effect:

1. **3D resolution**: 70-80% is hard to notice on a phone screen and saves a lot.
2. **Cooler shadows**: almost no visible difference, noticeably cooler.
3. **Shadow detail** and **Shadow edge softness**: lower values are lighter.
4. **Moving shadows**: refresh them less often.
5. **Object detail**: Reduced.
6. **Frame rate limit**: 30 fps if the phone still struggles or gets hot.

Turn on the **Performance overlay** to see the frame rate (and in multiplayer the ping) while you try settings.

## Made with AI

I built this project with heavy use of AI. Most of the code, the engine patches, the testing tools and the
documentation were written by Claude, an AI model by Anthropic (in Claude Code). I directed the work, made the
decisions and tested everything on real phones.

## Credits

- **Me (Deez-coder)**: the project, direction, design decisions, testing.
- **Claude** (Anthropic): code, engine patches, tools, documentation.
- **v1** (Discord: `v1_fromultrakill__04991`): testing the game and multiplayer with me.
- **Buckshot Roulette** is made by Mike Klubnika and published by CRITICAL REFLEX. Buckdroid Roulette only makes your own
  copy run on Android. Please [buy the game](https://store.steampowered.com/app/2835570/Buckshot_Roulette/).

**Discord**
- [Deez-coder's server](https://discord.gg/b9GN2Ypktw): my server, the home of all my ports.
- [V Alpha server](https://discord.gg/y9YrUfNj7Y)

## License

My project's own code (everything in this repository) is licensed under the **GNU General Public License v3.0 or later**,
see [LICENSE](LICENSE). The license covers only this project's code. It does not cover, and grants no rights to,
Buckshot Roulette or any of its content.

The app is built on the [Godot Engine](https://godotengine.org) 4.6 (MIT license) with a few patches in
`engine/patches46/`, uses [webrtc-native](https://github.com/godotengine/webrtc-native) (MIT) for multiplayer, and its
launcher look comes from my own launcher UI kit (GPL-3.0-or-later).

## For developers

Start with [docs/PROGRESS.md](docs/PROGRESS.md) (state, decisions, measurements), [CHANGELOG.md](CHANGELOG.md) and
[docs/MULTIPLAYER.md](docs/MULTIPLAYER.md). Engine build notes: [engine/README.md](engine/README.md). Before every commit
run `python tools/audit_repo.py`, which fails if anything that looks like game content would enter the repository.
