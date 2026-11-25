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
 * controller binding for free look) and works as a floating left stick from where it landed (the game turns the camera
 * with the left stick while the trigger is held). Lifting it lets go of both.
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
    static final float LOOK_RADIUS = 0.12f;        /* full stick throw, in parts of the screen height */
    float[] sentAxes = new float[3];               /* left stick x, y and the left trigger, as last sent */
    final Finger[] fingers = new Finger[10];
    int sent;                                      /* the joypad buttons Godot has as pressed, bits by TouchLayout index */
    float aspect = 16f / 9f;

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
            if (f != null && f.look) {             /* the look finger: its offset is the stick */
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

    /* Sends the buttons and look axes that changed to Godot and redraws. */
    void update() {
        float[] axes = new float[3];
        for (Finger f : fingers) {
            if (f.id < 0 || !f.look) continue;
            axes[2] = 1f;
            float[] d = lookOffset(f);
            axes[0] = d[0]; axes[1] = d[1];
        }
        Godot gl = godot;
        if (gl != null) {
            for (int a = 0; a < 3; a++) {
                if (Math.abs(axes[a] - sentAxes[a]) < 0.01f) continue;
                sentAxes[a] = axes[a];
                final int axis = a == 2 ? 4 : a;       /* Godot: 0/1 left stick, 4 left trigger */
                final float v = axes[a];
                gl.runOnRenderThread(() -> GodotLib.joyaxis(PAD_ID, axis, v));
            }
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

    /* The look finger's offset from where it landed, as stick values -1..1 (y down, as Godot's stick axes). */
    float[] lookOffset(Finger f) {
        float r = LOOK_RADIUS * scale;
        float dx = (f.lx - f.x0) * aspect / r, dy = (f.ly - f.y0) / r, m = (float) Math.sqrt(dx * dx + dy * dy);
        if (m > 1) { dx /= m; dy /= m; }
        return new float[]{dx, dy};
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
