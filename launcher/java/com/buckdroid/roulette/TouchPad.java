/* TouchPad - the on-screen buttons over the game (the touch-controls kit's look), sent to Godot as a gamepad.
 *
 * GodotApp (engine patch 46-0010) calls attach() in onCreate, connect() once Godot's main loop runs, and controllerUsed()
 * when a real controller sends input. The buttons press Godot joypad buttons on a virtual pad (device PAD_ID), which the
 * game's own controller support reads like any controller: the D-pad moves the selection, A uses it, B goes back. MENU acts
 * as Android's back button (BuckdroidBack: press twice to leave a game, twice in the menu to quit).
 *
 * It is one of the three touch modes (the user's choice): with touch_mode = pad the view takes every touch, so tapping the
 * game does nothing and only the buttons act. The buttons hide while a real controller is used and come back at the next
 * touch. The small ring at the top centre hides them for this session (touches still do nothing then).
 *
 * Looking around (multiplayer free look): a finger that starts on an empty spot holds the left trigger (the game's
 * controller binding for free look) and its movement is sent as relative mouse movement, which the game uses to turn
 * the camera while free look is held: the view follows the finger and stops when it stops (a stick would keep turning,
 * and the game's stick speed is slow). Lifting it lets go. controls.ini look_speed scales it, as in the touch modes.
 *
 * controls.ini (read at start and again when it changes, about once a second):
 *   touch_mode = direct | relative | pad   (the view is only added for pad)
 *   touch_opacity = 0.1..1 (0.45)   touch_scale = 0.6..1.6 (1.0)   pos_<KEY> = x y size (TouchLayout)
 *
 * Adapted from the touch-controls kit's TouchControlsView (SMO Android Port, GPL-3.0-or-later), 2026-11. */
package com.buckdroid.roulette;

import android.app.Activity;
import android.graphics.Canvas;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;

import androidx.activity.ComponentActivity;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotLib;

import java.io.File;

public final class TouchPad extends View {
    static final int PAD_ID = 15;                  /* Godot joypad slot; real controllers count up from 0 */

    final Activity activity;
    final TouchLayout layout = new TouchLayout();
    final TouchRenderer draw = new TouchRenderer();
    final Ini ini;
    volatile Godot godot;

    boolean on;                                    /* touch_mode = pad */
    float opacity = 0.45f, scale = 1f;
    long iniTime = -1, iniCheckedAt;
    boolean hiddenByRing, hiddenByController;

    static final class Finger { int id = -1, button = -1; boolean look; float x0, y0, lx, ly; }
    float sentTrigger = 0f;                        /* the left trigger (free look), as last sent */
    float lookSpeed = 1f;                          /* controls.ini look_speed */
    static final float LOOK_SCALE = 0.8f;          /* screen pixels -> game mouse units (the game turns 0.25 degree each); user: 0.4 felt slow */
    final Finger[] fingers = new Finger[10];
    int sent;                                      /* the joypad buttons Godot has as pressed, bits by TouchLayout index */
    float aspect = 16f / 9f;

    /* ------------------------------------------------------------ pass-through, set from GDScript (BuckdroidChat) */
    static volatile boolean passAll = false;
    static volatile float[] passRects = new float[0];   /* x0, y0, x1, y1 per area, parts of the screen */

    public static void setPassThrough(boolean all) { passAll = all; }
    public static void setPassRects(float[] rects) { passRects = rects != null ? rects : new float[0]; }

    static boolean inPassRect(float x, float y) {
        float[] r = passRects;
        for (int i = 0; i + 3 < r.length; i += 4)
            if (x >= r[i] && y >= r[i + 1] && x <= r[i + 2] && y <= r[i + 3]) return true;
        return false;
    }

    /* Puts the buttons over the game when touch_mode is pad; returns null otherwise. */
    public static TouchPad attach(Activity a) {
        File f = new File(new File(a.getExternalFilesDir(null), "config"), "controls.ini");
        TouchPad p = new TouchPad(a, f);
        if (!p.on) return null;
        a.addContentView(p, new ViewGroup.LayoutParams(-1, -1));
        return p;
    }

    TouchPad(Activity a, File controlsIni) {
        super(a);
        activity = a;
        for (int i = 0; i < fingers.length; i++) fingers[i] = new Finger();
        ini = new Ini(controlsIni);
        reload();
    }

    /* Godot is running: announce the virtual pad. */
    public void connect(Godot g) {
        godot = g;
        g.runOnRenderThread(() -> GodotLib.joyconnectionchanged(PAD_ID, true, "Buckdroid touch buttons"));
    }

    /* ------------------------------------------------------------ settings */
    void reload() {
        on = "pad".equalsIgnoreCase(ini.get("touch_mode", "direct"));
        opacity = TouchLayout.clamp(TouchLayout.num(ini.get("touch_opacity", "0.45"), 0.45f), 0.1f, 1f);
        scale = TouchLayout.clamp(TouchLayout.num(ini.get("touch_scale", "1.0"), 1f), 0.6f, 1.6f);
        lookSpeed = TouchLayout.clamp(TouchLayout.num(ini.get("look_speed", "1.0"), 1f), 0.25f, 3f);
        layout.load(ini);
        iniTime = ini.file.lastModified();
        invalidate();
    }
    void reloadIfChanged() {
        long now = System.currentTimeMillis();
        if (now - iniCheckedAt < 1000) return;
        iniCheckedAt = now;
        if (ini.file.lastModified() != iniTime) reload();
    }

    /* A real controller sent input: the buttons step aside until the next touch. */
    public void controllerUsed() {
        if (on && !hiddenByController) { hiddenByController = true; release(); invalidate(); }
    }
    public static boolean isController(int source) {
        return (source & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD
                || (source & InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK;
    }

    boolean shown() { return on && !hiddenByRing && !hiddenByController; }

    /* ------------------------------------------------------------ geometry (window parts; radii in parts of the height) */
    float distH(float ax, float ay, float bx, float by) { float dx = (ax - bx) * aspect, dy = ay - by; return (float) Math.sqrt(dx * dx + dy * dy); }
    int hitButton(float x, float y) {
        int best = -1; float bd = 1e9f;
        for (int i = 0; i < TouchLayout.NBUTTONS; i++) {
            float d = distH(x, y, layout.x[i], layout.y[i]), r = layout.radius(i, scale) * 1.25f;
            if (d < r && d < bd) { bd = d; best = i; }
        }
        return best;
    }
    boolean onRing(float x, float y) { return distH(x, y, TouchLayout.TOGGLE_X, TouchLayout.TOGGLE_Y) < TouchLayout.TOGGLE_R * scale * 1.6f; }
    static boolean isDpad(int i) { int b = TouchLayout.BIT[i]; return b >= TouchLayout.J_UP && b <= TouchLayout.J_RIGHT; }
    static boolean isFace(int i) { int b = TouchLayout.BIT[i]; return b == TouchLayout.J_A || b == TouchLayout.J_B; }

    @Override protected void onSizeChanged(int w, int h, int ow, int oh) { if (h > 0) aspect = (float) w / h; }

    /* ------------------------------------------------------------ touches */
    @Override public boolean onTouchEvent(MotionEvent e) {
        reloadIfChanged();
        int kind = e.getActionMasked(), idx = e.getActionIndex();
        float W = getWidth(), H = getHeight();
        if (kind == MotionEvent.ACTION_DOWN) {
            /* A new gesture. Every touch is ours (taps on the game are off in this mode); only buttons do something. */
            float x = e.getX() / W, y = e.getY() / H;
            if (!on) return false;
            /* Pass-through (set by the game's scripts): on menu and lobby screens every touch that is not on a pad
             * button reaches the game, and during play touches on our own screen boxes (chat, lobby ID entry) do. */
            if (hitButton(x, y) < 0 && !onRing(x, y) && (passAll || inPassRect(x, y))) return false;
            if (onRing(x, y)) { hiddenByRing = !hiddenByRing; hiddenByController = false; release(); invalidate(); return true; }
            if (hiddenByController) { hiddenByController = false; invalidate(); return true; }
            if (!shown()) return true;
        }
        for (int i = 0; i < e.getPointerCount(); i++) {
            int id = e.getPointerId(i);
            boolean up = kind == MotionEvent.ACTION_CANCEL
                    || ((kind == MotionEvent.ACTION_UP || kind == MotionEvent.ACTION_POINTER_UP) && i == idx);
            Finger f = null;
            for (Finger g : fingers) if (g.id == id) f = g;
            if (up) { if (f != null) { f.id = -1; f.button = -1; f.look = false; } continue; }
            float x = e.getX(i) / W, y = e.getY(i) / H;
            int b = hitButton(x, y);
            if (f != null && f.look) {             /* the look finger: its movement turns the camera */
                lookMove((x - f.lx) * W, (y - f.ly) * H);
                f.lx = x; f.ly = y; continue;
            }
            if (f == null) {                       /* a new finger: on a button it presses it, elsewhere it looks around */
                boolean looking = false;
                for (Finger g : fingers) if (g.id >= 0 && g.look) looking = true;
                if (b < 0 && looking) continue;
                for (Finger g : fingers) if (g.id < 0) { f = g; break; }
                if (f == null) continue;
                f.id = id;
                if (b < 0) { f.look = true; f.button = -1; f.x0 = f.lx = x; f.y0 = f.ly = y; continue; }
                f.button = b;
                if (TouchLayout.BIT[b] == TouchLayout.MENU) activity.runOnUiThread(this::menu);
            } else if (b >= 0 && b != f.button && ((isFace(b) && isFace(f.button)) || (isDpad(b) && isDpad(f.button)))) {
                f.button = b;                      /* rolling the thumb across A/B or around the D-pad */
            }
        }
        update();
        return true;
    }

    void menu() {
        if (activity instanceof ComponentActivity) ((ComponentActivity) activity).getOnBackPressedDispatcher().onBackPressed();
        else activity.onBackPressed();
    }

    /* Sends the buttons and the free-look trigger that changed to Godot and redraws. */
    void update() {
        float trigger = 0f;
        for (Finger f : fingers) if (f.id >= 0 && f.look) trigger = 1f;
        Godot gl = godot;
        if (gl != null && trigger != sentTrigger) {
            sentTrigger = trigger;
            final float v = trigger;
            gl.runOnRenderThread(() -> GodotLib.joyaxis(PAD_ID, 4, v));   /* Godot axis 4: left trigger */
        }
        int now = 0;
        for (Finger f : fingers) if (f.id >= 0 && f.button >= 0 && TouchLayout.BIT[f.button] >= 0) now |= 1 << f.button;
        int changed = now ^ sent;
        sent = now;
        Godot g = godot;
        if (changed != 0 && g != null) {
            final int c = changed, n = now;
            g.runOnRenderThread(() -> {
                for (int i = 0; i < TouchLayout.N; i++)
                    if ((c >> i & 1) != 0) GodotLib.joybutton(PAD_ID, TouchLayout.BIT[i], (n >> i & 1) != 0);
            });
        }
        invalidate();
    }
    void release() {
        for (Finger f : fingers) { f.id = -1; f.button = -1; f.look = false; }
        update();
    }

    /* Relative mouse movement for the game's free look (Godot's Android input: ACTION_MOVE with a relative source). */
    void lookMove(float dx, float dy) {
        Godot gl = godot;
        if (gl == null || (dx == 0 && dy == 0)) return;
        final float mx = dx * LOOK_SCALE * lookSpeed, my = dy * LOOK_SCALE * lookSpeed;
        gl.runOnRenderThread(() -> GodotLib.dispatchMouseEvent(MotionEvent.ACTION_MOVE, 0, mx, my, 0, 0, false, true, 0f, 0f, 0f));
    }

    /* ------------------------------------------------------------ drawing */
    @Override protected void onDraw(Canvas c) {
        if (!on) return;
        float W = getWidth(), H = getHeight();
        draw.ring(c, TouchLayout.TOGGLE_X * W, TouchLayout.TOGGLE_Y * H, TouchLayout.TOGGLE_R * scale * H, opacity,
                hiddenByRing ? 0x73 : 0xE6);
        if (!shown()) return;
        int held = 0;
        for (Finger f : fingers) if (f.id >= 0 && f.button >= 0) held |= 1 << f.button;
        for (int i = 0; i < TouchLayout.NBUTTONS; i++)
            draw.button(c, TouchLayout.ICON[i], layout.x[i] * W, layout.y[i] * H, layout.radius(i, scale) * H, opacity, (held >> i & 1) != 0);
    }
}
