# Buckdroid Roulette

An Android launcher that lets people who own **Buckshot Roulette** on Steam play their own copy on an Android phone.

- **You need to own the game.** The app contains no part of Buckshot Roulette: no game files, art, audio, music, scripts or
  other content. You copy the game file from your own Steam installation to your phone, and the app converts it there.
- **Buy the game:** [Buckshot Roulette on Steam](https://store.steampowered.com/app/2835570/Buckshot_Roulette/).
- **Not affiliated** with Mike Klubnika, CRITICAL REFLEX or Valve. Buckshot Roulette is their work and trademark.
- Nothing converted on your phone is ever uploaded or shared by the app. Never share or publish converted game data.

## How it works

1. Install the Buckdroid Roulette app (the launcher APK; the only file this project publishes).
2. Copy `Buckshot Roulette.exe` from your Steam folder to the phone and pick it in the app.
3. The app checks that it is a supported version, converts it for the phone (textures, settings, Android fixes) and
   stores the result in its own folder.
4. Press Play.

Multiplayer is not available yet (it needs Steam); single player, the full game, works.

## License

The project's own code (everything in this repository) is licensed under the **GNU General Public License v3.0 or later**,
see [LICENSE](LICENSE). The license covers only this project's code. It does not cover, and grants no rights to,
Buckshot Roulette or any of its content.

The app is built on the [Godot Engine](https://godotengine.org) (MIT license) with a few patches in `engine/patches46/`,
and its launcher look comes from the author's own launcher UI kit (GPL-3.0-or-later).

## For developers

Start with [docs/PROGRESS.md](docs/PROGRESS.md) (state, decisions, measurements) and [CHANGELOG.md](CHANGELOG.md).
Engine build notes: [engine/README.md](engine/README.md). Before every commit run `python tools/audit_repo.py`, which
fails if anything that looks like game content would enter the repository.
