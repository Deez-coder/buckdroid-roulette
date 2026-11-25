/* LogExport - bundles what is needed to look into a reported problem into one zip and hands it to the player.
 * Original code, part of Buckdroid Roulette (GPL-3.0-or-later).
 *
 * The zip holds: the game's own log files (Godot's file log, user://logs), this app's recent system log (Android only
 * lets an app read its own lines: the launcher's and the game process's), the performance logs (telemetry/), the
 * settings (config/*.ini), the conversion status, and the phone's model, Android version and app version. No game
 * files, no passwords or accounts. It does contain the player's nickname, player ID and lobby IDs (they are in the log).
 * The zip is saved to Downloads (Android 10+; older versions: the app's own folder) and the share menu opens, so the
 * player can send it where they report the problem. Nothing is sent anywhere by the app itself. */
package com.buckdroid.roulette;

import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

final class LogExport {
    private LogExport() { }

    static final int MAX_FILE = 8 * 1024 * 1024;        /* per file in the zip */
    static final int MAX_TELEMETRY_FILES = 5;           /* the newest performance logs */

    /* Builds the zip on a background thread, then saves and shares it on the UI thread. */
    static void run(Activity a) {
        new Thread(() -> {
            String name = "BuckdroidRoulette-logs-" + new SimpleDateFormat("yyyy-MM-dd_HH-mm", Locale.US).format(new Date()) + ".zip";
            try {
                File zip = new File(a.getCacheDir(), name);
                build(a, zip);
                Uri uri = save(a, zip, name);
                a.runOnUiThread(() -> share(a, uri, name));
            } catch (Exception e) {
                a.runOnUiThread(() -> ((KitActivity) a).toast("Could not export the logs: " + e.getMessage()));
            }
        }, "log-export").start();
    }

    static void build(Activity a, File out) throws Exception {
        File ext = a.getExternalFilesDir(null);
        try (ZipOutputStream z = new ZipOutputStream(new java.io.FileOutputStream(out))) {
            String info = "app " + ((KitActivity) a).appVersion() + "\n"
                    + "device " + Build.MANUFACTURER + " " + Build.MODEL + " (" + Build.DEVICE + ")\n"
                    + "android " + Build.VERSION.RELEASE + " (SDK " + Build.VERSION.SDK_INT + ")\n"
                    + "abi " + Arrays.toString(Build.SUPPORTED_ABIS) + "\n"
                    + "exported " + new Date() + "\n";
            put(z, "info.txt", info.getBytes(StandardCharsets.UTF_8));
            put(z, "logcat.txt", logcat());
            /* Godot's file log: user://logs under the app's private folder (searched, the exact folder depends on the
             * engine's user-folder rules). */
            for (File f : findLogs(a.getFilesDir(), 4)) put(z, "game-log/" + f.getName(), read(f));
            if (ext != null) {
                for (File f : findLogs(ext, 3)) put(z, "game-log/" + f.getName(), read(f));
                File cfg = new File(ext, "config");
                File[] inis = cfg.listFiles((d, n) -> n.endsWith(".ini"));
                if (inis != null) for (File f : inis) put(z, "config/" + f.getName(), read(f));
                File status = new File(ext, "convert_status.json");
                if (status.isFile()) put(z, "convert_status.json", read(status));
                File[] tel = new File(ext, "telemetry").listFiles(File::isFile);
                if (tel != null) {
                    Arrays.sort(tel, (x, y) -> Long.compare(y.lastModified(), x.lastModified()));
                    for (int i = 0; i < Math.min(MAX_TELEMETRY_FILES, tel.length); i++) put(z, "telemetry/" + tel[i].getName(), read(tel[i]));
                }
            }
        }
    }

    /* Godot writes logs/godot.log (and older godot*.log copies) in its user folder. */
    static List<File> findLogs(File dir, int depth) {
        List<File> out = new ArrayList<>();
        if (dir == null || depth < 0) return out;
        File[] list = dir.listFiles();
        if (list == null) return out;
        for (File f : list) {
            if (f.isDirectory()) {
                if (!f.getName().equals("payload") && !f.getName().equals("telemetry")) out.addAll(findLogs(f, depth - 1));
            } else if (f.getName().endsWith(".log") && dir.getName().equals("logs")) {
                out.add(f);
            }
        }
        return out;
    }

    /* This app's lines from the system log (Android shows an app only its own). */
    static byte[] logcat() {
        try {
            Process p = new ProcessBuilder("logcat", "-d", "-v", "time", "-t", "20000").redirectErrorStream(true).start();
            byte[] b = KitActivity.readAll(p.getInputStream());
            p.waitFor();
            return b;
        } catch (Exception e) {
            return ("logcat not available: " + e).getBytes(StandardCharsets.UTF_8);
        }
    }

    static byte[] read(File f) throws Exception {
        try (InputStream in = new FileInputStream(f)) {
            byte[] b = KitActivity.readAll(in);
            return b.length > MAX_FILE ? Arrays.copyOfRange(b, b.length - MAX_FILE, b.length) : b;   /* the newest part */
        }
    }

    static void put(ZipOutputStream z, String name, byte[] data) throws Exception {
        z.putNextEntry(new ZipEntry(name));
        z.write(data);
        z.closeEntry();
    }

    /* Android 10+: into Downloads (no permission needed). Older: stays in the app's own folder. */
    static Uri save(Activity a, File zip, String name) throws Exception {
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
            v.put(MediaStore.MediaColumns.MIME_TYPE, "application/zip");
            v.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download");
            Uri uri = a.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri == null) throw new java.io.IOException("Downloads is not available");
            try (OutputStream o = a.getContentResolver().openOutputStream(uri); InputStream in = new FileInputStream(zip)) {
                o.write(KitActivity.readAll(in));
            }
            zip.delete();
            return uri;
        }
        File dst = new File(a.getExternalFilesDir(null), name);
        try (InputStream in = new FileInputStream(zip); OutputStream o = new java.io.FileOutputStream(dst)) {
            o.write(KitActivity.readAll(in));
        }
        zip.delete();
        return null;
    }

    static void share(Activity a, Uri uri, String name) {
        KitActivity k = (KitActivity) a;
        if (uri == null) {
            k.toast("Saved as " + name + " in Android/data/com.buckdroid.roulette/files.");
            return;
        }
        k.toast("Saved to Downloads: " + name);
        Intent send = new Intent(Intent.ACTION_SEND).setType("application/zip").putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            a.startActivity(Intent.createChooser(send, "Send the logs"));
        } catch (Exception ignored) { }
    }
}
