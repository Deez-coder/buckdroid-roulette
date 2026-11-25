/* FrameRate - keeps the game's window from asking for the display's top refresh rate while it is touched.
 * Original code, part of Buckdroid Roulette (GPL-3.0-or-later).
 *
 * The game requests 60 Hz for its surface (engine patch 46-0002) and turns Android's touch boost off (46-0003/0005),
 * but on Android 15+ apps that target SDK 35+ also get per-view refresh-rate votes: a view that is touched or redrawn
 * votes for a high rate, and the panel (Galaxy S24 Ultra: 120 Hz) ran at 120 Hz in bursts while playing by touch.
 * Every view in the game's window here asks for the "normal" category instead (60 Hz class), which matches the
 * game's 60 fps and saves the display and compositor work. GodotApp calls apply() when the window is created and
 * whenever it regains focus (engine patch 46-0012). */
package com.buckdroid.roulette;

import android.app.Activity;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;

public final class FrameRate {
    private FrameRate() { }

    public static void apply(Activity a) {
        if (Build.VERSION.SDK_INT < 35 || a.getWindow() == null) return;
        preferNormal(a.getWindow().getDecorView());
    }

    static void preferNormal(View v) {
        if (Build.VERSION.SDK_INT < 35 || v == null) return;
        v.setRequestedFrameRate(View.REQUESTED_FRAME_RATE_CATEGORY_NORMAL);
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) preferNormal(g.getChildAt(i));
        }
    }
}
