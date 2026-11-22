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
| `0001-debug-shadow-dirty-log.patch` | Development diagnostic: with the `BUCKDROID_SHADOW_DEBUG` environment variable set, logs which instances force positional light shadows to be redrawn. | Dev builds only |

## Build

- Windows test runtime: `engine\build_windows.bat` (Visual Studio C++ tools, SCons). Output in `engine/godot/bin/`.
- Android templates: to be added (Android SDK/NDK r23c, JDK 17).
