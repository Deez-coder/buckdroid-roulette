/* TouchLayout - the on-screen buttons, where they sit as made, and the player's own places from controls.ini.
 *
 * Positions are parts of the window's width (x) and height (y); radii are parts of the window's height, so a button stays
 * round on any screen. The player's layout is one line per moved button, "pos_<KEY> = x y size" (size 1 = as made),
 * written by TouchLayoutEditorActivity; a button without a line keeps its place as made.
 *
 * Buckshot Roulette's own controller support is menu-like (the D-pad moves the selection, A uses it, B goes back), so the
 * set is the touch-controls kit's look with only those buttons, plus MENU (the house), which acts as Android's back
 * button (press twice to leave a game or quit). No sticks: everything that is not a button is a normal tap on the game.
 *
 * Adapted from the touch-controls kit (SMO Android Port, GPL-3.0-or-later), 2026-11. */
package com.buckdroid.roulette;

import java.util.Locale;

public final class TouchLayout {
    /* What a button sends: Godot's joypad button numbers (JoyButton), or MENU. */
    public static final int J_A = 0, J_B = 1, J_UP = 11, J_DOWN = 12, J_LEFT = 13, J_RIGHT = 14, MENU = -2;

    /* Icons (TouchRenderer): 1 A, 2 B, 5 a house, 12-15 arrows up right down left. */
    public static final String[] KEYS = {"A", "B", "UP", "DOWN", "LEFT", "RIGHT", "MENU"};
    public static final int[] BIT = {J_A, J_B, J_UP, J_DOWN, J_LEFT, J_RIGHT, MENU};
    public static final int[] ICON = {1, 2, 12, 14, 15, 13, 5};
    public static final float[][] DEF = {      /* x, y, radius (parts of the height) */
        {0.925f, 0.640f, 0.085f}, {0.840f, 0.820f, 0.085f},                                                      /* A, B: bottom right */
        {0.110f, 0.560f, 0.065f}, {0.110f, 0.840f, 0.065f}, {0.045f, 0.700f, 0.065f}, {0.175f, 0.700f, 0.065f},  /* the D-pad: bottom left */
        {0.050f, 0.090f, 0.050f}};                                                                               /* MENU: top left */
    public static final int N = KEYS.length, NBUTTONS = N;
    /* No sticks in this layout; the editor checks i >= LSTICK to draw one. */
    public static final int LSTICK = N, RSTICK = N + 1;
    /* the hide/show ring at the top centre: always there, faint while the buttons are hidden */
    public static final float TOGGLE_X = 0.500f, TOGGLE_Y = 0.060f, TOGGLE_R = 0.032f;
    public static final float KNOB = 0.46f;

    public final float[] x = new float[N], y = new float[N], size = new float[N];

    public TouchLayout() { reset(); }

    public void reset() { for (int i = 0; i < N; i++) reset(i); }
    public void reset(int i) { x[i] = DEF[i][0]; y[i] = DEF[i][1]; size[i] = 1f; }
    public float radius(int i, float scale) { return DEF[i][2] * scale * size[i]; }

    public void load(Ini ini) {
        reset();
        for (int i = 0; i < N; i++) {
            String v = ini.get("pos_" + KEYS[i], null);
            if (v == null) continue;
            String[] p = v.trim().split("\\s+");
            if (p.length >= 2) { x[i] = clamp(num(p[0], x[i]), 0, 1); y[i] = clamp(num(p[1], y[i]), 0, 1); }
            if (p.length >= 3) size[i] = clamp(num(p[2], 1f), 0.5f, 2.5f);
        }
    }

    /* Only buttons the player moved or resized get a line; the others lose theirs. */
    public void save(Ini ini) {
        for (int i = 0; i < N; i++) {
            boolean moved = Math.abs(x[i] - DEF[i][0]) > 0.001f || Math.abs(y[i] - DEF[i][1]) > 0.001f || Math.abs(size[i] - 1f) > 0.001f;
            if (moved) ini.set("pos_" + KEYS[i], String.format(Locale.ROOT, "%.3f %.3f %.2f", x[i], y[i], size[i]));
            else ini.remove("pos_" + KEYS[i]);
        }
    }

    static float num(String s, float def) { try { return Float.parseFloat(s.trim()); } catch (Exception e) { return def; } }
    static float clamp(float v, float a, float b) { return v < a ? a : v > b ? b : v; }
}
