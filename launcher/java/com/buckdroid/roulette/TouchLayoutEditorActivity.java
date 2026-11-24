/* TouchLayoutEditorActivity - the touch controls' editor: drag a control where it suits the player, make it bigger or
 * smaller, Save writes the pos_ lines of controls.ini (TouchLayout).
 *
 * Landscape and full screen, like the game's window, so a place here is the same place in the game. The controls are
 * drawn by the game's own renderer (TouchRenderer); the one being moved is outlined in yellow. The tools sit in a dark
 * panel at the top middle, where no control sits as made. The game reads the file again while it runs.
 * Start it with an Intent; the file is EXTRA_FILE (a path) or <external files>/config/controls.ini.
 * Taken from SMO Android Port (LayoutEditorActivity), 2026-11, via the touch-controls kit (GPL-3.0-or-later). */
package com.buckdroid.roulette;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.File;
import java.util.Locale;

public class TouchLayoutEditorActivity extends Activity {
    public static final String EXTRA_FILE = "controls_ini";
    static final int BG = 0xFF2B3340, PANEL = 0xE0101318, TOOL = 0xFF242A35, ACCENT = 0xFFE5393B, TEXT = 0xFFECEFF4, PICK = 0xFFFFD54F;

    final TouchLayout layout = new TouchLayout();
    final TouchRenderer draw = new TouchRenderer();
    Ini ini;
    float scale = 1f, opacity = 0.45f;
    boolean cameraStick = false;   /* Buckdroid: no sticks in our layout */
    int sel = -1;
    Board board;
    TextView info;

    /* Full screen with the bars hidden until a swipe (the game's window does the same, so the places match). */
    public static void fullScreen(Activity a) {
        if (Build.VERSION.SDK_INT >= 28)
            a.getWindow().getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        a.getWindow().setDecorFitsSystemWindows(false);
        WindowInsetsController c = a.getWindow().getInsetsController();
        if (c != null) {
            c.hide(WindowInsets.Type.systemBars());
            c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }
    @Override public void onWindowFocusChanged(boolean focus) { super.onWindowFocusChanged(focus); if (focus) fullScreen(this); }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        fullScreen(this);
        String path = getIntent().getStringExtra(EXTRA_FILE);
        ini = new Ini(path != null ? new File(path) : new File(new File(getExternalFilesDir(null), "config"), "controls.ini"));
        scale = TouchLayout.clamp(TouchLayout.num(ini.get("touch_scale", "1.0"), 1f), 0.6f, 1.6f);
        opacity = TouchLayout.clamp(TouchLayout.num(ini.get("touch_opacity", "0.45"), 0.45f), 0.25f, 1f);
        layout.load(ini);

        FrameLayout page = new FrameLayout(this);
        page.setBackgroundColor(BG);
        board = new Board(this);
        page.addView(board, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.VERTICAL);
        bar.setGravity(Gravity.CENTER_HORIZONTAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(PANEL);
        bg.setCornerRadius(dp(14));
        bar.setBackground(bg);
        bar.setPadding(dp(10), dp(8), dp(10), dp(8));
        info = new TextView(this);
        info.setTextColor(TEXT);
        info.setTextSize(13);
        info.setGravity(Gravity.CENTER);
        bar.addView(info);
        LinearLayout row1 = new LinearLayout(this), row2 = new LinearLayout(this);
        row1.addView(tool("Smaller", v -> resize(-0.1f)));
        row1.addView(tool("Bigger", v -> resize(0.1f)));
        row1.addView(tool("Put back", v -> { if (sel >= 0) { layout.reset(sel); changed(); } }));
        row2.addView(tool("Reset all", v -> { layout.reset(); sel = -1; changed(); }));
        row2.addView(tool("Cancel", v -> finish()));
        row2.addView(tool("Save", v -> { layout.save(ini); finish(); }));
        bar.addView(row1);
        bar.addView(row2);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER_HORIZONTAL | Gravity.TOP);
        lp.topMargin = dp(70);
        page.addView(bar, lp);
        setContentView(page);
        changed();
    }

    void resize(float d) {
        if (sel < 0) return;
        layout.size[sel] = TouchLayout.clamp(Math.round((layout.size[sel] + d) * 10f) / 10f, 0.5f, 2.5f);
        changed();
    }
    void changed() {
        info.setText(sel < 0 ? "Drag a control to move it. Tap one, then Smaller / Bigger."
                : name(sel) + ": size " + Math.round(layout.size[sel] * 100) + "%");
        board.invalidate();
    }
    static String name(int i) {
        String k = TouchLayout.KEYS[i];
        return i == TouchLayout.LSTICK ? "Left stick" : i == TouchLayout.RSTICK ? "Camera stick" : k.length() <= 2 ? k : k.charAt(0) + k.substring(1).toLowerCase(Locale.ROOT);
    }

    Button tool(String s, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setTextSize(13);
        GradientDrawable g = new GradientDrawable();
        g.setColor("Save".equals(s) ? ACCENT : TOOL);
        g.setCornerRadius(dp(10));
        b.setBackground(g);
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(92), dp(40));
        lp.setMargins(dp(3), dp(4), dp(3), 0);
        b.setLayoutParams(lp);
        return b;
    }
    int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    /* The board: a faint grid, the controls as the game draws them, dragged by a finger. */
    class Board extends View {
        final Paint grid = new Paint(), pick = new Paint(Paint.ANTI_ALIAS_FLAG), label = new Paint(Paint.ANTI_ALIAS_FLAG);
        float grabDx, grabDy;
        int drag = -1;

        Board(Context c) {
            super(c);
            grid.setColor(0x22FFFFFF);
            pick.setStyle(Paint.Style.STROKE);
            pick.setColor(PICK);
            label.setTextAlign(Paint.Align.CENTER);
            label.setTypeface(Typeface.DEFAULT_BOLD);
            label.setColor(Color.WHITE);
        }
        float r(int i) { return layout.radius(i, scale) * getHeight(); }
        boolean shown(int i) { return i != TouchLayout.RSTICK || cameraStick; }

        @Override protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            for (int i = 1; i < 10; i++) { c.drawLine(w * i / 10, 0, w * i / 10, h, grid); c.drawLine(0, h * i / 10, w, h * i / 10, grid); }
            draw.ring(c, TouchLayout.TOGGLE_X * w, TouchLayout.TOGGLE_Y * h, TouchLayout.TOGGLE_R * scale * h, 0.5f, 0xE6);      /* the on/off ring: fixed */
            float op = Math.max(opacity, 0.5f);
            for (int i = 0; i < TouchLayout.N; i++) {
                if (!shown(i)) continue;
                float cx = layout.x[i] * w, cy = layout.y[i] * h, rr = r(i);
                if (i >= TouchLayout.LSTICK) {
                    draw.ring(c, cx, cy, rr, op, TouchRenderer.BASE_GREY);
                    draw.button(c, TouchLayout.ICON[i], cx, cy, rr * TouchLayout.KNOB, op, false);
                    label.setTextSize(dp(11));
                    c.drawText(i == TouchLayout.LSTICK ? "MOVE" : "CAMERA", cx, cy + rr + dp(14), label);
                } else draw.button(c, TouchLayout.ICON[i], cx, cy, rr, op, false);
                if (i == sel) { pick.setStrokeWidth(dp(3)); c.drawCircle(cx, cy, rr + dp(4), pick); }
            }
        }

        @Override public boolean onTouchEvent(MotionEvent e) {
            float w = getWidth(), h = getHeight();
            switch (e.getActionMasked()) {
                case MotionEvent.ACTION_DOWN: {
                    drag = -1;
                    float best = 1e9f;
                    for (int i = 0; i < TouchLayout.N; i++) {         /* the nearest control under the finger, a little generous */
                        if (!shown(i)) continue;
                        float dx = e.getX() - layout.x[i] * w, dy = e.getY() - layout.y[i] * h, d = (float) Math.sqrt(dx * dx + dy * dy);
                        if (d < Math.max(r(i), dp(22)) * 1.15f && d < best) { best = d; drag = i; }
                    }
                    sel = drag;
                    if (drag >= 0) { grabDx = layout.x[drag] * w - e.getX(); grabDy = layout.y[drag] * h - e.getY(); }
                    changed();
                    return true;
                }
                case MotionEvent.ACTION_MOVE:
                    if (drag >= 0) {
                        layout.x[drag] = TouchLayout.clamp((e.getX() + grabDx) / w, 0, 1);
                        layout.y[drag] = TouchLayout.clamp((e.getY() + grabDy) / h, 0, 1);
                        invalidate();
                    }
                    return true;
                case MotionEvent.ACTION_UP: case MotionEvent.ACTION_CANCEL:
                    drag = -1;
                    return true;
            }
            return super.onTouchEvent(e);
        }
    }
}
