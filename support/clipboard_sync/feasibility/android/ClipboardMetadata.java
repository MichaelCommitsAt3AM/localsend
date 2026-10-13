package org.localsend.clipboarddiagnostics;

import android.content.ClipData;
import android.net.Uri;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import java.lang.reflect.InvocationTargetException;
import org.localsend.localsend_app.clipboard.ClipboardImageReader;

/** ADB-only metadata probe. Never prints or reads clipboard text/image bytes/URI paths. */
public final class ClipboardMetadata {
    public static void main(String[] args) {
        String stage = "clipboard";
        try {
            IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                    .getDeclaredMethod("getService", String.class).invoke(null, "clipboard");
            Object clipboard = Class.forName("android.content.IClipboard$Stub")
                    .getDeclaredMethod("asInterface", IBinder.class).invoke(null, binder);
            ClipData clip = (ClipData) Class.forName("android.content.IClipboard")
                    .getMethod("getPrimaryClip", String.class, String.class, int.class, int.class)
                    .invoke(clipboard, "com.android.shell", null, 0, 0);
            System.out.println("clipPresent=" + (clip != null));
            if (clip == null) return;
            System.out.println("singleItem=" + (clip.getItemCount() == 1));
            System.out.println("imageMime=" + clip.getDescription().hasMimeType("image/*"));
            System.out.println("sensitive=" + (clip.getDescription().getExtras() != null &&
                    clip.getDescription().getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false)));
            System.out.println("localsendOriginMarker=" + (clip.getDescription().getExtras() != null &&
                    clip.getDescription().getExtras().containsKey("org.localsend.clipboard.REMOTE_ORIGIN")));
            Uri uri = clip.getItemAt(0).getUri();
            System.out.println("uriPresent=" + (uri != null));
            System.out.println("textPresent=" + (clip.getItemAt(0).getText() != null));
            if (uri == null) return;
            System.out.println("uriScheme=" + ("content".equals(uri.getScheme()) ? "content" : "file".equals(uri.getScheme()) ? "file" : "other"));
            stage = "image-descriptor";
            try (ParcelFileDescriptor descriptor = ClipboardImageReader.open(uri, 0)) {
                System.out.println("imageDescriptorOpened=" + (descriptor != null));
                if (descriptor != null) System.out.println("encodedSizeWithinLimit=" + (descriptor.getStatSize() <= 8 * 1024 * 1024));
            }
        } catch (Exception exception) {
            Throwable cause = exception instanceof InvocationTargetException ? exception.getCause() : exception;
            System.out.println("diagnosticError=" + cause.getClass().getSimpleName());
            System.out.println("diagnosticStage=" + stage);
        }
    }
}
