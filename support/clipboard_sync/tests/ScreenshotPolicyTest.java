import org.localsend.localsend_app.clipboard.ScreenshotPolicy;

/** Standalone pure-policy tests; no gallery access or image bytes. */
public final class ScreenshotPolicyTest {
    private static final long START = 1760000000500L;
    private static final long NOW = START + 2000;
    private static boolean check(String path, String name, String mime, long added, long taken, long size, boolean pending) {
        return ScreenshotPolicy.eligible(path, name, mime, added, taken, START, NOW, size, pending);
    }
    private static void expect(boolean value, String failure) { if (!value) throw new AssertionError(failure); }
    public static void main(String[] args) {
        long added = NOW / 1000, taken = NOW - 500;
        expect(check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, taken, 1024, false), "Samsung screenshot rejected");
        expect(check("Pictures/Screenshots/", "Screenshot_2.png", "image/png", added, taken, 1024, false), "Pixel screenshot rejected");
        expect(!check("Download/", "Screenshot_1.png", "image/png", added, taken, 1024, false), "Downloaded image shared");
        expect(!check("DCIM/Camera/", "IMG_1.jpg", "image/jpeg", added, taken, 1024, false), "Camera photo shared");
        expect(!check("DCIM/Screenshots/", "IMG_1.jpg", "image/jpeg", added, taken, 1024, false), "Unrelated screenshot-album image shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, START - 60000, 1024, false), "Imported old screenshot shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, taken, 1024, true), "Pending file shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, taken, 0, false), "Unfinished file shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, taken, 8388609, false), "Oversized file shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "application/pdf", added, taken, 1024, false), "Unsupported MIME shared");
        expect(!check("DCIM/Screenshots/", "Screenshot_1.png", "image/png", Long.MAX_VALUE, taken, 1024, false), "Overflow accepted");
        expect(!ScreenshotPolicy.eligible("DCIM/Screenshots/", "Screenshot_1.png", "image/png", added, taken, START, NOW + 61000, 1024, false), "Stale screenshot shared");
        System.out.println("12 screenshot policy checks passed");
    }
}
