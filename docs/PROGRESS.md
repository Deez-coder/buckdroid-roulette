# Progress

Running log of where the port stands. Newest status first; the dated log at the bottom keeps the history.
Every behaviour change to the game is also listed, with its reason, in [CHANGELOG.md](../CHANGELOG.md).

## Status (2026-11-23)

| Phase | State | Notes |
|---|---|---|
| 1. Audit | Done | Findings below. |
| 2. Desktop proof of concept | Done | Plays on stock Godot 4.1.1 with our autoloads; first round played by touch only. |
| 2b. Manual Android test build | Done | Runs on a Galaxy S24 Ultra (Snapdragon 8 Gen 3, Android 16) with ETC2 textures and Forward+. Look matches the PC, including the dealer's face. |
| 3. Platform stubbing | Started | Steam stub, local achievements, offline leaderboard and the multiplayer lock are in. Platform/Multiplayer interfaces and MULTIPLAYER_NOTES.md still to do. |
| 4. Input | Started | Touch adapter is in. Confirm-before-shoot, bigger hit areas, back button, glyphs and haptics still to do. |
| 5. Rendering and performance | In progress | Forward+ on Android; ETC2 transcoding (PC reference); shadow optimizer (mixed), blinker fix, 16-slot shadow atlas, engine shadow-update budget, 60 Hz display request, 60 fps cap; settings render_scale, shadow_softness, shadow_resolution, idle_fps (off by default). Still to do: presets with auto-detect, shader warm-up, low/mid-range devices, on-device transcoding. |
| 6. Launcher | Not started | Will use the user's launcher UI kit and touch-controls kit (both native Java, GPL-3.0). The Android engine build it needs now works. |
| 7. Verification | Not started | |

## Decisions

| Decision | Choice | Who | Why |
|---|---|---|---|
| Launcher architecture | Native Android launcher built with the user's UI kit; the game runs in a Godot activity in its own process | User | Gives the kit's exact look, the system file picker, D-pad focus and notch handling for free. |
| Decompiler on the phone (gdsdecomp) | Not included | Claude | The game's scripts are plain text in the PCK (Godot 4.1 has no bytecode), so no decompiling is needed; gdsdecomp releases probably no longer build against 4.1.1. GDRE Tools stays a PC-only analysis aid. |
| Android renderer | Forward+ (same as the PC) on capable phones | Claude, after the user's visual reports | Compatibility loses colour adjustments and glow. Mobile looked identical on the PC, but on the Adreno 750 it drops the shadows on the dealer's face. Forward+ on the phone matches the PC frame for frame. Mobile and Compatibility stay as candidates for weaker phones. |
| `using_steam` | Left on | Claude | Keeps the Steam edition's content (bathroom CRT leaderboard machine, achievements); the stub answers offline. Turning it off made the game call itself the itch.io edition. |
| User data folder | `BuckdroidRoulette` (custom user dir) | Claude | Test builds must never read or write the PC game's real saves. |
| Idle pacing default | Off (setting `idle_fps = 30` turns it on) | User | Only helps on still screens; real play rarely stays still. |
| Optional settings | 3D resolution (`render_scale`), idle pacing and similar trade-offs are user settings, not forced defaults | User | The user wants to choose look-vs-heat trade-offs themselves. |
| Own engine build for Android | Yes, Godot 4.1.1 + patches in `engine/patches/` | User | Needed for engine fixes (shadow budget, 60 Hz) and later for on-device texture conversion. |
| **License** | **Open — needs the user** | — | The UI kit is GPL-3.0-or-later. Either the user relicenses the kit (if they own all of it) and the project is MIT, or the project is GPL-3.0. |

## Key findings

- **Game:** Buckshot Roulette v2.2.0 hotfix 6 (Steam, Windows). Engine 4.1.1-stable with GodotSteam compiled in; embedded PCK format 2, not encrypted. Version identification data is in `patches/versions.json`.
- **Scripts** are plain-text `.gd` in the PCK, so on-device patching is a text edit.
- **Steam:** the game only prints the result of `steamInit` and has a `using_steam` flag, so there is no ownership check to get around. On our engine there is no built-in `Steam` object; an autoload named `Steam` takes its place and the game's scripts compile unchanged.
- **Touch:** the game picks what's under the pointer over two frames and only acts on a click if something was already under it. Godot's built-in touch-to-mouse emulation sends the move and the press together, so every tap on a 3D object missed. Fixed by `BuckdroidTouch`.
- **Coordinates:** events reach `_input` already in the game's 960×540 base space; `Input.parse_input_event` expects window pixels. Convert with the root window's final transform before re-sending.
- **Rendering on Android (Adreno 750, Mobile renderer):** animated `GeometryInstance3D.transparency` has no effect, so faded objects (the DEALER/YOU choice text, blood) stayed visible. Fixed by `BuckdroidTransparencyFallback`. Colour and brightness otherwise match the PC: the game area's 10th/50th/90th luminance percentiles are identical (0/47/120).
- **Phone-only quality cuts:** Godot 4.1 has `.mobile` overrides that apply automatically on phones: vertex shading, Lambert diffuse, hard shadows at half resolution, cheaper glow upscaling, reduced sky reflections. The user saw this as a flat dealer face, odd colours and weak shadows. The Mobile renderer on the PC doesn't use these overrides, which is why desktop comparisons looked fine. Android builds now set them to the PC values (list them with the test driver's `mobile_settings` step).
- **The dealer room** has about 18 shadow-casting omni lights, which matters for Phase 5 performance on weaker phones.
- **Textures:** 874 S3TC textures (416 MB). Phones don't report S3TC, so Godot finds no loadable variant and scene loading fails. Needs ETC2 transcoding (dev builds use a software-decode shortcut for now).
- **Screen:** without immersive mode, Android reserves the status bar and the game draws in a smaller, offset box. Godot 4.1's Android runner turns immersive mode on with the `--use_immersive` argument.

## Where we stopped (2026-11-23)

**State:** the phone (Galaxy S24 Ultra) runs the game on our own patched Godot 4.1.1 Android engine (patches 0001 diagnostic, 0002 shadow-update budget, 0003 60 Hz display request). The look matches the PC. Gameplay works start to finish (user playtests). Everything is committed (latest: see `git log`).

**Heat, real play (unplugged, ~15-20 min, temperature read right after):**

| Session | Build | Skin after | Throttling | Shadow draws / frame | GPU ms / frame (capped) |
|---|---|---|---|---|---|
| 1 (morning) | official engine, mixed + blinker + atlas fixes | 38.9 °C | status 1 | ~2,000 | 17.6 |
| 2 | + our engine with shadow budget | 39.4 °C | status 1 | ~1,420 | 16.2 |
| 3 | + 60 Hz display (was 120 Hz) | 38.1 °C (only 8.4 min, started at 35.8 °C) | status 1 | ~1,370 | 14.8 (avg 58.8 fps; under 55 fps 13% of the time, from 56% / 38%) |

The waste is removed; at 60 fps the GPU still needs ~16 of 16.7 ms in real play, so savings went into smoother frames (time under 55 fps 56% → 38%) rather than lower temperature. The 120 Hz panel (found via the user's refresh-rate overlay) is the remaining no-look-change saving; session 3 measures it. If still too warm, the trade-off options (user's choice): key lights' shadow budget, cheaper shadow method for the backroom light, `render_scale` below 1, a 45 fps cap.

**Done today:** in-game telemetry logger (`telemetry = on`, CSV in the app's telemetry folder; Android doesn't let the app read temperatures, so temperatures come from `adb` while plugged in); Android SDK/NDK/JDK 17 setup and engine build; shadow-update budget (−11 to −16% GPU on the phone); 60 Hz display request (renderFrameRate 120 → 60); flicker on fading objects fixed (transparency fallback only for the Mobile/Compatibility renderers; Forward+ fades correctly); settings `render_scale`, `transparency_fallback`; idle pacing off by default.

**How the phone sessions work:** the user plays unplugged and plugs back in right after; `.work/heatplay.sh` (background, read-only) logs live temperatures from `dumpsys thermalservice` ("Current temperatures from HAL" section) every 30 s; pull `/sdcard/Android/data/com.godot.game/files/telemetry/` afterwards. Always `adb -s R5CY54G6DWF`. "Stay awake" is on (the user enabled it). The user allows launching/stopping the test app via adb, never taps.

**Flicker investigation (2026-11-23 afternoon):** the user's screen recording (`.work/video/flicker.mp4`, found automatically by an A→B→A frame search) shows at 28.76 s the whole health display content (DEALER label, name, both shock icons) vanishing for exactly one frame at round start, while the divider lines stay. On the PC the game's scene state never hides those elements (test-driver `watch` step, frame by frame through the round start). On the phone, a frame burst (`burst` step) also showed them visible every frame in the scene state, but saving frames slowed the game to ~23 fps and no vanish was captured. All flickering objects are transparent (alpha pass); the hypothesis is that a frame occasionally reaches the screen before its transparent pass is finished (presentation/synchronisation on Adreno in our build). Next test candidates: vsync mode, `rendering/rendering_device/vsync/frame_queue_size`, swapchain image count; A/B builds checked by the user's eye or by screen recording. The 60 Hz hold fix (touch boost off + CHANGE_FRAME_RATE_ALWAYS) is built into the engine (VkSurfaceView) but not yet verified during play.

**Open bug: flicker on fading objects (user report, still present in session 3).** Objects that disappear or turn transparent flicker at random moments: the life/charge counter display, ejected shells landing on the table. It existed before today. It is NOT the transparency fallback: the fallback is off on Forward+ and the flicker remains. Candidates to test next: (a) the zero-energy shadow skip in `render_settings.gd`, which toggles `shadow_enabled` whenever a light's energy crosses zero (flickering lights near those objects); (b) the game's own fades rendering badly on Forward+/Adreno (transparent sorting or depth prepass); (c) the shadow-update budget (deferred shadows; but the bug predates it); (d) whether it also happens on the PC with the same build. Plan: ask the user for a short screen recording (they start it themselves) or make a test-driver script that watches the counter display; toggle (a)-(c) one at a time via settings.

**Open issue: the display goes back to 120 Hz during play (user report, session 3).** Patch 0003's 60 Hz request (`Surface.setFrameRate(60, COMPATIBILITY_DEFAULT)` in `VkSurfaceView.surfaceChanged`) holds at the menu (verified) but the panel switched to 120 Hz mid-game. Most likely cause: Android's touch boost (raises the refresh rate on every touch and overrides the app's vote on Samsung), possibly also overlays/system UI voting 120. Fix plan: in our engine's activity call `window.setFrameRateBoostOnTouchEnabled(false)` (API 35; the user's touch-controls kit does the same), use `setFrameRate(60, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, CHANGE_FRAME_RATE_ALWAYS)` (API 31), and re-apply on resume. Verify with the user playing while `dumpsys display` logs renderFrameRate every few seconds.

**Next steps:**
1. Keep the display at 60 Hz during play (touch boost, see above), and find and fix the flicker (see above). Then a full-length (15-20 min) heat session with 60 Hz from a cool start, and decide with the user about trade-offs.
2. Phase 4 controls: confirm-before-shoot, hit areas, back button, controller glyphs, haptics, and the on-screen controller from the user's touch-controls kit.
3. Phase 6 launcher with the user's UI kit (needs the license decision: MIT vs GPL-3.0).
4. On-device texture conversion (needs the etcpak compressor enabled in our engine build).
5. Presets with auto-detect for weaker phones; test on low/mid-range devices.

### Previous end-of-day notes (2026-11-22)

**Heat and performance, Galaxy S24 Ultra, 15 min idle at the table, no idle pacing (unattended runs, `.work/heatab*.sh`):**

| Run | Build | Skin max | Processor max | Throttling |
|---|---|---|---|---|
| A | Forward+, mixed shadows | 42.1 °C | 49.1 °C | status 2 after 13 min |
| B | A + idle pacing (best case, still screen) | 36.0 °C | 38.9 °C | none |
| C | A + blinker fix | 39.1 °C | 46.8 °C | none |
| D | C + 16-slot shadow atlas | 39.0 °C | 45.5 °C | none |

GPU per frame at the idle table, uncapped: original 26.2 ms → mixed 13.1 → blinker fix ~9.7 → atlas layout ~9.7 in a run where the default layout measured 11.6 (run-to-run spread is about 1-2 ms). Shadow draw calls per frame: 2,451 → 1,396 → 1,197 (0 on a still frame). The look matches the PC (frame-by-frame checks).

**Findings that matter for next time:**
- Godot 4.1 does cache positional shadows, but two things defeated it here: the 32 blinking table indicators (material swaps) and too few full-size shadow atlas slots. Both fixed in `src/render/render_settings.gd`.
- What still redraws: the fill lights that reach the dealer, because his animation really moves him (a second animation besides the head bob). Pausing the head bob alone changes nothing.
- At a 60 fps cap, extra GPU savings now show up only weakly in temperature: the rest is screen, CPU, and USB charging during tests. A real-play session (not idle) with all fixes hasn't been measured yet.
- The idle-pacing feature only helps on still screens; the user pointed out real play rarely stays still for 2 s. It stays on (free), but it isn't the heat fix.
- Measurement rules: compare GPU costs uncapped (`fpscap 0`); with the cap the phone lowers its GPU clock. Read live temperatures from "Current temperatures from HAL" in `dumpsys thermalservice`, not "Cached temperatures". Use `adb -s R5CY54G6DWF` (an emulator from another project is often attached). The user allowed launching/stopping the test app over adb; never send taps. "Stay awake" is on (the user turned it on).

**Engine:** Godot 4.1.1 source in `engine/godot/` (gitignored), Windows runtime builds with `engineuild_windows.bat` (about 11 min clean, 1 min incremental). Patches: `0001` diagnostic (`BUCKDROID_SHADOW_DEBUG=1`), `0002` shadow-update budget. **Android engine build works (2026-11-23):** JDK 17, SDK 33, Build-Tools 33.0.2, NDK r23c, CMake in `.cache/` (`enginendroid_sdk_setup.bat`; the user accepted the Android SDK License only — other license acceptances that sdkmanager added were removed), `engineuild_android.bat debug` produces `engine/godot/bin/android_debug.apk`. The test app on the phone now runs our engine (`custom_build`).

**Real-play session 2026-11-23 (official engine, before the budget):** unplugged, 21 min: 38.9 °C skin, throttling status 1, 50 fps average, 2,000-2,700 shadow draws per frame (moving items/hands/dealer), GPU about 18 ms per frame (capped, so clock-scaled). In-game telemetry logger (`telemetry = on`) works; Android doesn't let the app read temperatures (needs the launcher's Java code later). Budget measured on our engine: about 11-16% less GPU.

**Real-play session 2 (our engine + budget, unplugged, 15 min in the dealer room):** shadow draws per frame about 2,000 → 1,420 (−29%), GPU 17.6 → 16.2 ms (−8%), time under 55 fps 56% → 38%, average fps 50.2 → 51.8; temperature right after 39.4 °C skin, throttling status 1 (morning: 38.9 °C, status 1, 17 min). Conclusion: the waste is gone; at 60 fps the GPU still needs about 16 of 16.7 ms per frame in real play, so savings show up as smoother frames, not lower temperature. Then (same day): the panel was found running at 120 Hz while the game draws 60 fps; engine patch 0003 requests 60 Hz (confirmed renderFrameRate 60). The flicker on fading objects came from the transparency fallback, which is now off on Forward+. New settings: render_scale; idle pacing off by default (user decision). Real-play heat with the 60 Hz fix not measured yet. Remaining trade-offs if still needed: key lights' shadow budget, a cheaper shadow method for the large backroom light, a 3D render scale below 100%, or a lower frame rate in calm scenes.

**New from the user:** `touch-controls-kit.zip` (on-screen controller, GPL-3.0, gitignored) is to be used for an on-screen controller in the launcher phase, next to the launcher UI kit.

**Next steps (suggested order):**
1. A real-play heat session with all fixes (the user plays; temperatures recorded in the background).
2. If still too warm: measure CPU time per thread, try a lower screen-resolution scale option, and test without USB charging for a fair number.
3. Android engine build setup (SDK/NDK/JDK 17) — needed for the launcher and on-device texture conversion.
4. Phase 4 controls (confirm-before-shoot, hit areas, back button, controller glyphs, haptics) and the on-screen controller from the user's kit.
5. Phase 6 launcher with the user's UI kit; license decision (MIT vs GPL-3.0) is still open with the user.

### Earlier notes on the face investigation (first session)
What was known then:
- The colour problem is solved: it came from the dev-only S3TC software decoding. With ETC2 the frames' average colour matches the PC within about 1%.
- Shadows: a same-frame experiment on the phone showed the 16-bit positional shadow atlas loses most shadows on the Adreno 750, and 32-bit brings them back. Setting `positional_shadow/atlas_16_bits = false` as a project setting did **not** change the result (the table frame stayed at the 16-bit brightness). So a runtime override was added, `src/render/render_settings.gd` (autoload `BuckdroidRender`), which sets the root viewport to 32-bit on Android and logs `[buckdroid] shadow atlas ... 16-bit=...`. **It is built into the code but not yet tested on the phone.**
- Frame comparisons must use moments that always play the same way. Shell order is random, so "after the shot" differs between runs (one run's player shot themselves). Use the intro right after signing the waiver: `.work/td.txt` takes dealer shots 14–23 s after Enter. Capture the PC reference with the same script, using Forward+ without `--rendering-method`.

**Next steps for this issue:**
1. Rebuild the Android PCK (`--android --dev --etc2-dir .work/etc2`). Push it plus `.work/td.txt` as `tp.txt`, have the user open the app, then pull `shots/`. Check logcat for `16-bit=false`, and compare the `q2..q5` dealer frames with the PC run.
2. If the face still differs: try other shadow settings at runtime (soft shadow quality, shadow bias/normal bias on the dealer's lights, atlas quadrant subdivisions). Also check the per-object light limit of the Mobile renderer (8 omni lights per mesh; the dealer room has about 18 shadowed omnis). It looked identical on the desktop Mobile renderer, but driver-side culling may differ. Check fragment precision on Adreno too.
3. Last resort: compare against the Forward+ renderer on the phone (`rendering_method.mobile = forward_plus`) to see whether the Mobile renderer itself is the cause.

(Outcome: steps 1–2 confirmed the 32-bit atlas works but wasn't enough; step 3, Forward+, was the answer.)

**State of the phone:** the test app `com.godot.game` is installed with a 739 MB test PCK in its app storage (`/sdcard/Android/data/com.godot.game/files/`). The APK runs whatever script is in `tp.txt` when opened; it's currently empty, so the game plays normally. To remove everything: uninstall the app, which also deletes its files.

## Open items (next steps, in order)

1. Finish the dealer-face investigation (above).
2. On-device ETC2 transcoding (the PC reference `tools/transcode_etc2.gd` is done and converts all 874 textures in 49 s). Needs the etcpak compressor in our own engine build (the official export templates don't include it). Measure time and memory on low/mid phones.
3. Phase 3 interfaces: `Platform` and `Multiplayer` autoload contracts; write `docs/MULTIPLAYER_NOTES.md`.
4. Phase 4: confirm-before-shoot on touch, bigger hit areas (waiver keypad), Android back button, controller glyphs, haptics.
5. Phase 5: Low/Medium/High presets (Compatibility as Low), render scale, FPS cap, shader warm-up, profiling on low/mid devices.
6. Phase 6: launcher with the UI kit (after the license decision).
7. Test devices: low-end and mid-range phones are still needed for the performance targets.

## How to test (developer machine only)

```text
python tools/build_patched_pck.py "<Steam folder>/Buckshot Roulette.exe" .work/patched.pck --dev
Godot_v4.1.1-stable_win64_console.exe --main-pack .work/patched.pck -- --bd-script=<script> --bd-out=<folder>
```
Android test build: `--android --dev --dev-s3tc-fallback`, then `tools/make_test_apk.py` on the official 4.1.1 template, sign with a local debug key, and push the PCK to `/sdcard/Android/data/com.godot.game/files/game.pck`. Test-script steps are documented at the top of `src_dev/test_driver.gd`.

Rules learned the hard way:
- Don't drive a real phone with blind `adb input tap`. Taps go to whatever app is in front; one hit the game's Discord button. Use the in-game test driver, and check the focused app before any screenshot.
- In Git Bash, set `MSYS_NO_PATHCONV=1` for adb and phone paths, but give Python Windows-style paths.

## Log

- **2026-11-23** Real-play sessions with the in-game telemetry logger. Android SDK/NDK/JDK setup (only the Android SDK License accepted) and our own Android engine build. Engine patches 0002 (shadow-update budget) and 0003 (60 Hz display request). Fixed the fade flicker (fallback off on Forward+). New settings render_scale, transparency_fallback; idle pacing off by default (user). Noted the user's touch-controls kit for the launcher phase.

- **2026-11-22 (second session)** Deterministic frame comparison showed the 32-bit atlas works but the dealer's face still lacked shadows on the Mobile renderer; Forward+ on the phone matches the PC, so Android switched to Forward+. Profiled on the phone: shadows were the whole cost (37 fps → 120 fps without them). Built the shadow optimizer (skip unlit lights, paraboloid fill lights): 60–71 fps with the face intact. 60 fps cap.
- **2026-11-22 (later)** Phone visuals: found Godot's phone-only quality cuts (vertex shading etc.) and set them to the PC values. Found that the S3TC software decoding washed out colours, and wrote the ETC2 transcoder; colours now match. Found the 16-bit shadow atlas losing shadows on Adreno, and added a runtime 32-bit override (untested). Test driver gained `inspect`, `lights`, `mobile_settings`, `texinfo`, `setall`, `vp`. Rule: compare only deterministic frames.
- **2026-11-22** Phase 1 audit. Repo set up with a strict `.gitignore`. PC tools (`gdpck.py`, `ecfg.py`, `build_patched_pck.py`). Steam stub, platform, boot (multiplayer lock), touch adapter, dev test driver. Desktop: full intro, waiver and first round by touch; controller menu navigation works. Android: official 4.1.1 template plus `_cl_` main-pack test APK; runs on S24 Ultra; switched to Mobile renderer; transparency fallback; immersive mode.
