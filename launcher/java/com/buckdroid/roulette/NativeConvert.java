/* NativeConvert - the launcher's texture converter (native/bdconvert.cpp, libbdconvert.so). Original code,
 * GPL-3.0-or-later. */
package com.buckdroid.roulette;

final class NativeConvert {
    static { System.loadLibrary("bdconvert"); }
    private NativeConvert() { }

    /* One Godot .ctex with S3TC data in, the same texture with ETC2 data out (null if the input is not supported).
     * Safe to call from several threads at once. */
    static native byte[] ctexToEtc2(byte[] ctex);
}
