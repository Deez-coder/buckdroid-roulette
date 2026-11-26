/* StaleScripts - keeps the game from starting with an older version's scripts after an app update.
 * Original code, part of Buckdroid Roulette (GPL-3.0-or-later).
 *
 * The launcher gives the converted game this app version's scripts (Converter.refresh) when it opens. But Android can
 * reopen the game activity directly (recent apps, or after the app was updated while the game was in the background),
 * skipping the launcher, and the game then ran the previous version's scripts: fixed bugs seemed to come back right
 * after updates (seen in testing). GodotApp asks check() before the engine starts (engine patch 46-0019); when the
 * scripts are not this version's, the launcher opens (it updates them and then starts the game) and the game process
 * ends before it loads anything. */
package com.buckdroid.roulette;

import android.app.Activity;
import android.content.Intent;

import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;

public final class StaleScripts {
    private StaleScripts() { }

    static final String EXTRA_AFTER_UPDATE = "com.buckdroid.roulette.AFTER_UPDATE";

    /* True when the game may start. False: the launcher was opened instead and the caller must finish at once. */
    public static boolean check(Activity a) {
        try {
            File status = new File(a.getExternalFilesDir(null), "convert_status.json");
            JSONObject s = new JSONObject(new String(KitActivity.readAll(new FileInputStream(status)), StandardCharsets.UTF_8));
            if ("done".equals(s.optString("state")) && Converter.payloadHash(a).equals(s.optString("payload"))) return true;
        } catch (Exception ignored) {
            /* no status: not set up yet, the launcher handles that too */
        }
        a.startActivity(new Intent(LauncherActivity.ACTION_PLAY).setClassName(a, "com.buckdroid.roulette.LauncherActivity")
                .putExtra(EXTRA_AFTER_UPDATE, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        return false;
    }
}
