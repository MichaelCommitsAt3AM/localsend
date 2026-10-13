package org.localsend.localsend_app.clipboard;

import android.content.ClipData;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/** Isolated shell clipboard adapter. No networking, keys, storage, overlays, or polling. */
public final class ClipboardUserService extends IClipboardProbe.Stub {
    private static final String PACKAGE = "com.android.shell";
    private static final String LISTENER_DESCRIPTOR = "android.content.IOnPrimaryClipChangedListener";
    private Object clipboard;
    private Object listener;
    private Method read;
    private Method remove;
    private IProbeCallback callback;
    private IBinder owner;
    private boolean ownerLinked;
    private int ownerUid = -1;
    private int userId;
    private HandlerThread thread;
    private Handler handler;
    private boolean monitoring;
    private boolean syncImages;
    private long events;
    private final IBinder.DeathRecipient ownerDeath = () -> {
        synchronized (this) { cleanup(); }
        System.exit(0);
    };

    public ClipboardUserService() {}

    private void enforceOwner() {
        if (ownerUid != -1 && Binder.getCallingUid() != ownerUid) {
            throw new SecurityException("different probe owner");
        }
    }

    @Override public synchronized Bundle start(int requestedUser, IBinder token, IProbeCallback sink, boolean images) {
        enforceOwner();
        cleanup();
        ownerUid = Binder.getCallingUid();
        if (Process.myUid() != 2000) return status("shell-mode-required");
        if (Build.VERSION.SDK_INT < 33 || Build.VERSION.SDK_INT > 36) return status("unsupported-android-version");
        if (token == null || sink == null || requestedUser != ownerUid / 100000) return status("invalid-owner");
        try {
            int activeUser = (Integer) Class.forName("android.app.ActivityManager")
                    .getDeclaredMethod("getCurrentUser").invoke(null);
            if (activeUser != requestedUser) return status("inactive-user-unsupported");
            userId = requestedUser;
            IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                    .getDeclaredMethod("getService", String.class).invoke(null, "clipboard");
            if (binder == null) return status("clipboard-service-unavailable");
            Class<?> api = Class.forName("android.content.IClipboard");
            clipboard = Class.forName("android.content.IClipboard$Stub")
                    .getDeclaredMethod("asInterface", IBinder.class).invoke(null, binder);
            Class<?> listenerApi = Class.forName(LISTENER_DESCRIPTOR);
            thread = new HandlerThread("clipboard-probe");
            thread.start();
            handler = new Handler(thread.getLooper());
            Binder listenerBinder = new Binder() {
                @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                        throws RemoteException {
                    if (code == INTERFACE_TRANSACTION) {
                        if (reply != null) reply.writeString(LISTENER_DESCRIPTOR);
                        return true;
                    }
                    if (code == FIRST_CALL_TRANSACTION) {
                        data.enforceInterface(LISTENER_DESCRIPTOR);
                        synchronized (ClipboardUserService.this) {
                            if (monitoring && handler != null) {
                                events++;
                                // Coalesce callbacks on the worker; never poll for clipboard changes.
                                handler.removeCallbacks(capture);
                                handler.post(capture);
                            }
                        }
                        return true;
                    }
                    return super.onTransact(code, data, reply, flags);
                }
            };
            listener = Proxy.newProxyInstance(listenerApi.getClassLoader(), new Class<?>[]{listenerApi},
                    (proxy, method, args) -> {
                        if (method.getName().equals("asBinder")) return listenerBinder;
                        if (method.getName().equals("toString")) return "ClipboardProbeListener";
                        if (method.getName().equals("hashCode")) return System.identityHashCode(proxy);
                        if (method.getName().equals("equals")) return proxy == args[0];
                        throw new UnsupportedOperationException("unexpected listener method");
                    });
            Method add;
            if (Build.VERSION.SDK_INT == 33) {
                read = api.getMethod("getPrimaryClip", String.class, int.class);
                add = api.getMethod("addPrimaryClipChangedListener", listenerApi, String.class, int.class);
                remove = api.getMethod("removePrimaryClipChangedListener", listenerApi, String.class, int.class);
            } else {
                read = api.getMethod("getPrimaryClip", String.class, String.class, int.class, int.class);
                add = api.getMethod("addPrimaryClipChangedListener", listenerApi, String.class, String.class, int.class, int.class);
                remove = api.getMethod("removePrimaryClipChangedListener", listenerApi, String.class, String.class, int.class, int.class);
            }
            owner = token;
            callback = sink;
            syncImages = images;
            owner.linkToDeath(ownerDeath, 0);
            ownerLinked = true;
            monitoring = true;
            add.invoke(clipboard, listenerArguments());
            return status("listener-registered");
        } catch (Exception exception) {
            String category = category(exception);
            cleanup();
            return status(category);
        }
    }

    private Object[] listenerArguments() {
        // Android 14+ attribution=null, current user resolved above, physical default device=0.
        return Build.VERSION.SDK_INT == 33
                ? new Object[]{listener, PACKAGE, userId}
                : new Object[]{listener, PACKAGE, null, userId, 0};
    }

    private final Runnable capture = () -> {
        synchronized (this) {
            if (!monitoring || callback == null) return;
            try {
                Bundle metadata = readInternal();
                String imageUri = metadata.getString("imageUri");
                metadata.remove("imageUri");
                if (imageUri != null) {
                    try {
                        // Clipboard grants temporary URI access; attribution uses actual shell UID.
                        try (ParcelFileDescriptor descriptor = ClipboardImageReader.open(Uri.parse(imageUri), userId)) {
                            if (descriptor == null) throw new IllegalStateException("missing image descriptor");
                            callback.onImage(descriptor, metadata);
                        }
                    } catch (Exception exception) { callback.onSnapshot(status("image-unavailable")); }
                } else callback.onSnapshot(metadata);
            }
            catch (RemoteException exception) { cleanup(); }
        }
    };

    @Override public synchronized Bundle readSnapshot() {
        enforceOwner();
        return readInternal();
    }

    private Bundle readInternal() {
        if (!monitoring || read == null) return status("not-monitoring");
        try {
            Object[] args = Build.VERSION.SDK_INT == 33
                    ? new Object[]{PACKAGE, userId} : new Object[]{PACKAGE, null, userId, 0};
            ClipData clip = (ClipData) read.invoke(clipboard, args);
            // Null can mean empty, locked, or denied: do not falsely report successful access.
            if (clip == null) return status("empty-or-unavailable");
            if (clip.getItemCount() != 1) return status("multi-item-unsupported");
            boolean sensitive = clip.getDescription().getExtras() != null
                    && clip.getDescription().getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false);
            if (sensitive) {
                Bundle metadata = status("sensitive-suppressed");
                String token = clip.getDescription().getExtras().getString("org.localsend.clipboard.REMOTE_ORIGIN");
                if (token != null && token.length() <= 64) metadata.putString("remoteToken", token);
                return metadata;
            }
            CharSequence value = clip.getItemAt(0).getText();
            Uri uri = clip.getItemAt(0).getUri();
            if (syncImages && uri != null && "content".equals(uri.getScheme())
                    && clip.getDescription().hasMimeType("image/*")) {
                Bundle metadata = status("image-readable");
                metadata.putString("imageUri", uri.toString());
                return metadata;
            }
            if (value == null || value.length() == 0) return status("non-text-or-empty");
            if (value.length() > 65536) return status("oversize");
            String text = value.toString();
            if (text.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 65536) return status("oversize");
            Bundle metadata = status("text-readable");
            metadata.putString("text", text);
            return metadata;
        } catch (Exception exception) {
            return status(category(exception));
        }
    }

    private Bundle status(String value) {
        Bundle result = new Bundle();
        result.putString("status", value);
        result.putInt("helperUid", Process.myUid());
        result.putInt("sdk", Build.VERSION.SDK_INT);
        result.putInt("userId", userId);
        result.putBoolean("listenerRegistered", monitoring);
        result.putLong("callbackCount", events);
        return result;
    }

    private static String category(Exception exception) {
        Throwable cause = exception instanceof InvocationTargetException ? exception.getCause() : exception;
        if (cause instanceof SecurityException) return "permission-denied";
        if (cause instanceof ReflectiveOperationException) return "unsupported-signature";
        if (cause instanceof RemoteException) return "binder-unavailable";
        return "helper-error";
    }

    @Override public synchronized void stop() { enforceOwner(); cleanup(); }

    private void cleanup() {
        monitoring = false;
        if (clipboard != null && listener != null && remove != null) {
            try { remove.invoke(clipboard, listenerArguments()); }
            catch (Exception ignored) { /* Teardown continues after dead/incompatible Binder. */ }
        }
        if (owner != null && ownerLinked) {
            try { owner.unlinkToDeath(ownerDeath, 0); }
            catch (java.util.NoSuchElementException ignored) { /* Already removed on Binder death. */ }
        }
        ownerLinked = false;
        if (handler != null) handler.removeCallbacksAndMessages(null);
        if (thread != null) thread.quitSafely();
        clipboard = listener = null;
        read = remove = null;
        owner = null;
        callback = null;
        handler = null;
        thread = null;
    }

    @Override public synchronized void destroy() {
        // Shizuku itself invokes this reserved transaction when removing a UserService.
        cleanup();
        System.exit(0);
    }
}
