package org.localsend.localsend_app.clipboard;
import android.os.Bundle;
import org.localsend.localsend_app.clipboard.IProbeCallback;
interface IClipboardProbe {
    Bundle start(int userId, IBinder owner, IProbeCallback callback, boolean syncImages) = 0;
    Bundle readSnapshot() = 1;
    void stop() = 2;
    void destroy() = 16777114;
}
