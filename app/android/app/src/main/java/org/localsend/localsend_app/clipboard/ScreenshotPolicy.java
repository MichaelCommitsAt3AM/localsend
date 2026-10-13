package org.localsend.localsend_app.clipboard;

import java.util.Locale;

/** Conservative classification: only fresh, finished files in screenshot albums. */
public final class ScreenshotPolicy {
    private ScreenshotPolicy() {}
    public static boolean eligible(String path, String name, String mime, long addedSeconds,
            long takenMillis, long startedMillis, long nowMillis, long size, boolean pending) {
        if (path == null || name == null || mime == null || pending || size <= 0 || size > 8L * 1024 * 1024
                || addedSeconds <= 0 || addedSeconds > Long.MAX_VALUE / 1000) return false;
        String album = path.toLowerCase(Locale.ROOT);
        if (!album.equals("pictures/screenshots/") && !album.equals("dcim/screenshots/")) return false;
        String filename = name.toLowerCase(Locale.ROOT);
        if (!filename.startsWith("screenshot") && !filename.startsWith("screen_capture") && !filename.startsWith("screencapture")) return false;
        if (!mime.equals("image/png") && !mime.equals("image/jpeg") && !mime.equals("image/webp")) return false;
        long saved = addedSeconds * 1000;
        long captured = takenMillis > 0 ? takenMillis : saved + 999;
        return saved >= startedMillis - 1000 && (takenMillis > 0 ? captured >= startedMillis : saved >= startedMillis)
                && captured <= nowMillis + 1000 && nowMillis - captured <= 60000;
    }
}
