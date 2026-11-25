/* NetLatency - the phone's low-latency Wi-Fi mode while a multiplayer lobby or match is running.
 * Original code, part of Buckdroid Roulette (GPL-3.0-or-later).
 *
 * To save power, phones let the Wi-Fi radio doze between packets; a game that sends small packets now and then (as
 * this one does) then waits for the radio's next wake-up on every packet, which adds tens of milliseconds. Android's
 * low-latency Wi-Fi lock (API 29+; high-performance mode before) keeps the radio awake while the game is in front and
 * the screen is on. BuckdroidNet (GDScript) turns it on while in a lobby and off when leaving it. Mobile data is not
 * affected. TouchPad.attach() hands over the game activity's context (no extra engine patch). */
package com.buckdroid.roulette;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Build;

public final class NetLatency {
    private NetLatency() { }

    private static Context app;
    private static WifiManager.WifiLock lock;

    static void init(Context c) { if (c != null) app = c.getApplicationContext(); }

    /* true while in a multiplayer lobby or match. Returns whether the lock is held. */
    public static boolean setActive(boolean on) {
        try {
            if (app == null) return false;
            if (lock == null) {
                WifiManager wm = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);
                if (wm == null) return false;
                @SuppressWarnings("deprecation")
                int mode = Build.VERSION.SDK_INT >= 29 ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY : WifiManager.WIFI_MODE_FULL_HIGH_PERF;
                lock = wm.createWifiLock(mode, "buckdroid:multiplayer");
                lock.setReferenceCounted(false);
            }
            if (on && !lock.isHeld()) lock.acquire();
            else if (!on && lock.isHeld()) lock.release();
            return lock.isHeld();
        } catch (RuntimeException e) {   /* missing permission or no Wi-Fi service: play on without it */
            return false;
        }
    }
}
