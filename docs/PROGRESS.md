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

**State:** the phone (Galaxy S24 Ultra) runs the game on our own patched Godot 4.1.1 Android engine (patches 0001 diagnostic, 0002 shadow-update budget, 0003/0004 60 Hz display, 0005 flicker fix). The look matches the PC. Gameplay works start to finish (user playtests). Everything is committed (latest: see `git log`).

**Heat, real play (unplugged, ~15-20 min, temperature read right after):**

| Session | Build | Skin after | Throttling | Shadow draws / frame | GPU ms / frame (capped) |
|---|---|---|---|---|---|
| 1 (morning) | official engine, mixed + blinker + atlas fixes | 38.9 °C | status 1 | ~2,000 | 17.6 |
| 2 | + our engine with shadow budget | 39.4 °C | status 1 | ~1,420 | 16.2 |
| 3 | + 60 Hz display (was 120 Hz) | 38.1 °C (only 8.4 min, started at 35.8 °C) | status 1 | ~1,370 | 14.8 (avg 58.8 fps; under 55 fps 13% of the time, from 56% / 38%) |

The waste is removed; at 60 fps the GPU still needs ~16 of 16.7 ms in real play, so savings went into smoother frames (time under 55 fps 56% → 38%) rather than lower temperature. The 120 Hz panel (found via the user's refresh-rate overlay) is the remaining no-look-change saving; session 3 measures it. If still too warm, the trade-off options (user's choice): key lights' shadow budget, cheaper shadow method for the backroom light, `render_scale` below 1, a 45 fps cap.

**Done today:** in-game telemetry logger (`telemetry = on`, CSV in the app's telemetry folder; Android doesn't let the app read temperatures, so temperatures come from `adb` while plugged in); Android SDK/NDK/JDK 17 setup and engine build; shadow-update budget (−11 to −16% GPU on the phone); 60 Hz display request (renderFrameRate 120 → 60); flicker on fading objects fixed (transparency fallback only for the Mobile/Compatibility renderers; Forward+ fades correctly); settings `render_scale`, `transparency_fallback`; idle pacing off by default.

**How the phone sessions work:** the user plays unplugged and plugs back in right after; `.work/heatplay.sh` (background, read-only) logs live temperatures from `dumpsys thermalservice` ("Current temperatures from HAL" section) every 30 s; pull `/sdcard/Android/data/com.godot.game/files/telemetry/` afterwards. Always `adb -s R5CY54G6DWF`. "Stay awake" is on (the user enabled it). The user allows launching/stopping the test app via adb, never taps.

**Flicker on fading objects: FIXED (engine patch 0005, 2026-11-23 evening).** Symptom: every transparent object (health display symbols and DEALER/name labels, ejected shells, saw-cut barrel tip, fading items) vanished for single frames, most visibly while the shell tray turns at round start. Findings: the game never hides them (test-driver `watchall`); the renderer's object/draw counts and the transparent list are identical on vanish frames, nothing is skipped (`watchrender`, temporary engine log), and unshaded copies still vanish, so it was the GPU reading wrong data for the whole transparent pass. Repro without the user: test-driver step `flipdemo 20` (camera on the health display, tray turned 20 times) plus `adb screenrecord`, counted frame by frame (`.work/flipcap.sh`): 4-28 vanishes per run. Trigger: frames mixing cube-shadow and paraboloid-shadow redraws (all-cube or all-paraboloid: 0; shadow budget interval 1: 0), which the budget makes frequent but also happens on its own in play. Cause: Godot 4.1 Forward+ reuses scene-data uniform buffer slot 0 for the shadow passes, the opaque pass and the transparent pass (rewritten between opaque and transparent) within one frame. Fix: the transparent pass uses slot 1 and shadow passes slots 2+. After: 0 vanishes in 3 runs (60 tray turns each), image identical. A render-pass dependency fix was tried first and did not help. Note: `.work/apk_ours.sh` now verifies that the signed APK really carries the new engine (a silent signing failure once left the old APK installed).

**Next steps:**
1. Heat: done for now (session 5: steady 60 fps, no throttling, GPU 12.9 ms). Optional further no-look savings: the six small LS lights (up to ~15% of the remaining load), the table light. If more is needed later, test the game on a newer Godot (user decision: shadows first, then newer engine). Heat-adaptive render scale (ADPF thermal headroom) remains an idea.
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


**Heat session 4 (2026-11-23 evening, flicker fix + 60 Hz, unplugged 17 min from 33.6 °C):** skin 39.4 °C, AP 42.5 °C, throttling status 1; fps 56.1 avg (58.3 → 53.8 as the phone heated), GPU 16.3 ms of 16.7, under 55 fps 38%, ~1,360 shadow draws/frame. Same as sessions 1-3: the GPU is maxed at 60 fps.

**GPU cost breakdown at the table (dealer idle, 2026-11-23):** at a locked 60 fps the GPU clock drops when work drops, so GPU ms reads flat; measure GPU clock x busy instead (`.work/gpusample.sh`, read-only sysfs `kgsl-3d0/devfreq/cur_freq` and `gpu_busy_percentage`, windows marked by `log win_start/win_end` in `.work/tcost.txt`). Load (MHz x busy): base ~535 (661 MHz, 81%); all shadows off 278 (-48%, 366 MHz); render scale 0.75 457 (-14%); 0.85 483 (-10%); hard shadows (soft quality 0) 476 (-11%); 2D screen overlays off ~-1%; glow is off in this scene. Power rises faster than clock (voltage), so shadows are roughly half or more of GPU power. vsync off does not unlock the frame rate on this phone. New test-driver steps: `vsync`, `nodeprocess`.

**Per-light shadow cost (GPU load, each light's shadow off alone):** backroom main (cube, range 44.6) -20%; tabletop interior (cube) -4%; each of the six small LS lights (paraboloid) 0-4%; door3 and the two lights without shadows ~0. Fix: patch 0006 cube-light budget, interval 3 on Android (-13% at the table). Next: real-play heat session 5 with patch 0006; if not enough, test the game on a newer Godot (user decision: shadows first, then newer engine).

**Heat session 5 (2026-11-23 evening, + patch 0006 big-light shadow refresh every 3rd frame, unplugged ~17 min from 32.8 °C):** skin 38.9 °C, AP 44.1 °C, **throttling status 0** (session 4: 39.4 °C, status 1). fps 60.0 avg, steady to the end (thirds 60.2 / 60.2 / 59.5; session 4: 58.2 / 56.6 / 53.3); time under 55 fps 1% (39%); GPU 12.9 ms per frame (16.5), flat across the session (session 4 rose 14.8 → 18.3 as the phone throttled); shadow draws/frame 772 (1,393). The user: "feels much better", look unchanged. Skin temperature is about the same because the phone now holds full speed instead of throttling.

**More cooling tests (2026-11-23 night, with patch 0006):** the game renders its 3D at only 960x540 (stretch mode viewport), so the cost is not pixels: the shadow passes draw ~860k triangles per frame versus ~72k visible. Measured (GPU load, clock x busy): shadow atlas 2048 -4%; mesh LOD threshold 4 -4% (visibly changes thin cables); atlas 2048 + LOD 2 together about -3%. Frozen-scene screenshots show no visible change for atlas 2048 / LOD 2, but the gain is too small for a default change: both stay user options (graphics.ini `shadow_resolution`, new `mesh_detail`; `shadow_softness` now documented in the file). Defaults stay original.

**Newer engine test (Godot 4.6.3, started 2026-11-23 night, user decision):** official 4.6.3 (checksum-verified, in `.cache/godot-4.6.3`). Two data adaptations make the game load (`build_patched_pck.py --dev-newer-engine`): the global class list needs `is_abstract`/`is_tool` per entry (else every class_name type is unknown and the menu is black), and the multiplayer-only `MP_ItemResource_User.gd` has four Node-typed `@export`s in a Resource script, which 4.2+ rejects (the `@export` is dropped). Old mesh surfaces are upgraded at every load (warning only). PC intro run vs 4.1.1, differences: the dealer's head sits lower; a dark box over the player's half of the table; the smoking man in the corridor is invisible (user report; cigarette visible). Likely skeleton/skinning and a material/lighting change. Next: measure GPU load on the phone with the official 4.6.3 Android template before fixing anything.

**Newer engine result (2026-11-23 night):** official 4.6 Android templates are built with `disable_path_overrides` and refuse `--main-pack` from the app folder ("Unable to setup the Godot engine"), so we build our own (`engine/build_android46.bat`, source in `engine/godot46`, needs NDK 29.0.14206865, platforms;android-36, build-tools;36.1.0). The 4.6 launcher activity is `GodotAppLauncher` (test scripts now resolve it). Same table scene, same content, no shadow budgets on either: **4.1.1 load ~580 (713-741 MHz), 4.6.3 load ~490 (629-635 MHz): -16% GPU**; CPU main loop 17 ms → 14 ms; worst frame 19 → 17 ms. Our 4.1 with patches 0002+0006 is ~465. Estimated 4.6 + ported budgets: ~390 (-15% vs today). Costs: the three visual differences (dealer head lower, dark box on the player's half, invisible smoker), repeated "BUG, indexing did not unpair geometries from light" errors, porting patches 0002/0003/0004/0006 (0005 may be obsolete; must re-check the flicker). The phone is back on the current 4.1 build.

**Where we stopped (2026-11-23, late night): moving to Godot 4.6.3 (user decision), visual fixes in progress (PC only).** Causes found for the three 4.6 differences:
1. *Smoker invisible / dealer head lower:* `MeshInstance3D.skeleton` defaulted to `".."` in 4.1, so the game's scenes don't store it; 4.6 defaults to empty, so skinned meshes under their Skeleton3D lose their skeleton and draw unanimated in bind pose (test-driver `skintest` showed `skeleton=` empty on 4.6). Node transforms and skeleton poses are identical on both engines (`geodump` diff), mesh arrays and skins too.
2. *Dark box over the player's briefcase hatch:* fixed by rebuilding the hatch's mesh from its arrays (`remesh`); the rebuild drops the separate shadow mesh, so the suspect is 4.6's on-load upgrade of the 4.1 shadow mesh (self-shadowing). Not proven yet which part.
New autoload `src/compat/newer_engine.gd` (BuckdroidCompat, inactive on 4.1): sets empty skeleton paths under a Skeleton3D back to "..", rebuilds shadow meshes from their arrays. First test run of it was in progress at the stop; check `.work/cf46_cmp.png` (4.1 vs 4.6+compat at corridor/table/dealer). Remaining plan: confirm fixes (else rebuild whole meshes, measured 369 ms for 582 meshes on PC), port engine patches 0002/0006 (shadow budgets), 0003/0004 (60 Hz, Java side changed in 4.6), re-test the flicker (0005), switch versions/build tools to the 4.6 target, phone GPU measurement and a full user playthrough. 4.6 build: `engine/build_android46.bat` (source `engine/godot46`, NDK 29); 4.6 launcher activity is GodotAppLauncher. The phone still runs the working 4.1 build.

Note: the first BuckdroidCompat test run stopped after the menu screenshot (no script errors logged, only q0_menu.png). Next session: check whether the compat autoload stalls the intro on 4.6 (log in .work/cf46.log), then fix and rerun.

## Moved to Godot 4.6.3 (2026-11-24, user decision; Claude's choices while the user was away are marked *choice*)

**State:** the phone runs our own Godot 4.6.3 build (`engine/godot46`, `engine/build_android46.bat`, patches in `engine/patches46/`) with 4.6-target data (`build_patched_pck.py` now defaults to `--target-engine 4.6`; `--target-engine 4.1` keeps the old path with `engine/godot` and `engine/patches/`). Scripted check on the phone: intro, bathroom, waiver, first round (grab gun, DEALER/YOU choice, shot, shell ejects, dealer's turn) all work; no script errors.

**4.6 compatibility (`src/compat/newer_engine.gd`, autoload BuckdroidCompat, does nothing on 4.1):**
1. Skeleton path default: 4.1 defaulted `MeshInstance3D.skeleton` to "..", 4.6 to empty; skinned meshes under a Skeleton3D get ".." back. Fixes the invisible corridor smoker and the dealer's head pose (verified against 4.1 screenshots).
2. Broken shadow meshes from 4.6's on-load upgrade of 4.1 mesh data (dark box over the player's briefcase hatch): each mesh with a shadow mesh is replaced by a fresh copy built from its own arrays (*choice*: at runtime, ~218 ms for 535 meshes on the PC, once per scene; could move into the conversion step later). Changing `shadow_mesh` in place crashes 4.6 (segfault), so the whole mesh is replaced.
3. Data adaptations in the PCK builder: global class list fields (`is_abstract`, `is_tool`), four Node-typed `@export`s in the multiplayer-only `MP_ItemResource_User.gd` relaxed.

**Engine patches on 4.6:** 46-0001 shadow-update budget (paraboloid + cube intervals, same settings as before); 46-0002 60 Hz request (VkSurfaceView); 46-0003 touch-boost opt-out moved into GodotActivity (the 4.6 view only has the application context). *choice*: the flicker fix (4.1 patch 0005) is NOT ported: 4.6 showed 0 vanishes in 2 scripted 20-flip runs (4.1 had 4-28 per run). Patch 0001 (diagnostic) not ported.

**Measured on the phone, same session (GPU load = clock x busy at the table):** 4.1 + budgets 480; 4.6 without budgets 495; **4.6 + budgets 458 (-5% GPU vs 4.1)**; CPU main loop ~18 → ~15 ms (-18%); worst frame 19-20 → 17 ms. The budgets and 4.6's own light culling overlap, so the GPU gain is smaller than the first estimate (-15%). Real-play heat on 4.6 not measured yet (needs the user).

**Known:** repeated engine errors "BUG, indexing did not unpair geometries from light" and "geom->softshadow_count==0 - BUG!" (also on the unmodified official 4.6 build; no visible effect yet). Old mesh surfaces are upgraded at every load (warning spam; load time). 4.6 launcher activity is GodotAppLauncher.

**Next:** real-play heat session on 4.6 with the user, user playthrough check (menus, all items, endings, endless mode), then Phase 4 controls.

**Heat session 6 (2026-11-24, Godot 4.6.3, short: 6 min of play from 34.2 °C):** skin 36.5 °C, AP 39.0, status 0. fps 60.2, under 55 fps 1%, GPU 12.7 ms (session 5 on 4.1: 12.9), shadow draws/frame 423 (772), median worst frame 20.4 ms (22.1), logger cpu_ms 18.4 (28.4; includes waiting, indicative only). Too short for a temperature comparison; a full 15-20 min session from ~33 °C is still needed.

## Optimization round on 4.6 (2026-11-24, user away; *choice* = decided by Claude)

Research (Godot docs, Android ADPF guide, Arm/Qualcomm notes, earlier Arm Godot posts): on phones the Mobile renderer is the efficient path (no clustered lighting, subpasses, FP16 since 4.5); frame pacing via Swappy is strongly recommended by Godot's own build ("without Swappy ... there will be stutter"); thermal headroom (ADPF) should drive gentle quality steps before throttling; resolution is the main heat lever, then shadows.

Done:
- *choice* **Swappy frame pacing compiled in** (`swappy=yes`, Godot's `misc/scripts/install_swappy_android.py`, official godot-swappy release). Our earlier 4.6 builds had none. Default mode `display/window/frame_pacing/android/swappy_mode` = 2 (auto).
- *choice* **Heat guard** `src/render/thermal_guard.gd` (autoload BuckdroidThermal, graphics.ini `thermal_guard`, default on): reads `PowerManager.getThermalHeadroom(10)` and `getCurrentThermalStatus()` every 10 s through Godot's built-in AndroidRuntime plugin (no engine change); at headroom >= 0.95 lowers the 3D scale by 0.1 (min 0.7), restores after 60 s below 0.80. Headroom/status/3D scale now in telemetry (`thermal_headroom,thermal_status,scale_3d`) and in the fps overlay ("heat 0.62"). First reliable heat signal from inside the app. Untested on the phone yet.
- CPU profiling on the PC (test-driver `perfmon`, `procscan`, `animscan`, `treescan`): per-frame process time ~5 ms on the desktop CPU, but no script or scene part stands out (all < 0.1-0.5 ms, noise ±0.3 ms); our autoloads are negligible; animations ~0.4 ms. *choice*: not chasing it further.
- Mobile renderer on 4.6 (PC): with `transparency_fallback` on (auto does this for non-Forward+ renderers) the in-game image matches Forward+ (mean difference ~1 level); fades pop instead of fading. The 4.1-era Adreno face-shadow loss must be re-checked on the phone. *choice*: candidate for an optional "cool" renderer setting, not the default.
- `.work/abtest.sh` (needs the phone): installs the Swappy build, then base / Mobile renderer / separate render thread (`rendering/driver/threads/thread_model=2`) / both / base again, each with a frozen dealer close-up (face-shadow check) and GPU clock x busy plus the game's CPU time (now sampled from /proc/<pid>/stat by `.work/gpusample.sh`).

Next when the phone is back: run `bash .work/abtest.sh` (~25 min, unattended), check thermal guard log lines and telemetry columns, then a full heat session.

**A/B on the phone (2026-11-24, Godot 4.6.3 + Swappy, GPU load = clock x busy at the table, CPU = % of one core):**

| Variant | GPU clock | GPU load | CPU | fps / worst frame |
|---|---|---|---|---|
| Forward+ (base) | 578-590 MHz | 454-462 | 67-69% | 60 / 23-33 ms |
| **Mobile renderer** | **366 MHz** | **273-278 (-40%)** | 68% | 60 / 29-34 ms |
| Forward+ + separate render thread | 590-602 MHz | 449-461 | 79% | 58-59 / 34-35 ms |
| Mobile + separate render thread | 366 MHz | 266 | 79-82% | 58-59 / 33-35 ms |

Frozen dealer close-ups: Mobile matches Forward+ (mean difference 1.2; face shadows intact, so the 4.1-era Adreno shadow loss is gone in 4.6). The heat guard reads the headroom (overlay showed "heat 0.7x, status 0"). *choice*: separate render thread rejected (more CPU, fps dips).

**Mobile renderer is now the Android default** (*choice*; `patches/versions.json` rendering_method(.mobile) = mobile; `--dev-renderer forward_plus` builds the old path). Engine patch **46-0004** ports the per-instance fade (GeometryInstance3D.transparency, distance fade) from Forward+ to Mobile (fade value in instance flag bits 24-31, faded instances in the transparent pass, shader alpha starts at the fade). Verified on the phone with the script fallback OFF: DEALER/YOU labels appear only on grabbing the gun, no stray blood/labels; flicker repro 0 vanishes. `transparency_fallback = auto` now only applies to the Compatibility renderer.

**Higher frame rates:** fps_cap 90/120 (with a 90/120 Hz display request) still ran at exactly 60: Godot sets Swappy's swap interval to max(display refresh period at swapchain creation, 1/max_fps), so a cap can only lower the rate. Needs an engine change (swap interval from the requested refresh rate) plus switching the panel rate from settings. At 60 fps on Mobile the GPU sits at its lowest clock (366 MHz, ~75% busy), so 90-120 fps is possible but costs heat.

**Heat session 7 (2026-11-24, Godot 4.6.3 + Mobile renderer + Swappy, unplugged 20 min, system display setting now adaptive 120 Hz; the game requests 60 Hz and the panel went 120 → 60 when the game started):** skin **35.1 °C**, AP **36.8 °C**, battery 34.5 °C, throttling status 0. Android thermal headroom (logged every 5 s): start 0.61, quarters 0.66 / 0.70 / 0.71 / 0.71, max 0.73 (1.0 = throttling); the heat guard never had to act (3D scale stayed 1.00). fps 60.4 avg, 0% under 55, GPU 11.5 ms. Median worst frame per 5 s window 25.6 ms (Forward+ sessions: 20-22 ms) - worth a look. Comparison: session 5 (4.1 Forward+, display forced to 60 Hz, 17 min) ended at skin 38.9 °C / AP 44.1 °C. User: "temps seem MUCH better". The user thinks the 120 Hz hold did not work during play (not verified; adb cannot log while unplugged).

**Shadow lag and black flash on hovered items (user report, 2026-11-24):** caused by our shadow-update budget (redraw every 3rd frame) on 4.6: moving shadows lagged visibly and lifted items shadowed themselves for a moment when dropping back. *choice*: default back to every frame (`buckdroid_*_update_interval` = 1 in versions.json); `shadow_refresh` (graphics.ini) now sets both intervals for users who want it cooler. Cost on Mobile: GPU load 276 → 315 (+14%), still ~30% below Forward+. User confirmed both issues gone.

**Display stays at 120 Hz during play (user's overlay app; confirmed by a 3-min adb log: 75/75 samples at 120 Hz with the game in front)** although our VkSurfaceView requests 60 Hz. Suspect: Swappy votes the frame rate from the refresh period it read at swapchain creation (120 Hz) and overrides our request.
