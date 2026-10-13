package org.localsend.localsend_app.clipboard;

import android.content.AttributionSource;
import android.net.Uri;
import android.os.Binder;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import android.os.Process;

/** Shell UserServices are not AMS app processes; use an external provider lease. */
public final class ClipboardImageReader {
    private ClipboardImageReader() {}

    public static ParcelFileDescriptor open(Uri original, int userId) throws Exception {
        if (Process.myUid() != 2000 || !"content".equals(original.getScheme())) {
            throw new SecurityException("Shell image adapter required");
        }
        String authority = original.getAuthority();
        if (authority == null || authority.length() > 255) throw new IllegalArgumentException("Invalid image authority");
        int separator = authority.indexOf('@');
        if (separator >= 0) {
            if (Integer.parseInt(authority.substring(0, separator)) != userId) {
                throw new SecurityException("Cross-profile clipboard images unsupported");
            }
            authority = authority.substring(separator + 1);
        }
        if (!authority.matches("[A-Za-z0-9_.-]+")) throw new IllegalArgumentException("Invalid image authority");
        Uri uri = original.buildUpon().authority(authority).build();
        Object manager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        Class<?> api = Class.forName("android.app.IActivityManager");
        IBinder lease = new Binder();
        Object holder = api.getMethod("getContentProviderExternal", String.class, int.class, IBinder.class, String.class)
                .invoke(manager, authority, userId, lease, "localsend-clipboard");
        if (holder == null) throw new IllegalStateException("Image provider unavailable");
        ParcelFileDescriptor descriptor = null;
        try {
            Object provider = holder.getClass().getField("provider").get(holder);
            AttributionSource caller = new AttributionSource.Builder(Process.myUid()).setPackageName("com.android.shell").build();
            descriptor = (ParcelFileDescriptor) Class.forName("android.content.IContentProvider")
                    .getMethod("openFile", AttributionSource.class, Uri.class, String.class, Class.forName("android.os.ICancellationSignal"))
                    .invoke(provider, caller, uri, "r", null);
            if (descriptor == null) throw new IllegalStateException("Image descriptor unavailable");
            return descriptor;
        } finally {
            try {
                api.getMethod("removeContentProviderExternalAsUser", String.class, IBinder.class, int.class)
                        .invoke(manager, authority, lease, userId);
            } catch (Exception exception) {
                if (descriptor != null) descriptor.close();
                throw exception;
            }
        }
    }
}
