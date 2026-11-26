/* LauncherActivity - Buckdroid Roulette's launcher. Original code, GPL-3.0-or-later. Built on KitActivity (the user's
 * launcher UI kit, GPL-3.0-or-later).
 *
 * The app contains no part of Buckshot Roulette. The player picks their own "Buckshot Roulette.exe" (copied from their
 * Steam folder); Converter checks it and converts it into game.pck in the app's folder, on a background thread, while
 * the Game page shows its progress in place of the Play button. Play then starts the engine on game.pck. Settings live in <external files>/config/graphics.ini and controls.ini, the files the game-side scripts
 * read (src/core/settings.gd), so both sides always agree.
 *
 * The engine activity (com.godot.game.GodotApp) runs in its own ":game" process: leaving the game ends that process and
 * the launcher stays.
 */
package com.buckdroid.roulette;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.net.Uri;

import org.json.JSONObject;

import java.io.File;
import java.nio.charset.StandardCharsets;

public class LauncherActivity extends KitActivity {
    static final int REQ_GAME_FILE = 1;
    static final String GAME_ACTIVITY = "com.godot.game.GodotApp";
    static final String STEAM_URL = "https://store.steampowered.com/app/2835570/Buckshot_Roulette/";

    File root, config, gamePck, statusFile;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView progPhase, progDetail;
    private ProgressBar progBar;

    @Override protected void onCreate(android.os.Bundle b) {
        root = getExternalFilesDir(null);                  /* before super.onCreate: it draws the first page */
        config = new File(root, "config");
        config.mkdirs();
        gamePck = new File(root, "game.pck");
        /* Left over from the first launcher version, which copied the .exe and converted in the engine. */
        Converter.deleteTree(new File(root, "import"));
        new File(root, "converter.pck").delete();
        statusFile = new File(root, "convert_status.json");
        /* Started from the home-screen shortcut: go straight into the game. */
        if (ACTION_PLAY.equals(getIntent().getAction()) && gameReady() && scriptsCurrent() && !converting()) {
            super.onCreate(b);
            startActivity(new Intent().setClassName(this, GAME_ACTIVITY));
            finish();
            return;
        }
        /* Sent here by the game because its scripts were out of date (StaleScripts): start it once they are updated. */
        playAfterUpdate = ACTION_PLAY.equals(getIntent().getAction()) && getIntent().getBooleanExtra(StaleScripts.EXTRA_AFTER_UPDATE, false);
        if (playAfterUpdate) toast("Updating the game first...");
        super.onCreate(b);
    }

    boolean playAfterUpdate;

    static final String ACTION_PLAY = "com.buckdroid.roulette.PLAY";

    /* A home-screen shortcut that starts the game. Its icon is the game's own, taken from the player's .exe during setup
     * (Converter.extractIcon, game_icon.png in the app's folder); without it the app's icon. */
    void addShortcut() {
        android.content.pm.ShortcutManager sm = getSystemService(android.content.pm.ShortcutManager.class);
        if (sm == null || !sm.isRequestPinShortcutSupported()) { toast("This home screen does not support shortcuts."); return; }
        File iconFile = new File(root, Converter.ICON_FILE);
        android.graphics.Bitmap bmp = iconFile.exists() ? android.graphics.BitmapFactory.decodeFile(iconFile.getPath()) : null;
        android.graphics.drawable.Icon icon = bmp != null ? android.graphics.drawable.Icon.createWithBitmap(bmp)
                : android.graphics.drawable.Icon.createWithResource(this, getApplicationInfo().icon);
        android.content.pm.ShortcutInfo info = new android.content.pm.ShortcutInfo.Builder(this, "play")
                .setShortLabel("Buckshot Roulette")
                .setIcon(icon)
                .setIntent(new Intent(this, LauncherActivity.class).setAction(ACTION_PLAY)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK))
                .build();
        sm.requestPinShortcut(info, null);
    }

    @Override protected String title() { return "Buckdroid Roulette"; }
    @Override protected String subtitle() { return "Play your own copy of Buckshot Roulette · " + appVersion(); }
    @Override protected String[] tabs() { return new String[]{"Game", "Graphics", "Controls", "About"}; }
    @Override protected void buildPage(int t) {
        switch (t) {
            case 0: gamePage(); break;
            case 1: graphicsPage(); break;
            case 2: controlsPage(); break;
            default: aboutPage(); break;
        }
    }

    Ini graphics() { return new Ini(new File(config, "graphics.ini")); }
    Ini controls() { return new Ini(new File(config, "controls.ini")); }

    /* ------------------------------------------------------------ conversion state */
    JSONObject status() {
        try {
            if (!statusFile.exists()) return null;
            return new JSONObject(new String(readAll(new java.io.FileInputStream(statusFile)), StandardCharsets.UTF_8));
        } catch (Exception e) { return null; }
    }
    boolean gameReady() {
        JSONObject s = status();
        return gamePck.exists() && s != null && "done".equals(s.optString("state"));
    }

    /* Switches that show or hide other settings redraw the page. */
    @Override protected void onToggle(Ini ini, String key, boolean checked) {
        if ("thermal_guard".equals(key)) ui.post(() -> show(tab));
        if ("cool_shadows".equals(key)) {
            ini.set("shadow_softness", checked ? "1" : "2");
            ini.set("shadow_resolution", checked ? "2048" : "4096");
            ui.post(() -> show(tab));
        }
    }

    static boolean converting() { Converter c = Converter.current; return c != null && "running".equals(c.state); }

    /* Whether the converted game carries this app version's scripts (Converter.payloadHash). */
    boolean scriptsCurrent() {
        JSONObject s = status();
        return s != null && Converter.payloadHash(this).equals(s.optString("payload"));
    }

    @Override protected void onResume() {
        super.onResume();
        /* After an app update: give the converted game the new scripts first (a minute; no game file needed). */
        if (!converting() && gameReady() && !scriptsCurrent()) {
            Converter.refresh(this, gamePck, statusFile);
            show(0);
        }
        ui.removeCallbacks(tick);
        if (converting()) ui.post(tick);
    }

    @Override protected void onPause() {
        super.onPause();
        ui.removeCallbacks(tick);
    }

    /* While a conversion runs: refresh the progress views four times a second, redraw the page when it ends. */
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            Converter c = Converter.current;
            if (c == null) return;
            if (!"running".equals(c.state)) {
                getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                if ("done".equals(c.state)) toast("The game is ready.");
                show(tab);
                if (playAfterUpdate && "done".equals(c.state) && gameReady() && scriptsCurrent()) {
                    playAfterUpdate = false;
                    startActivity(new Intent().setClassName(LauncherActivity.this, GAME_ACTIVITY));
                }
                return;
            }
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            if (progBar != null && progBar.isAttachedToWindow()) {
                progPhase.setText(c.phase);
                progDetail.setText(c.detail);
                progBar.setProgress(Math.round(c.fraction * 1000));
            }
            ui.postDelayed(this, 250);
        }
    };

    /* ------------------------------------------------------------ Game */
    void gamePage() {
        boolean busy = converting();
        boolean ready = !busy && gameReady();
        JSONObject s = status();
        LinearLayout card = card();
        card.addView(text("Buckshot Roulette", 20, TEXT, true));
        card.addView(text("Single player and online multiplayer with chat.", 13, DIM, false));
        card.addView(space(12));
        card.addView(statusLine("Game", busy ? "setting up..." : ready ? "ready" : "not set up yet", ready ? OK : busy ? ACCENT2 : WARN));
        if (ready) card.addView(statusLine("Version", s.optString("detail").replace(" is ready", "").replaceAll("\\s*\\(.*\\)\\.?$", ""), DIM));
        card.addView(space(16));
        if (busy) {
            /* The progress takes the Play button's place until the game is ready. */
            Converter c = Converter.current;
            progPhase = text(c.phase, 15, TEXT, true);
            card.addView(progPhase);
            progBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
            progBar.setMax(1000);
            progBar.setProgress(Math.round(c.fraction * 1000));
            progBar.setProgressTintList(ColorStateList.valueOf(ACCENT2));
            progBar.setProgressBackgroundTintList(ColorStateList.valueOf(CARD2));
            card.addView(progBar, fullWidth(20));
            progDetail = text(c.detail, 12, DIM, false);
            card.addView(progDetail);
            card.addView(text("Keep the app open. Everything stays on this phone.", 12, DIM, false));
            content.addView(card);
            ui.removeCallbacks(tick);
            ui.post(tick);
            return;
        }
        Button play = button(ready ? "▶  Play" : "Set up the game first", ready ? ACCENT : CARD2);
        play.setTextSize(18);
        play.setEnabled(ready);
        play.setOnClickListener(v -> startActivity(new Intent().setClassName(this, GAME_ACTIVITY)));
        card.addView(play, fullWidth(56));
        if (ready) {
            card.addView(space(6));
            Button sc = button("Add to home screen", CARD2);
            sc.setOnClickListener(v -> addShortcut());
            card.addView(sc, fullWidth(44));
            if (!new File(root, Converter.ICON_FILE).exists())
                card.addView(text("Set up again from your game file once to give the shortcut the game's own icon.", 11, DIM, false));
        }
        content.addView(card);

        if (s != null && "error".equals(s.optString("state"))) {
            LinearLayout err = card();
            err.addView(header("Last setup failed"));
            err.addView(warning(s.optString("message")));
            content.addView(err);
        }

        LinearLayout imp = card();
        imp.addView(header("Your game file"));
        imp.addView(text("You need your own copy of Buckshot Roulette from Steam. On your PC, open the game's folder "
                + "(Steam: right-click the game > Manage > Browse local files), copy \"Buckshot Roulette.exe\" to this phone, "
                + "then pick it here. The app checks it and converts it for the phone. Nothing is uploaded anywhere.", 13, DIM, false));
        imp.addView(space(8));
        Button pick = button(ready ? "Set up again from a game file…" : "Pick Buckshot Roulette.exe…", ready ? CARD2 : ACCENT2);
        pick.setOnClickListener(v -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
            startActivityForResult(i, REQ_GAME_FILE);
        });
        imp.addView(pick, fullWidth(48));
        imp.addView(space(6));
        imp.addView(text("Needs about 1.2 GB free while setting up, 0.75 GB afterwards. The picked file is only read; "
                + "you can delete it afterwards.", 11, DIM, false));
        content.addView(imp);

        /* Multiplayer: the name other players see, chat, and what is shared with them. */
        Ini mp = new Ini(new File(config, "multiplayer.ini"));
        LinearLayout m = card();
        m.addView(header("Multiplayer"));
        m.addView(text("Your name", 15, TEXT, false));
        android.widget.EditText name = new android.widget.EditText(this);
        name.setSingleLine(true);
        name.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(24)});
        name.setText(mp.get("nickname", ""));
        name.setHint("Player");
        name.setTextColor(TEXT);
        name.setHintTextColor(DIM);
        name.setBackground(round(CARD2, 10));
        name.setPadding(dp(12), dp(10), dp(12), dp(10));
        name.addTextChangedListener(new android.text.TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) { }
            @Override public void afterTextChanged(android.text.Editable s) {
                mp.set("nickname", s.toString().replace("=", "").replace(";", "").trim());
            }
        });
        m.addView(name, fullWidth(48));
        m.addView(toggle(mp, "chat", "In-game chat", "on", "off", "on", "Messages with the other players at the table."));
        m.addView(text("Games are played directly between the phones (the host's phone connects everyone). As in any "
                + "peer-to-peer game, the players at a table can see each other's internet address; nothing else about "
                + "you is shared, and the game and chat never pass through a server.", 11, DIM, false));
        content.addView(m);
    }

    @Override protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_GAME_FILE || res != RESULT_OK || data == null || data.getData() == null) return;
        statusFile.delete();
        Converter.start(this, data.getData(), gamePck, statusFile);
        show(0);
    }

    /* ------------------------------------------------------------ Graphics (src/core/settings.gd reads these keys) */
    void graphicsPage() {
        Ini g = graphics();
        LinearLayout p = card();
        p.addView(header("Picture"));
        p.addView(slider(g, "render_scale", "3D resolution", 50, 100, 5, 100, "%", 0.01f,
                "100% = the game's own picture. Lower is cooler and faster but softer; menus and text stay sharp."));
        /* "Cooler shadows": a shortcut for the two settings below (softness 1, detail Medium). Measured on a Galaxy S24
         * Ultra in a multiplayer match: about 30% less GPU work, and the screenshots look the same. */
        boolean cool = "1".equals(g.get("shadow_softness", "2")) && "2048".equals(g.get("shadow_resolution", "4096"));
        g.set("cool_shadows", cool ? "on" : "off");
        p.addView(toggle(g, "cool_shadows", "Cooler shadows", "on", "off", "off",
                "Shadow softness 1 and Medium detail: about 30% less GPU work and a cooler phone, with almost no visible "
                        + "difference. Sets the two options below."));
        p.addView(choice(g, "shadow_resolution", "Shadow detail", new String[]{"4096", "2048", "1024"},
                new String[]{"Full", "Medium", "Low"}, "4096", "Lower saves a little GPU work; shadow edges get coarser."));
        p.addView(choice(g, "shadow_softness", "Shadow edge softness", new String[]{"0", "1", "2", "3", "4", "5"},
                new String[]{"Hard", "1", "2", "3", "4", "5"}, "2",
                "2 is the original. Hard edges save about 11% GPU work; higher is softer and costs more."));
        p.addView(choice(g, "shadow_refresh", "Moving shadows", new String[]{"1", "2", "3"},
                new String[]{"Every frame", "Every 2nd", "Every 3rd"}, "1",
                "Every frame is the original. Every 3rd saves about 12% GPU work but moving shadows lag a little."));
        p.addView(choice(g, "mesh_detail", "Object detail", new String[]{"1.0", "2.0"}, new String[]{"Full", "Reduced"}, "1.0",
                "Reduced uses simpler versions of small or distant objects."));
        content.addView(p);

        LinearLayout perf = card();
        perf.addView(header("Performance"));
        perf.addView(choice(g, "fps_cap", "Frame rate limit", new String[]{"60", "30"}, new String[]{"60 fps", "30 fps"}, "60",
                "30 fps runs much cooler and saves battery."));
        perf.addView(toggle(g, "thermal_guard", "Heat guard", "on", "off", "on",
                "When the phone is about to throttle, lowers the 3D resolution a step until it cools down."));
        if (!"off".equalsIgnoreCase(g.get("thermal_guard", "on")))
            perf.addView(slider(g, "thermal_guard_level", "Heat guard steps in at", 80, 99, 1, 90, "%", 0.01f,
                    "How warm the phone may get first (Android's thermal headroom). Lower: steps in earlier, stays cooler."));
        perf.addView(toggle(g, "fps_counter", "Performance overlay", "on", "off", "off",
                "Frame rate, frame time, memory and heat in the top left corner."));
        content.addView(perf);

        LinearLayout adv = card();
        adv.addView(header("Advanced"));
        adv.addView(choice(g, "shadow_mode", "Shadow method", new String[]{"mixed", "cube", "paraboloid"},
                new String[]{"Balanced", "Exact", "Fast"}, "mixed",
                "Balanced: the main lights keep exact shadows, weak fill lights use cheaper ones (default). "
                + "Exact: every light like the PC (heaviest). Fast: all lights use the cheaper method (shading on faces changes)."));
        adv.addView(choice(g, "idle_fps", "Idle frame rate", new String[]{"0", "30"}, new String[]{"Off", "30 fps"}, "0",
                "30 fps while nothing on screen changes for 2 seconds; any touch restores full speed."));
        adv.addView(choice(g, "transparency_fallback", "Fade workaround", new String[]{"auto", "on", "off"},
                new String[]{"Auto", "On", "Off"}, "auto",
                "Hides fully faded objects on renderers that ignore fading. Auto: only where needed."));
        adv.addView(toggle(g, "telemetry", "Performance log", "on", "off", "off",
                "Writes frame rate, GPU time and heat readings every 5 seconds to the app's telemetry folder, for testing."));
        content.addView(adv);
        content.addView(note("Changes apply the next time the game starts."));
    }

    /* ------------------------------------------------------------ Controls */
    void controlsPage() {
        Ini c = controls();
        LinearLayout t = card();
        t.addView(header("Touch"));
        c.remove("touch_pad");   /* from the build where the buttons were a separate switch */
        t.addView(choice(c, "touch_mode", "Touch mode", new String[]{"direct", "relative", "pad"}, new String[]{"Tap", "Trackpad", "Buttons"}, "direct",
                "Tap: touch what you want to click. Trackpad: drag to move a cursor, tap to click. Buttons: a D-pad, A, B and a "
                        + "menu button over the game, played the game's controller way; tapping the game is off."));
        String mode = c.get("touch_mode", "direct");
        if ("pad".equalsIgnoreCase(mode)) {
            t.addView(slider(c, "touch_opacity", "Opacity", 10, 100, 5, 45, "%", 0.01f, null));
            t.addView(slider(c, "touch_scale", "Size", 60, 160, 5, 100, "%", 0.01f, null));
            t.addView(space(6));
            Button edit = button("Edit button layout", ACCENT2);
            edit.setOnClickListener(v -> startActivity(new Intent(this, TouchLayoutEditorActivity.class)
                    .putExtra(TouchLayoutEditorActivity.EXTRA_FILE, new File(config, "controls.ini").getAbsolutePath())));
            t.addView(edit, fullWidth(48));
            t.addView(text("The buttons hide while a controller is used and come back at the next touch.", 12, DIM, false));
        } else if ("relative".equalsIgnoreCase(mode)) {
            t.addView(slider(c, "cursor_speed", "Cursor speed", 25, 400, 25, 100, "%", 0.01f, null));
            t.addView(slider(c, "cursor_size", "Cursor size", 50, 300, 25, 100, "%", 0.01f, null));
        } else {
            t.addView(toggle(c, "tap_assist", "Tap assist", "on", "off", "off",
                    "A tap that just misses goes to the nearest thing you can use."));
        }
        t.addView(slider(c, "look_speed", "Look-around speed", 25, 300, 25, 100, "%", 0.01f,
                "Multiplayer: drag with two fingers to look around (Buttons mode: one finger on an empty spot)."));
        content.addView(t);

        LinearLayout pad = card();
        pad.addView(header("Controller"));
        pad.addView(text("Bluetooth and USB controllers work in the game's own way: the D-pad or stick picks, A confirms.",
                13, DIM, false));
        content.addView(pad);
        content.addView(note("The Android back button: press twice to leave a game, twice in the menu to quit."));
    }

    /* ------------------------------------------------------------ About */
    void aboutPage() {
        LinearLayout a = card();
        a.addView(header("About"));
        a.addView(text("Buckdroid Roulette lets people who own Buckshot Roulette on Steam play their own copy on Android. "
                + "The app contains no part of the game: you provide the game file, and it is converted on this phone. "
                + "Never share or upload converted game data.", 13, TEXT, false));
        a.addView(space(10));
        Button buy = button("Buy Buckshot Roulette on Steam", ACCENT2);
        buy.setOnClickListener(v -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(STEAM_URL))));
        a.addView(buy, fullWidth(48));
        content.addView(a);

        LinearLayout l = card();
        l.addView(header("Not affiliated"));
        l.addView(text("Buckdroid Roulette is an independent fan project. It is not made, endorsed or supported by "
                + "Mike Klubnika, CRITICAL REFLEX or Valve. Buckshot Roulette is their work and trademark.", 13, DIM, false));
        content.addView(l);

        LinearLayout lic = card();
        lic.addView(header("License"));
        lic.addView(text("The app's own code is free software under the GNU General Public License v3.0 or later. "
                + "The license covers only this project's code, not Buckshot Roulette. Built with the Godot Engine (MIT license).",
                13, DIM, false));
        content.addView(lic);

        /* User request: players can send their logs with a bug report (LogExport). */
        LinearLayout rep = card();
        rep.addView(header("Report a problem"));
        rep.addView(text("Saves the game's logs, your settings and your phone's model into one zip file in Downloads, "
                + "then opens the share menu so you can send it with your report. It contains no game files and no "
                + "passwords, but it does include your multiplayer name, player ID and lobby IDs.", 13, DIM, false));
        rep.addView(space(10));
        Button export = button("Export logs", CARD2);
        export.setOnClickListener(v -> { toast("Collecting the logs..."); LogExport.run(this); });
        rep.addView(export, fullWidth(48));
        content.addView(rep);

        /* User request: one button that puts every setting back to its default. The settings are the ini files in
         * config/ (a missing file or key means the default), so resetting deletes them. The converted game stays. */
        LinearLayout r = card();
        r.addView(header("Reset settings"));
        r.addView(text("Puts every setting back to its default: graphics, controls, the button layout and multiplayer "
                + "(name and chat). The game itself stays set up.", 13, DIM, false));
        r.addView(space(10));
        Button reset = button("Reset all settings", CARD2);
        reset.setOnClickListener(v -> new AlertDialog.Builder(this)
                .setTitle("Reset all settings?")
                .setMessage("Every setting goes back to its default. This cannot be undone.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Reset", (d, w) -> {
                    for (String f : new String[]{"graphics.ini", "controls.ini", "multiplayer.ini"}) new File(config, f).delete();
                    toast("All settings are back to their defaults.");
                    show(tab);
                })
                .show());
        r.addView(reset, fullWidth(48));
        content.addView(r);
    }
}
