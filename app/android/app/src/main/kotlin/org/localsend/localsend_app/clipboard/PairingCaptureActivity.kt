package org.localsend.localsend_app.clipboard

import com.journeyapps.barcodescanner.CaptureActivity

/** Portrait is set in our manifest instead of inheriting ZXing's landscape default. */
class PairingCaptureActivity : CaptureActivity()
