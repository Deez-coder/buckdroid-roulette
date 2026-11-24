/* Ini - a settings file shared with the native side: "key = value" lines, ";" or "#" comments.
 *
 * A value is read from and written to its own line; every other line (comments, unknown keys, their order) stays as it
 * was, so a file with explanations written by the native code keeps them. Keys are matched without regard to case; when
 * a key appears twice, get() returns the first and set() changes both. Lines end in \r\n. Each call reads the file again,
 * so the launcher always shows what is on disk.
 *
 * Taken from SMO Android Port's LauncherActivity.Ini (2026-11). */
package com.buckdroid.roulette;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public class Ini {
    public final File file;
    public Ini(File f) { file = f; }

    public List<String> lines() {
        List<String> l = new ArrayList<>();
        if (!file.exists()) return l;
        try (BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            for (String s; (s = r.readLine()) != null; ) l.add(s);
        } catch (Exception ignored) { }
        return l;
    }
    static String keyOf(String line) {
        String t = line.trim();
        if (t.startsWith(";") || t.startsWith("#") || !t.contains("=")) return null;
        return t.substring(0, t.indexOf('=')).trim();
    }
    public String get(String key, String def) {
        for (String s : lines()) if (key.equalsIgnoreCase(keyOf(s))) return s.substring(s.indexOf('=') + 1).trim();
        return def;
    }
    public void set(String key, String value) {
        List<String> l = lines();
        boolean done = false;
        for (int i = 0; i < l.size(); i++) if (key.equalsIgnoreCase(keyOf(l.get(i)))) { l.set(i, key + " = " + value); done = true; }
        if (!done) l.add(key + " = " + value);
        write(l);
    }
    public void remove(String key) {
        List<String> l = lines();
        if (!l.removeIf(s -> key.equalsIgnoreCase(keyOf(s)))) return;
        write(l);
    }
    public void write(List<String> l) {
        if (file.getParentFile() != null) file.getParentFile().mkdirs();
        try (OutputStream o = new FileOutputStream(file)) {
            for (String s : l) o.write((s + "\r\n").getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) { }
    }
}
