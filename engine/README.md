# Engine

Buckdroid Roulette runs the game on a self-built Godot **4.1.1-stable**, the exact version the supported game uses.
The engine source is not stored here: `engine/godot/` is a local, gitignored clone of the official repository, and
our changes live as small patch files in `engine/patches/`. Godot is MIT-licensed (see its LICENSE.txt).

## Get the source and apply the patches

```text
git clone --depth 1 --branch 4.1.1-stable https://github.com/godotengine/godot.git engine/godot
git -C engine/godot apply ../patches/*.patch
```

## Patches

| Patch | What it does | Shipped? |
|---|---|---|
| `0005-separate-scene-ubo-slots.patch` | Forward+: the transparent pass gets its own scene-data uniform buffer (slot 1) and shadow passes use slots 2+, instead of all sharing slot 0 within a frame. Fixes every transparent object vanishing for single frames on Adreno when cube and paraboloid shadow redraws mix in a frame (seen at round start while the shell tray turns). Verified: 4-28 vanishes per scripted run before, 0 in 3 runs after; image unchanged. | Yes |
| `0004-android-hold-60hz.patch` | Android: makes the 60 Hz request stick during play. Requests the rate with `FRAME_RATE_COMPATIBILITY_FIXED_SOURCE` and `CHANGE_FRAME_RATE_ALWAYS` (Android 12+) and turns off touch boost for the game window (`setFrameRateBoostOnTouchEnabled(false)`, Android 15+, via reflection), because the user saw the panel return to 120 Hz while touching the screen. Verified during play: 60 Hz in 165 of 173 samples (3 s apart) while the game was in front; the 120 Hz samples were while the screen recorder ran. | Yes |
| `0003-android-preferred-refresh-rate.patch` | Android: requests the refresh rate in `display/window/buckdroid_preferred_refresh_rate` (default 0 = system; the Android overrides set 60) for the game's surface via `Surface.setFrameRate` (Android 11+). On the S24 Ultra the panel drops from 120 to 60 Hz while the game runs. | Yes |
| `0002-shadow-update-budget.patch` | Shadow-update budget: omni lights with dual-paraboloid shadows (the port's weaker fill lights) redraw a changed shadow at most once every N frames (`rendering/lights_and_shadows/positional_shadow/buckdroid_paraboloid_update_interval`, default 1 = Godot's behaviour; the Android overrides set 3). Pending changes are kept and drawn later; cube-shadow (key) lights are never delayed. PC: shadow draws while moving the shotgun 2,284 → about 1,550 per frame. Phone (S24 Ultra, uncapped): GPU 11.1 → 9.3 ms idle, 12.1 → 10.5 ms grabbing the shotgun. | Yes |
| `0001-debug-shadow-dirty-log.patch` | Development diagnostic: with the `BUCKDROID_SHADOW_DEBUG` environment variable set, logs which instances mark positional light shadows dirty and which lights actually redraw their shadow. | Dev builds only |

## Build

- Windows test runtime: `engine\build_windows.bat` (Visual Studio C++ tools, SCons). Output in `engine/godot/bin/`.
- Android SDK: `enginendroid_sdk_setup.bat licenses` then `... install` (JDK 17 and the command-line tools in `.cache/`; accepting means agreeing to Google's Android SDK License).
- Android templates: `set SCONS_DIR=<folder with scons.exe>` (if SCons isn't on the PATH), then `engineuild_android.bat debug` (or `release`). Output `engine/godot/bin/android_debug.apk` (arm64, about 22 MB). First build about 15 minutes on 12 threads; use it as the template for `tools/make_test_apk.py`.
- Apply the patches in order (0001, 0002, ...); 0002 is written on top of 0001.
