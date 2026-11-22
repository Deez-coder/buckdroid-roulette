# Changelog

Every change Buckdroid Roulette makes to how the game behaves, and why it exists. The game's own scripts are not
edited unless an entry says so; changes are made from our own code (autoloads), project-setting overrides applied
by the installer, and resource conversions. Gameplay logic (rounds, items, damage, dealer AI, RNG) is never changed.

Format: each entry says **what**, **where** (our file or setting), and **why**.

## Unreleased

### Game script patches
- None. All changes so far are made from our own code and settings.

### Project setting overrides (`patches/versions.json`)
- **Our autoloads load first**: `BuckdroidPlatform`, `Steam`, `BuckdroidBoot`, `BuckdroidTouch`, `BuckdroidTransparencyFallback`, inserted before the game's own autoloads. *Why:* the game's Steam autoload needs a `Steam` object to exist when it starts.
- `application/config/use_custom_user_dir = true`, `custom_user_dir_name = "BuckdroidRoulette"`. *Why:* keeps the port's saves apart from the PC game's.
- `application/boot_splash/minimum_display_time = 0`. *Why:* the 3-second splash wait shows only a black screen (the splash image is turned off).
- `input_devices/pointing/emulate_mouse_from_touch = false`. *Why:* replaced by `BuckdroidTouch` (see below).
- Android only: `rendering/renderer/rendering_method(.mobile) = "mobile"`. *Why:* the PC game uses Forward+; on phones Mobile matches it most closely (Compatibility loses colour adjustments and glow).
- Android only: all of Godot's phone-only quality cuts are set back to the PC values: `force_vertex_shading.mobile = false`, `force_lambert_over_burley.mobile = false`, positional and directional shadow size 4096 with soft filter quality 2, glow upscale mode 1, sky reflections (texture arrays, 32 GGX samples, 256 reflection size). *Why:* Godot 4.1 applies these automatically on phones; vertex shading in particular made the dealer's face look flat and changed colours, and shadows became hard-edged and lower resolution. Performance cost to be measured in Phase 5, where they become part of the Low/Medium/High presets.
- Android only: `rendering/lights_and_shadows/positional_shadow/atlas_16_bits = false`. *Why:* on the tested Adreno 750, 16-bit shadow storage lost most of the shadows from the game's lights. A same-frame experiment on the phone showed 32-bit storage brings them back, matching the PC.
- Android only: `rendering/textures/vram_compression/import_etc2_astc = true`, `display/window/handheld/orientation = 4` (sensor landscape), `debug/file_logging/enable_file_logging = true`.

### Platform (`src/platform/`)
- **Steam stub** (`steam_stub.gd`, autoload `Steam`): an offline replacement for the GodotSteam functions, signals and constants the game uses. Never logged on, no lobbies or networking. *Why:* Steam does not exist on Android; the game has no ownership check, so nothing is bypassed.
- **Local achievements** (`platform.gd`): achievements the game unlocks are stored in `user://buckdroid/achievements.cfg`. *Why:* replaces Steam achievements.
- **Offline leaderboard** (`steam_stub.gd` + `platform.gd`): the Double-or-Nothing board shows this device's best score only, stored in `user://buckdroid/scores.cfg`. *Why:* the online board needs Steam; the game's board screen works unchanged.

### Multiplayer (`src/core/boot.gd`)
- The main menu's **Multiplayer** button is greyed out, cannot be pressed or focused, and shows "COMING SOON". *Why:* the game's multiplayer is built on Steam lobbies; a local multiplayer backend is planned for later.

### Input (`src/input/touch_adapter.gd`)
- **Touch adapter**: a touch moves the pointer, then presses 3 frames (about 50 ms) later; the release always follows its press. Positions are converted from game space back to window pixels before re-sending. *Why:* the game only acts on a click when something was already under the pointer, so with Godot's emulation every tap on a 3D object missed.

### Rendering (`src/render/transparency_fallback.gd`)
- **Transparency fallback** (Android only): objects whose `transparency` is animated are hidden while fully transparent and shown again when the animation brings them back. *Why:* on the Mobile renderer on Android (tested on Adreno 750) animated transparency has no effect, so the DEALER/YOU choice text and blood stayed on screen. *Side effect:* those fades are instant instead of gradual.

- **Runtime shadow atlas override** (`src/render/render_settings.gd`, autoload `BuckdroidRender`, Android only): sets the root viewport's positional shadow atlas to 32-bit after startup. *Why:* the project setting above didn't take effect on the phone, and changing the viewport at runtime did. *Status:* not yet confirmed on the phone.

### Resources
- **Textures converted to ETC2** (`tools/transcode_etc2.gd`, PC reference for the installer step): every desktop S3TC/BPTC/RGTC texture (874, 416 MB) is decoded and re-encoded as ETC2 with mipmaps. Normal maps use Godot's ETC2 normal layout. On Android the ETC2 data is written in place of the S3TC file, so references by file name keep working, and each `.import` remap gets a `path.etc2` entry. *Why:* phones can't use S3TC; software decoding of S3TC on the phone also produced washed-out, flat colours. With ETC2 the phone's frames match the PC's average colour within about 1%. PC conversion time: 49 s.
- Dev builds only, now superseded by ETC2 (`--dev-s3tc-fallback`): texture `.import` remaps get a `path.etc2` entry pointing at the existing S3TC data, which Godot decodes in software. *Why:* lets the game load on phones before transcoding exists. Will be replaced by real ETC2 transcoding, and is never used for users.

### Test build (`tools/make_test_apk.py`)
- Adds `--use_immersive` to the start arguments. *Why:* hides the status and navigation bars so the game uses the full screen height.
