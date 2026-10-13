package org.localsend.clipboardfeasibility;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import rikka.shizuku.Shizuku;

public final class ProbeActivity extends Activity {
    private TextView status;
    private final Shizuku.OnRequestPermissionResultListener permission = (code, grant) -> runOnUiThread(this::refresh);
    private final Shizuku.OnBinderReceivedListener received = () -> runOnUiThread(this::refresh);

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(24, 24, 24, 24);
        TextView instructions = new TextView(this);
        instructions.setText("Developer feasibility test; no sync or networking. Only metadata is displayed.\n"
                + "After starting, switch to another app and copy this exact marker:\n\n" + ProbeText.FIXTURE
                + "\n\nReturn and refresh status. Use manual snapshot only as a separate read test.");
        layout.addView(instructions);
        button(layout, "Authorize Shizuku", () -> {
            if (!Shizuku.pingBinder()) { status.setText("Start Shizuku first."); return; }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) { refresh(); return; }
            if (Shizuku.shouldShowRequestPermissionRationale()) { status.setText("Restore permission in Shizuku settings."); return; }
            Shizuku.requestPermission(1);
        });
        button(layout, "Start listener", () -> {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 2);
                status.setText("Grant notification permission, then press Start listener again.");
                return;
            }
            startForegroundService(new Intent(this, ProbeService.class).setAction(ProbeService.START));
            status.setText("Starting. Switch apps, copy the marker, then refresh.");
        });
        button(layout, "Refresh metadata (no clipboard read)", this::refresh);
        button(layout, "Manual snapshot (separate read test)", () -> action(ProbeService.READ));
        button(layout, "Write marker in 5 seconds", () -> action(ProbeService.WRITE));
        button(layout, "Stop and remove helper", () -> {
            stopService(new Intent(this, ProbeService.class));
            status.setText("Stop requested.");
        });
        status = new TextView(this);
        status.setText("Stopped");
        layout.addView(status);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        setContentView(scroll);
        Shizuku.addRequestPermissionResultListener(permission);
        Shizuku.addBinderReceivedListenerSticky(received);
    }

    private void button(LinearLayout layout, String text, Runnable action) {
        Button button = new Button(this);
        button.setText(text);
        button.setOnClickListener(view -> {
            try { action.run(); }
            catch (RuntimeException exception) { status.setText("Action failed; check permissions and service status."); }
        });
        layout.addView(button);
    }

    private void action(String action) {
        if (!ProbeService.running()) { status.setText("Start the probe first."); return; }
        startService(new Intent(this, ProbeService.class).setAction(action));
        status.setText("Action submitted. Refresh metadata after the test.");
    }

    private void refresh() { status.setText(ProbeService.summary()); }

    @Override public void onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permission);
        Shizuku.removeBinderReceivedListener(received);
        super.onDestroy();
    }
}
