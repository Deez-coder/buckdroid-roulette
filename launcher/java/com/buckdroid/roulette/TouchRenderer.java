/* TouchRenderer - draws one control the way SMO Android Port draws its touch controls, on an Android Canvas.
 *
 * The look (a port of the present pass's fragment shader, nvn_vk_draw.c PP_SHAPES, to Canvas paths):
 *   - a button: a dark fill (grey 7%) at the player's opacity, a white outline, a white icon; while pressed the fill turns
 *     white and the outline and icon dark (grey 10%). Outline and icon strokes are 0.15 of the radius wide, round ends;
 *     the outline and icon stay twice as opaque as the fill, so the controls read well at low opacity.
 *   - shapes: a circle (radius 0.86) for most buttons, rounded tabs for L R ZL ZR (ZL / ZR with one rounder outer corner),
 *     a cross for +, a bar for -;
 *   - icons: letters drawn from straight strokes (the tables below), filled triangles for the d-pad, a ring with an R and
 *     a small arrow for the right stick's click, a wave for SHAKE, a house for EXIT, a ring with L / R for the sticks' knobs;
 *   - rings (the sticks' bases and the on/off ring): a thin circle (0.88 to 1.0 of the radius), no fill.
 * Units: a control's own radius is 1, y points down. Taken from SMO Android Port, 2026-11. */
package com.buckdroid.roulette;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;

public final class TouchRenderer {
    /* The letters' strokes: x0 y0 x1 y1 in a button of radius 1 (y down), then each letter's first stroke and count. */
    static final float[][] STROKES = {
        {-0.32f, 0.42f, 0.0f, -0.42f}, {0.0f, -0.42f, 0.32f, 0.42f}, {-0.19f, 0.1f, 0.19f, 0.1f},                                            /* A */
        {-0.24f, -0.42f, -0.24f, 0.42f}, {-0.24f, -0.42f, 0.1f, -0.42f}, {0.1f, -0.42f, 0.24f, -0.3f}, {0.24f, -0.3f, 0.24f, -0.12f},
        {0.24f, -0.12f, 0.1f, 0.0f}, {-0.24f, 0.0f, 0.12f, 0.0f}, {0.12f, 0.0f, 0.28f, 0.13f}, {0.28f, 0.13f, 0.28f, 0.29f},
        {0.28f, 0.29f, 0.12f, 0.42f}, {0.12f, 0.42f, -0.24f, 0.42f},                                                                           /* B */
        {-0.3f, -0.42f, 0.3f, 0.42f}, {0.3f, -0.42f, -0.3f, 0.42f},                                                                            /* X */
        {-0.3f, -0.42f, 0.0f, 0.0f}, {0.3f, -0.42f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f, 0.42f},                                                    /* Y */
        {-0.48f, 0.02f, 0.0f, -0.44f}, {0.0f, -0.44f, 0.48f, 0.02f}, {-0.3f, -0.14f, -0.3f, 0.4f}, {0.3f, -0.14f, 0.3f, 0.4f}, {-0.3f, 0.4f, 0.3f, 0.4f},   /* a house */
        {-0.2f, -0.42f, -0.2f, 0.42f}, {-0.2f, 0.42f, 0.26f, 0.42f},                                                                           /* L */
        {-0.24f, -0.42f, -0.24f, 0.42f}, {-0.24f, -0.42f, 0.1f, -0.42f}, {0.1f, -0.42f, 0.26f, -0.28f}, {0.26f, -0.28f, 0.26f, -0.12f},
        {0.26f, -0.12f, 0.1f, 0.0f}, {0.1f, 0.0f, -0.24f, 0.0f}, {0.02f, 0.0f, 0.28f, 0.42f},                                                 /* R */
        {-0.24f, -0.42f, 0.24f, -0.42f}, {0.24f, -0.42f, -0.24f, 0.42f}, {-0.24f, 0.42f, 0.26f, 0.42f},                                        /* Z */
        {-0.46f, 0.0f, -0.345f, -0.092f}, {-0.345f, -0.092f, -0.23f, -0.13f}, {-0.23f, -0.13f, -0.115f, -0.092f}, {-0.115f, -0.092f, 0.0f, 0.0f},
        {0.0f, 0.0f, 0.115f, 0.092f}, {0.115f, 0.092f, 0.23f, 0.13f}, {0.23f, 0.13f, 0.345f, 0.092f}, {0.345f, 0.092f, 0.46f, 0.0f},           /* ~ */
    };
    static final int[][] LETTER = {{0, 3}, {3, 10}, {13, 2}, {15, 3}, {18, 5}, {23, 2}, {25, 7}, {32, 3}, {35, 8}};      /* A B X Y house L R Z ~ */
    static final int L_A = 0, L_HOUSE = 4, L_L = 5, L_R = 6, L_Z = 7, L_WAVE = 8;

    static final int FILL = 0x12, INK_PRESSED = 0x1A, BASE_GREY = 0xBF;      /* 7%, 10% and 75% grey */
    static final float STROKE = 0.15f;                                       /* outline and icon strokes, in radii */

    final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG), ink = new Paint(Paint.ANTI_ALIAS_FLAG), inkFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    final Path path = new Path(), tmp = new Path();
    final RectF rect = new RectF();

    public TouchRenderer() {
        fill.setStyle(Paint.Style.FILL);
        ink.setStyle(Paint.Style.STROKE);
        ink.setStrokeCap(Paint.Cap.ROUND);
        ink.setStrokeJoin(Paint.Join.ROUND);
        inkFill.setStyle(Paint.Style.FILL);
    }

    static int alpha(float a) { return Math.max(0, Math.min(255, Math.round(a * 255))); }
    static int grey(int a, int g) { return (a << 24) | (g << 16) | (g << 8) | g; }

    /* A button or knob with icon `icon` (TouchLayout.ICON) at (cx, cy), radius R pixels, at opacity op (0..1). */
    public void button(Canvas c, int icon, float cx, float cy, float R, float op, boolean pressed) {
        float io = Math.min(1f, op * 2f);
        int inkCol = pressed ? grey(alpha(io), INK_PRESSED) : grey(alpha(io), 0xFF);
        body(icon, cx, cy, R);
        fill.setColor(pressed ? grey(alpha(Math.min(1f, op * 1.6f)), 0xFF) : grey(alpha(op), FILL));
        c.drawPath(path, fill);
        ink.setStrokeWidth(STROKE * R);
        ink.setColor(inkCol);
        c.drawPath(path, ink);
        inkFill.setColor(inkCol);
        icon(c, icon, cx, cy, R);
    }

    /* A ring: a stick's base (bright = false: 75% grey) or the on/off ring (on: 90%, off: 45%). */
    public void ring(Canvas c, float cx, float cy, float R, float op, int greyLevel) {
        ink.setStrokeWidth(0.12f * R);
        ink.setColor(grey(alpha(op), greyLevel));
        c.drawCircle(cx, cy, 0.94f * R, ink);
    }

    /* the outline shape into `path` */
    void body(int g, float cx, float cy, float R) {
        path.reset();
        switch (g) {
            case 6: case 7: rbox(path, cx, cy, R, 0.9f, 0.62f, 0.22f, 0.22f, 0.22f, 0.22f); break;      /* L R tabs */
            case 8: rbox(path, cx, cy, R, 0.9f, 0.62f, 0.55f, 0.18f, 0.18f, 0.18f); break;               /* ZL: round top left */
            case 9: rbox(path, cx, cy, R, 0.9f, 0.62f, 0.18f, 0.55f, 0.18f, 0.18f); break;               /* ZR: round top right */
            case 10:                                                                                     /* + */
                rbox(path, cx, cy, R, 0.82f, 0.27f, 0.06f, 0.06f, 0.06f, 0.06f);
                tmp.reset(); rbox(tmp, cx, cy, R, 0.27f, 0.82f, 0.06f, 0.06f, 0.06f, 0.06f);
                path.op(tmp, Path.Op.UNION); break;
            case 11: rbox(path, cx, cy, R, 0.82f, 0.25f, 0.06f, 0.06f, 0.06f, 0.06f); break;             /* - */
            default: path.addCircle(cx, cy, 0.86f * R, Path.Direction.CW);
        }
    }

    /* a box of half size (hx, hy) with corner radii top left, top right, bottom left, bottom right, all in radii */
    void rbox(Path p, float cx, float cy, float R, float hx, float hy, float tl, float tr, float bl, float br) {
        rect.set(cx - hx * R, cy - hy * R, cx + hx * R, cy + hy * R);
        p.addRoundRect(rect, new float[]{tl * R, tl * R, tr * R, tr * R, br * R, br * R, bl * R, bl * R}, Path.Direction.CW);
    }

    void icon(Canvas c, int g, float cx, float cy, float R) {
        if (g >= 1 && g <= 4) letter(c, g - 1, cx, cy, R, 1f);
        else if (g == 5) letter(c, L_HOUSE, cx, cy, R, 1f);
        else if (g == 6 || g == 7) letter(c, g == 6 ? L_L : L_R, cx, cy, R, 1f);
        else if (g == 8 || g == 9) { letter(c, L_Z, cx - 0.27f * R, cy, R, 0.8f); letter(c, g == 8 ? L_L : L_R, cx + 0.29f * R, cy, R, 0.8f); }
        else if (g >= 12 && g <= 15) arrow(c, g - 12, cx, cy, R);
        else if (g == 16) {                                                              /* R3: a ring with R, a small arrow above it */
            c.drawCircle(cx, cy + 0.18f * R, 0.44f * R, ink);
            letter(c, L_R, cx, cy + 0.18f * R, R, 0.55f);
            tri(c, cx, cy, R, 0.0f, -0.33f, 0.2f, -0.58f, -0.2f, -0.58f);
        } else if (g == 17) letter(c, L_WAVE, cx, cy, R, 1f);
        else if (g == 18 || g == 19) {                                                   /* a stick's knob */
            c.drawCircle(cx, cy, 0.56f * R, ink);
            letter(c, g == 18 ? L_L : L_R, cx, cy, R, 0.62f);
        }
    }

    /* letter k centred at (ox, oy), scaled by sc (its strokes keep the same width) */
    void letter(Canvas c, int k, float ox, float oy, float R, float sc) {
        for (int j = 0; j < LETTER[k][1]; j++) {
            float[] s = STROKES[LETTER[k][0] + j];
            c.drawLine(ox + s[0] * sc * R, oy + s[1] * sc * R, ox + s[2] * sc * R, oy + s[3] * sc * R, ink);
        }
    }

    /* the d-pad's filled triangle, pointing up, turned a quarter clockwise `turns` times (0 up, 1 right, 2 down, 3 left) */
    void arrow(Canvas c, int turns, float cx, float cy, float R) {
        float[] p = {0.0f, -0.42f, 0.4f, 0.28f, -0.4f, 0.28f};
        for (int t = 0; t < turns; t++) for (int i = 0; i < 6; i += 2) { float x = p[i]; p[i] = -p[i + 1]; p[i + 1] = x; }
        tri(c, cx, cy, R, p[0], p[1], p[2], p[3], p[4], p[5]);
    }

    void tri(Canvas c, float cx, float cy, float R, float x0, float y0, float x1, float y1, float x2, float y2) {
        tmp.reset();
        tmp.moveTo(cx + x0 * R, cy + y0 * R); tmp.lineTo(cx + x1 * R, cy + y1 * R); tmp.lineTo(cx + x2 * R, cy + y2 * R); tmp.close();
        c.drawPath(tmp, inkFill);
    }
}
