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
| `0002-shadow-update-budget.patch` | Shadow-update budget: omni lights with dual-paraboloid shadows (the port's weaker fill lights) redraw a changed shadow at most once every N frames (`rendering/lights_and_shadows/positional_shadow/buckdroid_paraboloid_update_interval`, default 1 = Godot's behaviour; the Android overrides set 3). Pending changes are kept and drawn later; cube-shadow (key) lights are never delayed. PC measurement while moving the shotgun: shadow draws 2,284 → about 1,550 per frame. | Yes |
| `0001-debug-shadow-dirty-log.patch` | Development diagnostic: with the `BUCKDROID_SHADOW_DEBUG` environment variable set, logs which instances mark positional light shadows dirty and which lights actually redraw their shadow. | Dev builds only |

## Build

- Windows test runtime: `engine\build_windows.bat` (Visual Studio C++ tools, SCons). Output in `engine/godot/bin/`.
- Android SDK: `enginendroid_sdk_setup.bat licenses` then `... install` (JDK 17 and the command-line tools in `.cache/`; accepting means agreeing to Google's Android SDK License).
- Android templates: to be added.
- Apply the patches in order (0001, 0002, ...); 0002 is written on top of 0001.
