/* KitActivity - the launcher look of SMO Android Port, as a base class for another app's launcher.
 *
 * Everything is built in code: plain android.widget views, no XML layouts, no resources, no support libraries. It compiles
 * with javac against android.jar (API 30+) and works the same in a Gradle project.
 *
 * What it gives a subclass:
 *   - the page: a title and a subtitle at the top, a row of tabs that scrolls sideways, and a scrolling page below.
 *     The page is rebuilt from scratch on every change (show(tab)), and keeps its scroll position when the same tab is
 *     redrawn. It stays clear of the system bars (Android 15 draws apps under them).
 *   - cards (rounded panels), section headers, notes, status lines (label left, value right), buttons, spacing.
 *   - setting widgets bound to an ini file (Ini.java): choice (a row of segments), slider, toggle (a switch).
 *     A change is written to the file at once; choice and slider redraw the page so dependent text updates.
 *   - helpers: background work with a "please wait" dialog, a confirm dialog, toasts, dp(), file copy / unzip / delete.
 *
 * A subclass fills in title(), subtitle(), tabs() and buildPage(int), and adds cards to `content` there:
 *
 *     @Override protected void buildPage(int tab) {
 *         LinearLayout c = card();
 *         c.addView(header("Performance"));
 *         c.addView(toggle(ini, "vsync", "VSync", "on", "off", "on", "Waits for the screen."));
 *         content.addView(c);
 *     }
 *
 * Taken from SMO Android Port's LauncherActivity.java (2026-11); the look and behaviour are unchanged. */
package com.buckdroid.roulette;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

public abstract class KitActivity extends Activity {
    /* ------------------------------------------------------------ the palette (dark, one red and one blue accent) */
    public static final int BG = 0xFF101318,      /* the window */
                            CARD = 0xFF1B2029,    /* a card */
                            CARD2 = 0xFF242A35,   /* a quiet button, an unselected segment, the selected tab's pill */
                            TEXT = 0xFFECEFF4,    /* main text */
                            DIM = 0xFF9AA3B2,     /* help text, labels, unselected tabs */
                            ACCENT = 0xFFE5393B,  /* the main action (Play) */
                            ACCENT2 = 0xFF3B82F6, /* headers, selected segments, sliders, switches that are on, secondary actions */
                            OK = 0xFF34C77B,      /* a good status ("installed") */
                            WARN = 0xFFF5A524;    /* a warning status or note */

    /* ------------------------------------------------------------ what a subclass fills in */
    protected abstract String title();                   /* the big name at the top */
    protected abstract String subtitle();                /* the small line under it (version, a short description) */
    protected abstract String[] tabs();                  /* the tab names, left to right */
    protected abstract void buildPage(int tab);          /* add the cards of this tab to `content` */

    protected LinearLayout content;                      /* the page's column: add cards here in buildPage */
    protected int tab = 0;                               /* the tab on screen */
    private ScrollView scroll;
    private final List<TextView> tabViews = new ArrayList<>();

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);

        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setBackgroundColor(BG);

        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.VERTICAL);
        head.setPadding(dp(20), dp(18), dp(20), dp(6));
        head.addView(text(title(), 26, TEXT, true));
        String sub = subtitle();
        if (sub != null && !sub.isEmpty()) head.addView(text(sub, 13, DIM, false));
        page.addView(head);

        HorizontalScrollView tabScroll = new HorizontalScrollView(this);
        tabScroll.setHorizontalScrollBarEnabled(false);
        LinearLayout row = new LinearLayout(this);
        row.setPadding(dp(14), dp(6), dp(14), dp(6));
        String[] names = tabs();
        for (int i = 0; i < names.length; i++) {
            final int t = i;
            TextView tv = text(names[i], 15, DIM, true);
            tv.setPadding(dp(16), dp(9), dp(16), dp(9));
            tv.setOnClickListener(v -> show(t));
            row.addView(tv);
            tabViews.add(tv);
        }
        tabScroll.addView(row);
        page.addView(tabScroll);

        scroll = new ScrollView(this);
        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(16), dp(8), dp(16), dp(24));
        scroll.addView(content);
        page.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        page.setOnApplyWindowInsetsListener((v, in) -> {      /* keep clear of the status and navigation bars */
            v.setPadding(in.getSystemWindowInsetLeft(), in.getSystemWindowInsetTop(), in.getSystemWindowInsetRight(), in.getSystemWindowInsetBottom());
            return in;
        });
        setContentView(page);
        show(b != null ? b.getInt("tab", 0) : 0);
    }

    @Override protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); out.putInt("tab", tab); }
    /* Coming back from the game (or a file picker): the page is drawn again, so statuses are current. */
    @Override protected void onResume() { super.onResume(); if (content != null) show(tab); }

    /* Draws tab t from scratch. Call show(tab) after anything that changes what the page shows. */
    public void show(int t) {
        final int keep = t == tab && scroll != null ? scroll.getScrollY() : 0;      /* the same tab again: stay where the user was */
        tab = t;
        for (int i = 0; i < tabViews.size(); i++) {
            TextView tv = tabViews.get(i);
            tv.setTextColor(i == t ? TEXT : DIM);
            tv.setBackground(i == t ? round(CARD2, 18) : null);
        }
        content.removeAllViews();
        buildPage(t);
        if (keep > 0 && scroll != null) scroll.post(() -> scroll.scrollTo(0, keep));
    }

    /* ------------------------------------------------------------ setting widgets (each writes its key in the ini at once) */

    /* A row of segments, one per value; the selected one is blue. vals are written to the file, names are shown. */
    public View choice(Ini ini, String key, String label, String[] vals, String[] names, String def, String help) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(0, dp(10), 0, dp(4));
        row.addView(text(label, 15, TEXT, false));
        LinearLayout seg = new LinearLayout(this);
        seg.setPadding(0, dp(6), 0, 0);
        String cur = ini.get(key, def);
        for (int i = 0; i < vals.length; i++) {
            final String v = vals[i];
            boolean on = v.equalsIgnoreCase(cur);
            TextView b = text(names[i], 13, on ? Color.WHITE : DIM, true);
            b.setGravity(Gravity.CENTER);
            b.setPadding(dp(10), dp(8), dp(10), dp(8));
            b.setBackground(round(on ? ACCENT2 : CARD2, 10));
            b.setOnClickListener(x -> { ini.set(key, v); show(tab); });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, -2, 1);
            lp.setMargins(i == 0 ? 0 : dp(4), 0, 0, 0);
            seg.addView(b, lp);
        }
        row.addView(seg);
        if (help != null) row.addView(text(help, 12, DIM, false));
        return row;
    }

    /* A slider from min to max in steps; the label shows "label: value unit". The file gets value * scale with two decimals
     * (scale 0.01f with unit "%" stores 0.75 for 75%; scale 1f stores the number as shown). */
    public View slider(Ini ini, String key, String label, int min, int max, int step, int def, String unit, float scale, String help) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(0, dp(10), 0, dp(4));
        int cur = Math.round(parse(ini.get(key, String.valueOf(def * scale)), def * scale) / scale);
        cur = Math.max(min, Math.min(max, cur));
        TextView title = text(label + ": " + cur + unit, 15, TEXT, false);
        row.addView(title);
        SeekBar sb = new SeekBar(this);
        sb.setMax((max - min) / step);
        sb.setProgress((cur - min) / step);
        sb.setProgressTintList(ColorStateList.valueOf(ACCENT2));
        sb.setThumbTintList(ColorStateList.valueOf(ACCENT2));
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar s, int p, boolean u) { title.setText(label + ": " + (min + p * step) + unit); }
            public void onStartTrackingTouch(SeekBar s) { }
            public void onStopTrackingTouch(SeekBar s) {
                float v = (min + s.getProgress() * step) * scale;
                ini.set(key, String.format(java.util.Locale.ROOT, "%.2f", v));
                show(tab);
            }
        });
        row.addView(sb);
        if (help != null) row.addView(text(help, 12, DIM, false));
        return row;
    }

    /* A switch; the file gets `on` or `off`. It does not redraw the page (the switch animates); override onToggle to react. */
    public View toggle(Ini ini, String key, String label, String on, String off, String def, String help) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(0, dp(8), 0, dp(4));
        Switch s = new Switch(this);
        s.setText(label);
        s.setTextColor(TEXT);
        s.setTextSize(15);
        s.setChecked(on.equalsIgnoreCase(ini.get(key, def)));
        styleSwitch(s, getResources().getDisplayMetrics().density);
        s.setOnCheckedChangeListener((x, c) -> { ini.set(key, c ? on : off); onToggle(ini, key, c); });
        row.addView(s);
        if (help != null) row.addView(text(help, 12, DIM, false));
        return row;
    }
    protected void onToggle(Ini ini, String key, boolean checked) { }

    /* A switch shows its state by its track: blue when on, dark grey when off; the thumb is white when on, light grey when
     * off. The theme's own track is see-through and looks dull, so it gets a solid rounded bar. Static, so a game overlay or
     * in-game menu can style its switches the same way. */
    public static ColorStateList switchTrack() {
        return new ColorStateList(new int[][]{{android.R.attr.state_checked}, {}}, new int[]{ACCENT2, 0xFF3A404C});
    }
    public static ColorStateList switchThumb() {
        return new ColorStateList(new int[][]{{android.R.attr.state_checked}, {}}, new int[]{Color.WHITE, 0xFFB4BAC6});
    }
    public static void styleSwitch(Switch s, float density) {
        GradientDrawable t = new GradientDrawable();
        t.setShape(GradientDrawable.RECTANGLE);
        t.setColor(Color.WHITE);
        t.setCornerRadius(12 * density);
        t.setSize(Math.round(46 * density), Math.round(24 * density));
        s.setTrackDrawable(t);
        s.setTrackTintList(switchTrack());
        s.setTrackTintMode(android.graphics.PorterDuff.Mode.SRC_IN);
        s.setThumbTintList(switchThumb());
    }

    /* ------------------------------------------------------------ small views */

    /* A rounded panel; add a header() and rows to it, then content.addView(card). */
    public LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(18), dp(16), dp(18), dp(16));
        c.setBackground(round(CARD, 16));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.setMargins(0, dp(6), 0, dp(10));
        c.setLayoutParams(lp);
        return c;
    }
    /* A card's section title: small blue capitals with letter spacing. */
    public TextView header(String s) { TextView t = text(s.toUpperCase(), 12, ACCENT2, true); t.setLetterSpacing(0.08f); t.setPadding(0, 0, 0, dp(4)); return t; }
    /* A dim line under the cards ("Changes apply the next time the game starts."). */
    public TextView note(String s) { TextView t = text(s, 12, DIM, false); t.setPadding(dp(4), dp(4), dp(4), dp(4)); return t; }
    /* A warning line in a card (yellow, bold). */
    public TextView warning(String s) { TextView t = text("⚠ " + s, 12, WARN, true); t.setPadding(0, dp(2), 0, dp(6)); return t; }
    /* "Label ........ value": the label dim on the left, the value bold on the right in the given colour (OK, WARN, DIM, TEXT). */
    public View statusLine(String k, String v, int col) {
        LinearLayout r = new LinearLayout(this);
        r.setPadding(0, dp(3), 0, dp(3));
        r.addView(text(k, 14, DIM, false), new LinearLayout.LayoutParams(0, -2, 1));
        r.addView(text(v, 14, col, true));
        return r;
    }
    public TextView text(String s, int sp, int col, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(col);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }
    /* A rounded button in a solid colour: ACCENT for the main action, ACCENT2 for the next step, CARD2 for the rest.
     * Add it full width: card.addView(button(...), fullWidth(48)). */
    public Button button(String s, int col) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setTextSize(15);
        b.setBackground(round(col, 14));
        return b;
    }
    public LinearLayout.LayoutParams fullWidth(int heightDp) { return new LinearLayout.LayoutParams(-1, dp(heightDp)); }
    public View space(int h) { View v = new View(this); v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(h))); return v; }
    public GradientDrawable round(int col, int r) { GradientDrawable g = new GradientDrawable(); g.setColor(col); g.setCornerRadius(dp(r)); return g; }
    public int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }
    public void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }
    public String appVersion() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception e) { return "?"; }
    }

    /* ------------------------------------------------------------ dialogs and background work */
    public void confirm(String question, String verb, Runnable yes) {
        new AlertDialog.Builder(this).setMessage(question).setPositiveButton(verb, (d, w) -> yes.run()).setNegativeButton("Cancel", null).show();
    }
    /* A dialog whose screen was rebuilt meanwhile (rotation, the system ending it) is no longer attached, and dismiss() throws. */
    public static void dismissSafely(AlertDialog d) { try { if (d.isShowing()) d.dismiss(); } catch (IllegalArgumentException ignored) { } }
    public interface Work { void run() throws Exception; }
    /* Runs w on a thread behind a "what" dialog that cannot be cancelled, then done on the UI thread (a failure is a toast). */
    public void background(String what, Work w, Runnable done) {
        AlertDialog d = new AlertDialog.Builder(this).setMessage(what).setCancelable(false).show();
        new Thread(() -> {
            String err = null;
            try { w.run(); } catch (Exception e) { err = e.getMessage(); }
            final String fe = err;
            runOnUiThread(() -> { dismissSafely(d); if (isFinishing() || isDestroyed()) return; if (fe != null) toast("Failed: " + fe); done.run(); });
        }).start();
    }

    /* ------------------------------------------------------------ files */
    public static float parse(String s, float d) { try { return Float.parseFloat(s.trim()); } catch (Exception e) { return d; } }
    public static void pipe(InputStream in, OutputStream out) throws java.io.IOException {
        byte[] buf = new byte[1 << 16];
        for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
    }
    public static byte[] readAll(InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream o = new java.io.ByteArrayOutputStream();
        try (InputStream i = in) { pipe(i, o); }
        return o.toByteArray();
    }
    public static void copyFile(File a, File b) throws java.io.IOException {
        try (InputStream in = new FileInputStream(a); OutputStream out = new FileOutputStream(b)) { pipe(in, out); }
    }
    public static void deleteTree(File f) {
        File[] k = f.listFiles();
        if (k != null) for (File c : k) deleteTree(c);
        f.delete();
    }
    /* A .zip the user picked (a content Uri) into dest; fresh empties dest first. No entry may write outside dest. */
    public void unzip(Uri zip, File dest, boolean fresh) throws Exception {
        if (fresh) deleteTree(dest);
        dest.mkdirs();
        String base = dest.getCanonicalPath() + File.separator;
        try (ZipInputStream z = new ZipInputStream(getContentResolver().openInputStream(zip))) {
            for (ZipEntry e; (e = z.getNextEntry()) != null; ) {
                File out = new File(dest, e.getName());
                if (!out.getCanonicalPath().startsWith(base)) continue;
                if (e.isDirectory()) { out.mkdirs(); continue; }
                out.getParentFile().mkdirs();
                try (OutputStream os = new FileOutputStream(out)) { pipe(z, os); }
            }
        }
    }
}
