package org.localsend.clipboardfeasibility;
import android.os.Bundle;
import org.localsend.clipboardfeasibility.IProbeCallback;
interface IClipboardProbe {
    Bundle start(int userId, IBinder owner, IProbeCallback callback) = 0;
    Bundle readSnapshot() = 1;
    void stop() = 2;
    void destroy() = 16777114;
}
