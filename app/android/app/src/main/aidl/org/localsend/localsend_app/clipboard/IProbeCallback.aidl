package org.localsend.localsend_app.clipboard;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
oneway interface IProbeCallback {
    void onSnapshot(in Bundle metadata);
    void onImage(in ParcelFileDescriptor descriptor, in Bundle metadata);
}
