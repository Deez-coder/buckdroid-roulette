# Progress

Running log of where the port stands. Newest status first; the dated log at the bottom keeps the history.
Every behaviour change to the game is also listed, with its reason, in [CHANGELOG.md](../CHANGELOG.md).

## Status (2026-11-22)

| Phase | State | Notes |
|---|---|---|
| 1. Audit | Done | Findings below. |
| 2. Desktop proof of concept | Done | Plays on stock Godot 4.1.1 with our autoloads; first round played by touch only. |
| 2b. Manual Android test build | Done | Runs on a Galaxy S24 Ultra (Snapdragon 8 Gen 3, Android 16) with ETC2 textures and Forward+. Look matches the PC, including the dealer's face. |
| 3. Platform stubbing | Started | Steam stub, local achievements, offline leaderboard and the multiplayer lock are in. Platform/Multiplayer interfaces and MULTIPLAYER_NOTES.md still to do. |
| 4. Input | Started | Touch adapter is in. Confirm-before-shoot, bigger hit areas, back button, glyphs and haptics still to do. |
| 5. Rendering and performance | In progress | Forward+ on capable phones; ETC2 transcoding (PC reference); shadow optimizer: 60–71 fps on the S24 Ultra; 60 fps cap. Still to do: presets, auto-detect, shader warm-up, low/mid-range devices, on-device transcoding. |
| 6. Launcher | Not started | Will use the user's launcher UI kit (native Java views). |
| 7. Verification | Not started | |

## Decisions

| Decision | Choice | Who | Why |
|---|---|---|---|
| Launcher architecture | Native Android launcher built with the user's UI kit; the game runs in a Godot activity in its own process | User | Gives the kit's exact look, the system file picker, D-pad focus and notch handling for free. |
| Decompiler on the phone (gdsdecomp) | Not included | Claude | The game's scripts are plain text in the PCK (Godot 4.1 has no bytecode), so no decompiling is needed; gdsdecomp releases probably no longer build against 4.1.1. GDRE Tools stays a PC-only analysis aid. |
| Android renderer | Forward+ (same as the PC) on capable phones | Claude, after the user's visual reports | Compatibility loses colour adjustments and glow. Mobile looked identical on the PC, but on the Adreno 750 it drops the shadows on the dealer's face. Forward+ on the phone matches the PC frame for frame. Mobile and Compatibility stay as candidates for weaker phones. |
| `using_steam` | Left on | Claude | Keeps the Steam edition's content (bathroom CRT leaderboard machine, achievements); the stub answers offline. Turning it off made the game call itself the itch.io edition. |
| User data folder | `BuckdroidRoulette` (custom user dir) | Claude | Test builds must never read or write the PC game's real saves. |
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

## Where we stopped (2026-11-22, second session)

**Solved: the dealer's face.** Godot 4.1's Mobile renderer drops the shadows on the dealer on the Adreno 750; Forward+ on the phone matches the PC (dealer-area brightness 19.5 vs 19.0, deterministic intro frames). Android now uses Forward+.

**Optimized: speed.** With Forward+, shadows were the whole cost (26 of 33 ms GPU at the idle table). The shadow optimizer in `src/render/render_settings.gd` ("mixed" mode plus skipping shadows for unlit lights) gives 60 fps at the dealer intro and 71 fps at the idle table on the S24 Ultra, with the face still very close to the PC. The cap is 60 fps. Measured per mode: cube 39/43, mixed 60/71, paraboloid –/96 fps (paraboloid visibly changes the face).

**Playtest (user, full match won):** gameplay works start to finish. Reported: (1) noticeable warmth (phone skin about 38 °C afterwards, no throttling); (2) the end-of-run stats screen ignored taps ("press any button"); (3) requests for a relative cursor mode with size and speed options, and an fps/RAM overlay. Done in response: any-button fix, relative cursor mode, settings files (`config/*.ini`, UI-kit format), performance overlay, `fps_cap = 30` option. **Not yet confirmed on the phone.** The phone currently has `fps_counter = on`, `touch_mode = relative`, `cursor_size = 1.5`, `fps_cap = 60` in `/sdcard/Android/data/com.godot.game/files/config/`.

**Heat work (second playtest session):** the user asked for real optimizations rather than only an fps cap. Measured (uncapped; with the cap the GPU clock drops and times read flat): no single big cost left after the shadow optimizer; several ~1 ms options (softness, atlas size, render scale). The table's fill-light shadows only matter when the dealer's face is visible, so the new default **adaptive** shadow mode switches them by whether the dealer's head is on screen: GPU at the idle table 13.1 → about 9.7 ms with the same look. The user confirmed the relative cursor works well. Still open: how warm the phone gets now over a long session (user to judge), and `fps_cap = 30` as an extra option.

**Heat, round 3 (2026-11-22 evening):** second long playtest with adaptive shadows: skin 32 → 41 °C in about 20 minutes, thermal status 1 (light throttling); items lost their shadows at the table view, so adaptive was reverted (back to "mixed"). Freeze test on the phone: pausing every animation saves no GPU time, so Godot 4.1 redraws shadows every frame regardless. CPU about 0.8 core. New: idle frame pacing (30 fps while the picture is still). Unattended A/B heat test (15 min idle at the table, `.work/heatab.sh`): without idle pacing 33 → 42.1 °C (throttling status 2); with it 33 → 36.0 °C (no throttling). Best case only: the user pointed out real play rarely stays still for 2 s.

**Recon (draw-work counts, PC = same as phone):** per frame in the dealer room, the shadow passes draw 2,451 draw calls / 1.06 M triangles versus 182 / 72 k for the visible picture. With every animation frozen and nothing changing (verified for 20 frames), Godot 4.1 still redraws nearly all shadow maps every frame, so its shadow caching never kicks in here. Hiding the dealer or the smoker doesn't stop it. Candidate casters (outdoor props, the hidden crushed head) turned out not to cost anything. **Decision: shadow caching in our own engine build** (`engine/`), done next.

**Found and fixed (no engine change needed):** the engine diagnostic (patch 0001, custom Windows runtime built with `engine/build_windows.bat`) showed the 32 blinking table indicators (material swaps by `BlinkerBranch`) marking every table light's shadow dirty every frame. With their shadow casting off, Godot's own caching works: shadow draws 2,451 → 1,396 per frame running, 834 frozen; phone GPU 12.1 → 9.7 ms at the idle table; no visible change. What still triggers redraws: the dealer's head bob (real movement) and the smoker (other room, no effect on the dealer room's lights). Running total at the idle table on the S24 Ultra (uncapped GPU per frame): original 26.2 ms → mixed 13.1 → + blinker fix 9.7 ms. Heat run C (blinker fix, no idle pacing, 15 min idle): skin 39.1 °C, no throttling, against 42.1 °C and throttling status 2 in run A. Checked and ruled out: pausing the dealer's head bob (no change in shadow draws). Then the atlas layout fix (16 full-size slots, Android): the four fill lights near the table were evicting each other from Godot's 8 default full-size slots and redrawing every frame. Now: still frame 0 shadow draws, animating 1,197 (only the fill lights that reach the moving dealer redraw; the dealer has a second animation besides the head bob). Phone, same run: 11.6 → 9.7 ms GPU at the idle table.

**Next steps:**
1. The user tests the new build (relative cursor, overlay, stats screen) and compares 30 vs 60 fps for heat. Watch for stutters (first-time shader compiles), heat over a longer session, anything that looks off.
2. Identify the compute shader that fails on the Adreno with Forward+ (`vkCreateComputePipelines failed with error -13`, one per run). Nothing visible is missing in the tested scenes; check items, the endings and Double or Nothing.
3. Remaining gameplay coverage: every item, a full run to the ending, Double or Nothing, the controller in-game.
4. Phase 4: confirm-before-shoot on touch, bigger hit areas, Android back button, glyphs, haptics.
5. Phase 5: presets (High = Forward+ "mixed"/"cube", Medium = paraboloid or Mobile, Low = Compatibility), auto-detect by GPU, shader warm-up, measurements on low- and mid-range phones (devices still needed).

**Test-run notes:** compare only deterministic frames (`.work/td.txt` / `td2.txt` for the dealer intro; repeated door taps make it robust against slow loads). The test driver now has `fps`, `env`, `envset`, `overlays`, `shadowlist`, `shadow`, `omnimode`, `call`. An Android emulator from another of the user's projects is often connected: always use `adb -s R5CY54G6DWF`.

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

- **2026-11-22 (second session)** Deterministic frame comparison showed the 32-bit atlas works but the dealer's face still lacked shadows on the Mobile renderer; Forward+ on the phone matches the PC, so Android switched to Forward+. Profiled on the phone: shadows were the whole cost (37 fps → 120 fps without them). Built the shadow optimizer (skip unlit lights, paraboloid fill lights): 60–71 fps with the face intact. 60 fps cap.
- **2026-11-22 (later)** Phone visuals: found Godot's phone-only quality cuts (vertex shading etc.) and set them to the PC values. Found that the S3TC software decoding washed out colours, and wrote the ETC2 transcoder; colours now match. Found the 16-bit shadow atlas losing shadows on Adreno, and added a runtime 32-bit override (untested). Test driver gained `inspect`, `lights`, `mobile_settings`, `texinfo`, `setall`, `vp`. Rule: compare only deterministic frames.
- **2026-11-22** Phase 1 audit. Repo set up with a strict `.gitignore`. PC tools (`gdpck.py`, `ecfg.py`, `build_patched_pck.py`). Steam stub, platform, boot (multiplayer lock), touch adapter, dev test driver. Desktop: full intro, waiver and first round by touch; controller menu navigation works. Android: official 4.1.1 template plus `_cl_` main-pack test APK; runs on S24 Ultra; switched to Mobile renderer; transparency fallback; immersive mode.
