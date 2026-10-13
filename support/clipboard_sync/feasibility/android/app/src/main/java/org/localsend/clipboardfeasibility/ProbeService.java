package org.localsend.clipboardfeasibility;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;

import java.io.FileDescriptor;
import java.io.PrintWriter;

import rikka.shizuku.Shizuku;

public final class ProbeService extends Service {
    static final String START = "start";
    static final String STOP = "stop";
    static final String READ = "read";
    static final String WRITE = "write";
    private static volatile String summary = "Stopped";
    private static volatile boolean running;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Binder owner = new Binder();
    private IClipboardProbe helper;
    private boolean bound;
    private boolean active;
    private int generation;
    private Shizuku.UserServiceArgs args;

    static String summary() { return summary; }
    static boolean running() { return running; }

    private final Shizuku.OnBinderDeadListener dead = () -> main.post(() -> {
        generation++;
        summary = "Shizuku disconnected. Stop and restart after restoring Shizuku.";
        stopSelf();
    });

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            if (!active || !bound) return;
            helper = IClipboardProbe.Stub.asInterface(binder);
            int current = generation;
            IProbeCallback callback = new IProbeCallback.Stub() {
                @Override public void onSnapshot(Bundle metadata) {
                    main.post(() -> { if (active && generation == current) update(metadata); });
                }
            };
            try {
                int user = android.os.Process.myUid() / 100000;
                update(helper.start(user, owner, callback));
            } catch (RemoteException | RuntimeException exception) { failed("helper-start-failed"); }
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            generation++;
            helper = null;
            summary = "Helper disconnected; stop and restart to recover.";
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        Shizuku.addBinderDeadListener(dead);
        args = new Shizuku.UserServiceArgs(new ComponentName(this, ClipboardUserService.class))
                .tag("clipboard-feasibility").daemon(false).processNameSuffix("clipboard_probe").version(1);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || STOP.equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (!active) {
            foreground();
            active = true;
            running = true;
        }
        switch (intent.getAction() == null ? START : intent.getAction()) {
            case START:
                if (bound) break;
                if (!Shizuku.pingBinder()) { failed("Shizuku unavailable"); break; }
                if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                    failed("Shizuku permission required"); break;
                }
                try {
                    bound = true;
                    Shizuku.bindUserService(args, connection);
                    summary = "Binding shell helper...";
                } catch (RuntimeException exception) { bound = false; failed("bind-failed"); }
                break;
            case READ:
                if (helper == null) { summary = "No helper connected"; break; }
                try { update(helper.readSnapshot()); }
                catch (RemoteException | RuntimeException exception) { failed("read-failed"); }
                break;
            case WRITE:
                // User explicitly schedules this, then backgrounds the Activity before it runs.
                summary = "Test marker write scheduled in 5 seconds. Switch to another app.";
                main.postDelayed(() -> {
                    if (!active) return;
                    try {
                        getSystemService(ClipboardManager.class).setPrimaryClip(
                                ClipData.newPlainText("LocalSend feasibility", ProbeText.FIXTURE));
                        summary = "Ordinary service setPrimaryClip returned. Verify by pasting in another app.";
                    } catch (RuntimeException exception) { summary = "Ordinary service write failed"; }
                }, 5000);
                break;
            default: summary = "Unknown probe action";
        }
        return START_NOT_STICKY;
    }

    private void foreground() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("probe", "Clipboard feasibility", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, ProbeActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, ProbeService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(this, "probe")
                .setSmallIcon(android.R.drawable.ic_menu_info_details).setContentTitle("Clipboard feasibility running")
                .setContentText("Local test only. No text logs or network access.").setContentIntent(open)
                .setOngoing(true).addAction(new Notification.Action.Builder(null, "Stop", stop).build()).build();
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(1, notification);
    }

    private void update(Bundle metadata) {
        summary = "Status: " + metadata.getString("status")
                + "\nSDK: " + metadata.getInt("sdk") + "  helper UID: " + metadata.getInt("helperUid")
                + "  user: " + metadata.getInt("userId")
                + "\nListener registered: " + metadata.getBoolean("listenerRegistered")
                + "\nCallbacks: " + metadata.getLong("callbackCount")
                + "\nUTF-8 bytes: " + metadata.getInt("utf8Bytes")
                + "\nKnown marker matches: " + metadata.getBoolean("fixtureMatches");
    }

    private void failed(String category) { summary = category; stopSelf(); }

    @Override public void onDestroy() {
        active = false;
        running = false;
        generation++;
        main.removeCallbacksAndMessages(null);
        if (helper != null) {
            try { helper.stop(); } catch (RemoteException | RuntimeException ignored) { /* Dead helper. */ }
        }
        if (bound && Shizuku.pingBinder()) {
            try { Shizuku.unbindUserService(args, connection, true); }
            catch (RuntimeException ignored) { /* Shizuku disappeared during teardown. */ }
        }
        Shizuku.removeBinderDeadListener(dead);
        helper = null;
        bound = false;
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override protected void dump(FileDescriptor fd, PrintWriter writer, String[] args) {
        // Read cached metadata without foregrounding the Activity or reading clipboard.
        writer.println("probeRunning=" + active);
        writer.println(summary);
    }
}
