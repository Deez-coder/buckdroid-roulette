/* Converter - turns the player's own copy of Buckshot Roulette into the game.pck the engine runs. Original code,
 * GPL-3.0-or-later. Java port of converter/converter.gd (itself the on-device version of tools/build_patched_pck.py):
 * same checks, same patches, same output; textures go through libbdconvert (native/bdconvert.cpp).
 *
 * Runs on a background thread inside the launcher, so the launcher can show its progress in place. One conversion at a
 * time (Converter.current). Everything stays on the phone.
 *
 * PCK format 2 (see tools/gdpck.py): header "GDPC", u32 version 2, u32 engine major/minor/patch, u32 flags,
 * u64 file_base, 16 x u32 reserved; u32 count; per file u32 path length (padded to 4), path, u64 offset, u64 size,
 * 16 B md5, u32 flags; data aligned to 32 bytes. project.binary ("ECFG"): u32 count, then key/value pairs with values
 * in Godot's Variant encoding (see tools/ecfg.py).
 */
package com.buckdroid.roulette;

import android.content.Context;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;

final class Converter implements Runnable {
    static volatile Converter current;

    /* State the launcher shows (written by the worker, read by the UI thread). */
    volatile String state = "running";   /* running | done | error */
    volatile String phase = "Starting";
    volatile String detail = "";
    volatile String message = "";
    volatile float fraction = 0f;

    private final Context ctx;
    private final Uri source;
    private final File out, status, work;

    private Converter(Context c, Uri source, File out, File status) {
        this.ctx = c.getApplicationContext();
        this.source = source;
        this.out = out;
        this.status = status;
        this.work = new File(c.getCacheDir(), "convert");
    }

    /* Starts a conversion unless one is running. */
    static synchronized Converter start(Context c, Uri source, File out, File status) {
        if (current != null && "running".equals(current.state)) return current;
        current = new Converter(c, source, out, status);
        Thread t = new Thread(current, "buckdroid-convert");
        t.setPriority(Thread.NORM_PRIORITY - 1);
        t.start();
        return current;
    }

    static final class Entry { String path; long offset, size; byte[] md5; }

    private FileChannel src;
    private long pckStart;
    private int[] engine = new int[3];
    private final List<Entry> entries = new ArrayList<>();
    private final Map<String, Entry> byPath = new LinkedHashMap<>();

    @Override public void run() {
        ParcelFileDescriptor pfd = null;
        try {
            deleteTree(work);
            work.mkdirs();
            set("Checking the game file", "", 0f);
            JSONObject versions = new JSONObject(asset("payload/versions.json"));
            JSONArray autoloads = new JSONObject(asset("payload/autoloads.json")).getJSONArray("autoloads");
            pfd = ctx.getContentResolver().openFileDescriptor(source, "r");
            if (pfd == null) throw new Fail("The file could not be opened.");
            src = new FileInputStream(pfd.getFileDescriptor()).getChannel();
            readPck();
            JSONObject ver = identify(versions);
            if (ver == null) throw new Fail("This version of Buckshot Roulette is not supported yet. Supported: "
                    + supportedNames(versions) + ".");
            if (pckStart > 0) {
                long len = src.size();
                if (ver.optLong("exe_size", 0) != 0 && len != ver.getLong("exe_size"))
                    throw new Fail("The game file is incomplete or changed. Copy it again from your Steam folder.");
                set("Checking the game file", "Verifying " + ver.getString("name"), 0.01f);
                if (!sha256(len).equals(ver.getString("exe_sha256")))
                    throw new Fail("The game file does not match the original " + ver.getString("name") + ". Copy it again.");
                /* The game's own icon, from the player's .exe, for the home-screen shortcut. Stays on the phone. */
                try { extractIcon(new File(out.getParentFile(), ICON_FILE)); } catch (Throwable ignored) { }
            }

            set("Patching", ver.getString("name"), 0.08f);
            Map<String, byte[]> replaced = new LinkedHashMap<>();
            Ecfg pb = new Ecfg(read("res://project.binary"));
            String firstGameAutoload = null;
            for (String[] it : pb.items) if (it[0].startsWith("autoload/")) { firstGameAutoload = it[0]; break; }
            for (int i = 0; i < autoloads.length(); i++) {
                JSONObject a = autoloads.getJSONObject(i);
                pb.insertBefore(firstGameAutoload, "autoload/" + a.getString("name"), "*res://buckdroid/" + a.getString("script"));
            }
            JSONObject ov = versions.getJSONObject("overrides");
            applyOverrides(pb, ov.getJSONObject("common"));
            applyOverrides(pb, ov.getJSONObject("android"));
            replaced.put("res://project.binary", pb.toBytes());

            /* Godot 4.6 adaptations (see tools/build_patched_pck.py) */
            String cacheKey = "res://.godot/global_script_class_cache.cfg";
            String cache = utf8(read(cacheKey));
            replaced.put(cacheKey, cache.replace("\"icon\": \"\",", "\"icon\": \"\",\n\"is_abstract\": false,\n\"is_tool\": false,")
                    .getBytes(StandardCharsets.UTF_8));
            String mpKey = "res://multiplayer/scripts/user scripts/MP_ItemResource_User.gd";
            if (byPath.containsKey(mpKey)) {
                String mp = utf8(read(mpKey));
                for (String side : new String[]{"R", "L"})
                    for (String part : new String[]{"hand", "mesh"})
                        mp = mp.replace("@export var " + side + "_assigned_" + part + " : Node3D", "var " + side + "_assigned_" + part + " : Node3D");
                replaced.put(mpKey, mp.getBytes(StandardCharsets.UTF_8));
            }

            /* Textures: converted on worker threads into files in the cache folder (keeps memory low). */
            List<String[]> jobs = new ArrayList<>();   /* [import path, s3tc path] */
            for (Entry e : entries) {
                if (!e.path.endsWith(".import")) continue;
                String target = s3tcTarget(utf8(read(e.path)));
                if (target != null && byPath.containsKey(target)) jobs.add(new String[]{e.path, target});
            }
            Map<String, File> converted = new LinkedHashMap<>();
            int threads = Math.max(1, Math.min(6, Runtime.getRuntime().availableProcessors() - 2));
            ExecutorService pool = Executors.newFixedThreadPool(threads);
            AtomicInteger doneCount = new AtomicInteger();
            List<Future<File>> futures = new ArrayList<>();
            for (int i = 0; i < jobs.size(); i++) {
                final String path = jobs.get(i)[1];
                final File f = new File(work, "t" + i + ".ctex");
                futures.add(pool.submit(() -> {
                    byte[] etc2 = NativeConvert.ctexToEtc2(read(path));
                    if (etc2 == null) return null;
                    try (FileOutputStream o = new FileOutputStream(f)) { o.write(etc2); }
                    int n = doneCount.incrementAndGet();
                    set("Converting textures for the phone", n + " of " + jobs.size(), 0.1f + 0.6f * n / jobs.size());
                    return f;
                }));
            }
            pool.shutdown();
            int failed = 0;
            for (int i = 0; i < jobs.size(); i++) {
                File f = futures.get(i).get();
                if (f == null) { failed++; continue; }
                converted.put(jobs.get(i)[1], f);
                byte[] remap = (addEtc2Remap(utf8(read(jobs.get(i)[0])), jobs.get(i)[1]) + "\0").getBytes(StandardCharsets.UTF_8);
                replaced.put(jobs.get(i)[0], remap);
            }
            if (failed > 0) throw new Fail(failed + " textures could not be converted.");

            /* Our scripts */
            Map<String, byte[]> ours = new LinkedHashMap<>();
            collectPayload(ctx.getAssets(), "payload/buckdroid", ours);

            write(replaced, converted, ours);
            deleteTree(work);
            set("Done", ver.getString("name") + " is ready (" + converted.size() + " textures converted).", 1f);
            state = "done";
        } catch (Throwable t) {
            message = t instanceof Fail ? t.getMessage() : "Setup failed: " + t;
            state = "error";
            deleteTree(work);
        } finally {
            try { if (src != null) src.close(); } catch (Exception ignored) { }
            try { if (pfd != null) pfd.close(); } catch (Exception ignored) { }
            writeStatus();
        }
    }

    static final class Fail extends Exception { Fail(String m) { super(m); } }

    /* ------------------------------------------------------------ the game's icon (Windows .exe resources) */
    static final String ICON_FILE = "game_icon.png";

    /* Finds the largest icon (RT_ICON) in the .exe's resources and saves it as a PNG. Icons are stored as PNG or as a
     * 32-bit bitmap (BITMAPINFOHEADER, height doubled for the mask, rows bottom-up, BGRA). */
    private void extractIcon(File dst) throws Exception {
        int pe = readAt(0x3C, 4).getInt();
        ByteBuffer h = readAt(pe, 24);
        if (h.getInt(0) != 0x00004550) return;
        int nsec = h.getShort(6) & 0xFFFF, optSize = h.getShort(20) & 0xFFFF;
        ByteBuffer opt = readAt(pe + 24, optSize);
        int dirs = (opt.getShort(0) & 0xFFFF) == 0x20B ? 112 : 96;
        int resRva = opt.getInt(dirs + 16), resSize = opt.getInt(dirs + 20);
        if (resRva == 0 || resSize <= 0 || resSize > (64 << 20)) return;
        ByteBuffer sec = readAt(pe + 24 + optSize, nsec * 40);
        long resOff = -1;
        int secVa = 0, secRaw = 0;
        for (int i = 0; i < nsec; i++) {
            int va = sec.getInt(i * 40 + 12), vsz = Math.max(sec.getInt(i * 40 + 8), sec.getInt(i * 40 + 16));
            if (resRva >= va && resRva < va + vsz) { secVa = va; secRaw = sec.getInt(i * 40 + 20); resOff = secRaw + (long) (resRva - va); }
        }
        if (resOff < 0) return;
        ByteBuffer r = readAt(resOff, resSize);
        Bitmap best = null;
        for (int[] t : dirEntries(r, 0)) {
            if (t[0] != 3 || t[1] >= 0) continue;                      /* RT_ICON, a subdirectory */
            for (int[] id : dirEntries(r, t[1] & 0x7FFFFFFF)) {
                if (id[1] >= 0) continue;
                for (int[] lang : dirEntries(r, id[1] & 0x7FFFFFFF)) {
                    if (lang[1] < 0) continue;
                    int rva = r.getInt(lang[1]), size = r.getInt(lang[1] + 4);
                    long off = secRaw + (long) (rva - secVa);
                    if (size <= 0 || size > (16 << 20)) continue;
                    Bitmap b = decodeIcon(readAt(off, size).array());
                    if (b != null && (best == null || b.getWidth() > best.getWidth())) best = b;
                }
            }
        }
        if (best == null || best.getWidth() < 48) return;
        File tmp = new File(dst.getPath() + ".part");
        try (FileOutputStream o = new FileOutputStream(tmp)) { best.compress(Bitmap.CompressFormat.PNG, 100, o); }
        if (!tmp.renameTo(dst)) tmp.delete();
    }

    /* A resource directory's entries: {id (or -1 for a named entry), offset (negative: a subdirectory)}. */
    private static List<int[]> dirEntries(ByteBuffer r, int at) {
        int n = (r.getShort(at + 12) & 0xFFFF) + (r.getShort(at + 14) & 0xFFFF);
        List<int[]> l = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            int name = r.getInt(at + 16 + i * 8), off = r.getInt(at + 16 + i * 8 + 4);
            l.add(new int[]{name < 0 ? -1 : name, off});
        }
        return l;
    }

    private static Bitmap decodeIcon(byte[] d) {
        if (d.length > 8 && (d[0] & 0xFF) == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G')
            return BitmapFactory.decodeByteArray(d, 0, d.length);
        ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
        if (d.length < 40 || b.getInt(0) != 40) return null;
        int w = b.getInt(4), hgt = b.getInt(8) / 2, bits = b.getShort(14);
        if (bits != 32 || w <= 0 || w > 1024 || hgt != w || 40 + (long) w * hgt * 4 > d.length) return null;
        int[] px = new int[w * hgt];
        for (int y = 0; y < hgt; y++)
            for (int x = 0; x < w; x++) {
                int o = 40 + ((hgt - 1 - y) * w + x) * 4;
                px[y * w + x] = (d[o + 3] & 0xFF) << 24 | (d[o + 2] & 0xFF) << 16 | (d[o + 1] & 0xFF) << 8 | (d[o] & 0xFF);
            }
        return Bitmap.createBitmap(px, w, hgt, Bitmap.Config.ARGB_8888);
    }

    private void set(String p, String d, float f) {
        phase = p;
        detail = d;
        fraction = f;
    }

    /* convert_status.json, which the launcher reads to know whether the game is ready (and why setup failed). */
    private void writeStatus() {
        try {
            JSONObject o = new JSONObject();
            o.put("state", state).put("phase", phase).put("detail", detail).put("message", message).put("fraction", fraction);
            try (FileOutputStream f = new FileOutputStream(status)) { f.write(o.toString().getBytes(StandardCharsets.UTF_8)); }
        } catch (Exception ignored) { }
    }

    /* ------------------------------------------------------------ reading the source pack */
    private ByteBuffer readAt(long pos, int len) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN);
        while (b.hasRemaining()) {
            int n = src.read(b, pos + b.position());
            if (n < 0) throw new Fail("The game file ended early.");
        }
        b.flip();
        return b;
    }

    private void readPck() throws Exception {
        long len = src.size();
        ByteBuffer m = readAt(0, 4);
        if ("GDPC".equals(new String(m.array(), 0, 4, StandardCharsets.US_ASCII))) pckStart = 0;
        else {
            ByteBuffer t = readAt(len - 12, 12);
            long size = t.getLong();
            if (!"GDPC".equals(new String(t.array(), 8, 4, StandardCharsets.US_ASCII)))
                throw new Fail("This file is not Buckshot Roulette (no game pack in it).");
            pckStart = len - 12 - size;
        }
        ByteBuffer h = readAt(pckStart, 4 + 4 + 12 + 4 + 8 + 64 + 4);
        h.position(4);
        int version = h.getInt();
        engine = new int[]{h.getInt(), h.getInt(), h.getInt()};
        int flags = h.getInt();
        long fb = h.getLong();
        if (version != 2) throw new Fail("This game pack format (" + version + ") is not supported.");
        if ((flags & 1) != 0) throw new Fail("This game file is encrypted; it is not a supported version.");
        long fileBase = (pckStart == 0 || fb > pckStart) ? fb : pckStart + fb;
        h.position(4 + 4 + 12 + 4 + 8 + 64);
        int count = h.getInt();
        long pos = pckStart + 4 + 4 + 12 + 4 + 8 + 64 + 4;
        /* The directory is small (a few hundred KB): read it in one go. */
        ByteBuffer d = readAt(pos, (int) Math.min(len - pos, 16 << 20));
        for (int i = 0; i < count; i++) {
            int n = d.getInt();
            byte[] raw = new byte[n];
            d.get(raw);
            int z = 0;
            while (z < n && raw[z] != 0) z++;
            Entry e = new Entry();
            e.path = new String(raw, 0, z, StandardCharsets.UTF_8);
            e.offset = fileBase + d.getLong();
            e.size = d.getLong();
            e.md5 = new byte[16];
            d.get(e.md5);
            d.getInt();
            entries.add(e);
            byPath.put(e.path, e);
        }
    }

    byte[] read(String path) throws Exception {
        Entry e = byPath.get(path);
        return readAt(e.offset, (int) e.size).array();
    }

    private JSONObject identify(JSONObject versions) throws Exception {
        Entry pb = byPath.get("res://project.binary");
        if (pb == null) return null;
        String eng = engine[0] + "." + engine[1] + "." + engine[2];
        String md5 = hex(pb.md5);
        JSONArray sup = versions.getJSONArray("supported");
        for (int i = 0; i < sup.length(); i++) {
            JSONObject v = sup.getJSONObject(i);
            if (v.getString("engine").equals(eng) && v.getString("project_binary_md5").equals(md5)) return v;
        }
        return null;
    }

    private static String supportedNames(JSONObject versions) throws Exception {
        JSONArray sup = versions.getJSONArray("supported");
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < sup.length(); i++) b.append(i > 0 ? ", " : "").append(sup.getJSONObject(i).getString("name"));
        return b.toString();
    }

    private String sha256(long len) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        ByteBuffer b = ByteBuffer.allocate(1 << 20);
        long pos = 0;
        while (pos < len) {
            b.clear();
            int n = src.read(b, pos);
            if (n < 0) break;
            md.update(b.array(), 0, n);
            pos += n;
            set("Checking the game file", detail, 0.01f + 0.07f * pos / len);
        }
        return hex(md.digest());
    }

    /* ------------------------------------------------------------ writing the game pack */
    private void write(Map<String, byte[]> replaced, Map<String, File> converted, Map<String, byte[]> ours) throws Exception {
        List<Object[]> items = new ArrayList<>();   /* [path, size, source: Entry | byte[] | File] */
        for (Entry e : entries) {
            if (converted.containsKey(e.path)) items.add(new Object[]{e.path, converted.get(e.path).length(), converted.get(e.path)});
            else if (replaced.containsKey(e.path)) items.add(new Object[]{e.path, (long) replaced.get(e.path).length, replaced.get(e.path)});
            else if (!ours.containsKey(e.path)) items.add(new Object[]{e.path, e.size, e});
        }
        for (Map.Entry<String, byte[]> o : ours.entrySet()) items.add(new Object[]{o.getKey(), (long) o.getValue().length, o.getValue()});

        long dirSize = 4;
        for (Object[] it : items) {
            int b = ((String) it[0]).getBytes(StandardCharsets.UTF_8).length;
            dirSize += 4 + b + pad(b, 4) + 8 + 8 + 16 + 4;
        }
        long fileBase = 4 + 4 + 12 + 4 + 8 + 64 + dirSize;
        fileBase += pad(fileBase, 32);
        long[] offsets = new long[items.size()];
        long cur = 0;
        for (int i = 0; i < items.size(); i++) {
            offsets[i] = cur;
            long s = (Long) items.get(i)[1];
            cur += s + pad(s, 32);
        }
        File part = new File(out.getPath() + ".part");
        byte[][] md5s = new byte[items.size()][];
        try (RandomAccessFile raf = new RandomAccessFile(part, "rw")) {
            raf.setLength(0);
            FileChannel oc = raf.getChannel();
            ByteBuffer buf = ByteBuffer.allocate(1 << 20);
            for (int i = 0; i < items.size(); i++) {
                Object[] it = items.get(i);
                long pos = fileBase + offsets[i];
                MessageDigest md = MessageDigest.getInstance("MD5");
                Object s = it[2];
                if (s instanceof byte[]) {
                    byte[] d = (byte[]) s;
                    md.update(d);
                    oc.write(ByteBuffer.wrap(d), pos);
                } else if (s instanceof File) {
                    try (FileChannel fc = new FileInputStream((File) s).getChannel()) {
                        long left = fc.size(), p = 0;
                        while (left > 0) {
                            buf.clear();
                            int n = fc.read(buf, p);
                            buf.flip();
                            md.update(buf.array(), 0, n);
                            oc.write(buf, pos + p);
                            p += n;
                            left -= n;
                        }
                    }
                } else {
                    Entry e = (Entry) s;
                    long left = e.size, p = 0;
                    while (left > 0) {
                        buf.clear();
                        buf.limit((int) Math.min(buf.capacity(), left));
                        int n = src.read(buf, e.offset + p);
                        if (n < 0) throw new Fail("The game file ended early.");
                        buf.flip();
                        md.update(buf.array(), 0, n);
                        oc.write(buf, pos + p);
                        p += n;
                        left -= n;
                    }
                }
                md5s[i] = md.digest();
                if (i % 50 == 0 || i == items.size() - 1)
                    set("Writing the game data", (i + 1) + " of " + items.size() + " files", 0.7f + 0.3f * (i + 1) / items.size());
            }
            /* zero-fill the last file's alignment, then the header and directory at the start */
            long end = fileBase + cur;
            if (oc.size() < end) oc.write(ByteBuffer.allocate((int) (end - oc.size())), oc.size());
            ByteArrayOutputStream h = new ByteArrayOutputStream();
            ByteBuffer hb = ByteBuffer.allocate(4 + 4 + 12 + 4 + 8 + 64 + 4).order(ByteOrder.LITTLE_ENDIAN);
            hb.put("GDPC".getBytes(StandardCharsets.US_ASCII)).putInt(2).putInt(engine[0]).putInt(engine[1]).putInt(engine[2])
                    .putInt(0).putLong(fileBase).put(new byte[64]).putInt(items.size());
            h.write(hb.array());
            for (int i = 0; i < items.size(); i++) {
                byte[] p = ((String) items.get(i)[0]).getBytes(StandardCharsets.UTF_8);
                int pd = pad(p.length, 4);
                ByteBuffer e = ByteBuffer.allocate(4 + p.length + pd + 8 + 8 + 16 + 4).order(ByteOrder.LITTLE_ENDIAN);
                e.putInt(p.length + pd).put(p).put(new byte[pd]).putLong(offsets[i]).putLong((Long) items.get(i)[1]).put(md5s[i]).putInt(0);
                h.write(e.array());
            }
            oc.write(ByteBuffer.wrap(h.toByteArray()), 0);
            oc.force(false);
        }
        if (out.exists() && !out.delete()) throw new Fail("The old game data could not be replaced.");
        if (!part.renameTo(out)) throw new Fail("The game data could not be saved. Is there enough free space?");
    }

    /* ------------------------------------------------------------ helpers */
    private String asset(String name) throws Exception {
        try (InputStream in = ctx.getAssets().open(name)) { return utf8(KitActivity.readAll(in)); }
    }

    private void collectPayload(AssetManager am, String dir, Map<String, byte[]> ours) throws Exception {
        String[] names = am.list(dir);
        if (names == null) return;
        for (String n : names) {
            String p = dir + "/" + n;
            String[] sub = am.list(p);
            if (sub != null && sub.length > 0) collectPayload(am, p, ours);
            else try (InputStream in = am.open(p)) {
                ours.put("res://buckdroid/" + p.substring("payload/buckdroid/".length()), KitActivity.readAll(in));
            }
        }
    }

    private static void applyOverrides(Ecfg pb, JSONObject o) throws Exception {
        for (Iterator<String> it = o.keys(); it.hasNext(); ) {
            String k = it.next();
            pb.set(k, o.get(k));
        }
    }

    static String s3tcTarget(String importText) {
        for (String line : importText.split("\n"))
            if (line.startsWith("path.s3tc=")) return strip(line.substring(line.indexOf('=') + 1).trim());
        return null;
    }

    static String addEtc2Remap(String importText, String target) {
        String t = importText;
        int z = t.indexOf('\0');
        if (z >= 0) t = t.substring(0, z);
        StringBuilder b = new StringBuilder();
        String[] lines = t.split("\n", -1);
        boolean first = true;
        for (String line : lines) {
            if (line.startsWith("path.etc2=")) continue;
            if (!first) b.append('\n');
            b.append(line);
            first = false;
            if (line.startsWith("path.s3tc=")) b.append("\npath.etc2=\"").append(target).append('"');
        }
        return b.toString();
    }

    private static String strip(String s) { return s.startsWith("\"") && s.endsWith("\"") ? s.substring(1, s.length() - 1) : s; }
    private static String utf8(byte[] b) {
        int n = b.length;
        while (n > 0 && b[n - 1] == 0) n--;
        return new String(b, 0, n, StandardCharsets.UTF_8);
    }
    private static int pad(long n, int a) { return (int) ((a - n % a) % a); }
    private static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x & 0xff));
        return s.toString();
    }
    static void deleteTree(File f) {
        File[] k = f.listFiles();
        if (k != null) for (File c : k) deleteTree(c);
        f.delete();
    }

    /* project.binary editor (port of tools/ecfg.py): untouched values keep their raw bytes. */
    static final class Ecfg {
        final List<String[]> items = new ArrayList<>();      /* [key, raw value as ISO-8859-1 string] */

        Ecfg(byte[] d) throws Exception {
            if (d.length < 8 || d[0] != 'E' || d[1] != 'C' || d[2] != 'F' || d[3] != 'G') throw new Fail("The game's settings could not be read.");
            ByteBuffer b = ByteBuffer.wrap(d).order(ByteOrder.LITTLE_ENDIAN);
            b.position(4);
            int n = b.getInt();
            for (int i = 0; i < n; i++) {
                byte[] k = new byte[b.getInt()];
                b.get(k);
                byte[] v = new byte[b.getInt()];
                b.get(v);
                items.add(new String[]{new String(k, StandardCharsets.UTF_8), new String(v, StandardCharsets.ISO_8859_1)});
            }
        }

        static String encode(Object v) {
            ByteBuffer b;
            if (v instanceof Boolean) {
                b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(1).putInt((Boolean) v ? 1 : 0);
            } else if (v instanceof Integer || v instanceof Long) {
                long x = ((Number) v).longValue();
                if (x >= Integer.MIN_VALUE && x <= Integer.MAX_VALUE) b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(2).putInt((int) x);
                else b = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(2 | (1 << 16)).putLong(x);
            } else if (v instanceof Number) {
                double x = ((Number) v).doubleValue();
                if (x == Math.rint(x) && Math.abs(x) < 1e15) return encode((long) x);   /* JSON whole numbers are ints */
                b = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(3 | (1 << 16)).putDouble(x);
            } else {
                byte[] s = String.valueOf(v).getBytes(StandardCharsets.UTF_8);
                int p = pad(s.length, 4);
                b = ByteBuffer.allocate(8 + s.length + p).order(ByteOrder.LITTLE_ENDIAN).putInt(4).putInt(s.length).put(s).put(new byte[p]);
            }
            return new String(b.array(), StandardCharsets.ISO_8859_1);
        }

        void set(String key, Object v) {
            String raw = encode(v);
            for (String[] it : items) if (it[0].equals(key)) { it[1] = raw; return; }
            items.add(new String[]{key, raw});
        }

        void insertBefore(String before, String key, Object v) {
            items.removeIf(it -> it[0].equals(key));
            int idx = items.size();
            for (int i = 0; i < items.size(); i++) if (items.get(i)[0].equals(before)) { idx = i; break; }
            items.add(idx, new String[]{key, encode(v)});
        }

        byte[] toBytes() {
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            ByteBuffer h = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
            h.put(new byte[]{'E', 'C', 'F', 'G'}).putInt(items.size());
            o.write(h.array(), 0, 8);
            for (String[] it : items) {
                byte[] k = it[0].getBytes(StandardCharsets.UTF_8);
                byte[] v = it[1].getBytes(StandardCharsets.ISO_8859_1);
                ByteBuffer l = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                o.write(l.putInt(k.length).array(), 0, 4);
                o.write(k, 0, k.length);
                l = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
                o.write(l.putInt(v.length).array(), 0, 4);
                o.write(v, 0, v.length);
            }
            return o.toByteArray();
        }
    }
}
