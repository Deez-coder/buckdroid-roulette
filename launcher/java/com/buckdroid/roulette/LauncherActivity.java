/* LauncherActivity - Buckdroid Roulette's launcher. Original code, GPL-3.0-or-later. Built on KitActivity (the user's
 * launcher UI kit, GPL-3.0-or-later).
 *
 * The app contains no part of Buckshot Roulette. The player picks their own "Buckshot Roulette.exe" (copied from their
 * Steam folder); the launcher copies it into the app's folder and starts our Godot engine with converter.pck (this
 * project's own code, shipped in the APK assets) to check it and convert it into game.pck. Play then starts the engine
 * on game.pck. Settings live in <external files>/config/graphics.ini and controls.ini, the files the game-side scripts
 * read (src/core/settings.gd), so both sides always agree.
 *
 * The engine activity (com.godot.game.GodotApp) runs in its own ":game" process: leaving the game ends that process and
 * the launcher stays.
 */
package com.buckdroid.roulette;

import android.content.Intent;
import android.net.Uri;
import android.widget.Button;
import android.widget.LinearLayout;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public class LauncherActivity extends KitActivity {
    static final int REQ_GAME_FILE = 1;
    static final String GAME_ACTIVITY = "com.godot.game.GodotApp";
    static final String STEAM_URL = "https://store.steampowered.com/app/2835570/Buckshot_Roulette/";

    File root, config, gamePck, sourceCopy, converterPck, statusFile;

    @Override protected void onCreate(android.os.Bundle b) {
        root = getExternalFilesDir(null);                  /* before super.onCreate: it draws the first page */
        config = new File(root, "config");
        config.mkdirs();
        gamePck = new File(root, "game.pck");
        sourceCopy = new File(root, "import/Buckshot Roulette.exe");
        converterPck = new File(root, "converter.pck");
        statusFile = new File(root, "convert_status.json");
        super.onCreate(b);
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

    @Override protected void onResume() {
        /* Back from a conversion: once it succeeded the 800 MB copy of the .exe is no longer needed. */
        JSONObject s = status();
        if (s != null && "done".equals(s.optString("state")) && sourceCopy.exists()) sourceCopy.delete();
        super.onResume();
    }

    /* ------------------------------------------------------------ Game */
    void gamePage() {
        boolean ready = gameReady();
        JSONObject s = status();
        LinearLayout card = card();
        card.addView(text("Buckshot Roulette", 20, TEXT, true));
        card.addView(text("Single player. Multiplayer is coming later.", 13, DIM, false));
        card.addView(space(12));
        card.addView(statusLine("Game", ready ? "ready" : "not set up yet", ready ? OK : WARN));
        if (ready) card.addView(statusLine("Version", s.optString("detail").replace(" is ready", "").replaceAll("\\s*\\(.*\\)\\.?$", ""), DIM));
        card.addView(space(16));
        Button play = button(ready ? "▶  Play" : "Set up the game first", ready ? ACCENT : CARD2);
        play.setTextSize(18);
        play.setEnabled(ready);
        play.setOnClickListener(v -> startActivity(new Intent().setClassName(this, GAME_ACTIVITY)));
        card.addView(play, fullWidth(56));
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
        if (sourceCopy.exists() && !ready) {
            imp.addView(space(6));
            Button again = button("Convert the copied file again", CARD2);
            again.setOnClickListener(v -> startConversion());
            imp.addView(again, fullWidth(48));
        }
        imp.addView(space(6));
        imp.addView(text("Needs about 2 GB free while setting up, 0.8 GB afterwards.", 11, DIM, false));
        content.addView(imp);
    }

    @Override protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_GAME_FILE || res != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        background("Copying the game file…", () -> {
            sourceCopy.getParentFile().mkdirs();
            try (InputStream in = getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(sourceCopy)) {
                pipe(in, out);
            }
        }, this::startConversion);
    }

    /* Starts the engine with converter.pck (from the APK assets) as the main pack. */
    void startConversion() {
        try {
            try (InputStream in = getAssets().open("converter.pck"); OutputStream out = new FileOutputStream(converterPck)) { pipe(in, out); }
        } catch (Exception e) { toast("The converter is missing from this app: " + e.getMessage()); return; }
        statusFile.delete();
        String[] args = {"--main-pack", converterPck.getAbsolutePath(), "--",
                "--source=" + sourceCopy.getAbsolutePath(), "--out=" + gamePck.getAbsolutePath(),
                "--status=" + statusFile.getAbsolutePath()};
        startActivity(new Intent().setClassName(this, GAME_ACTIVITY).putExtra("command_line_params", args));
    }

    /* ------------------------------------------------------------ Graphics (src/core/settings.gd reads these keys) */
    void graphicsPage() {
        Ini g = graphics();
        LinearLayout p = card();
        p.addView(header("Picture"));
        p.addView(slider(g, "render_scale", "3D resolution", 50, 100, 5, 100, "%", 0.01f,
                "100% = the game's own picture. Lower is cooler and faster but softer; menus and text stay sharp."));
        p.addView(choice(g, "shadow_resolution", "Shadow detail", new String[]{"4096", "2048", "1024"},
                new String[]{"Full", "Medium", "Low"}, "4096", "Lower saves a little GPU work; shadow edges get coarser."));
        p.addView(choice(g, "shadow_softness", "Shadow edges", new String[]{"2", "0"}, new String[]{"Soft (original)", "Hard"}, "2",
                "Hard edges save about 11% GPU work."));
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
        perf.addView(toggle(g, "fps_counter", "Performance overlay", "on", "off", "off",
                "Frame rate, frame time, memory and heat in the top left corner."));
        content.addView(perf);
        content.addView(note("Changes apply the next time the game starts."));
    }

    /* ------------------------------------------------------------ Controls */
    void controlsPage() {
        Ini c = controls();
        LinearLayout t = card();
        t.addView(header("Touch"));
        t.addView(choice(c, "touch_mode", "Touch mode", new String[]{"direct", "relative"}, new String[]{"Tap", "Trackpad"}, "direct",
                "Tap: touch what you want to click. Trackpad: drag to move a cursor, tap to click."));
        if ("relative".equalsIgnoreCase(c.get("touch_mode", "direct"))) {
            t.addView(slider(c, "cursor_speed", "Cursor speed", 25, 400, 25, 100, "%", 0.01f, null));
            t.addView(slider(c, "cursor_size", "Cursor size", 50, 300, 25, 100, "%", 0.01f, null));
        } else {
            t.addView(toggle(c, "tap_assist", "Tap assist", "on", "off", "off",
                    "A tap that just misses goes to the nearest thing you can use."));
        }
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
    }
}
