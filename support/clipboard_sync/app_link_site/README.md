# Cloudflare Pages pairing-link site

Deployed 2026-10-13 to `localsend-clipboard-pairing.pages.dev`, with custom
domain `localsend.currenta.tech`. The user added its CNAME. Android on the test
phone reported the domain **verified** against the current debug APK signer.
See `../DEBUG_RESULTS.md` for what has and has not been physically tested.

Upload the **contents of `public/`**, including `.well-known/`, to a new
Cloudflare Pages Direct Upload project. No build command or backend is needed.
Then add `localsend.currenta.tech` through the Pages project's Custom domains
screen; when `currenta.tech` is in the same Cloudflare account, confirm the DNS
record Cloudflare offers. Do not point this hostname at an arbitrary IP or
create a CNAME before associating it with the Pages project.

Required public endpoints:

- `https://localsend.currenta.tech/pair`: static app-opening fallback.
- `https://localsend.currenta.tech/.well-known/assetlinks.json`: HTTP 200,
  `application/json`, without authentication, interstitials or redirects.

The supplied association authorizes **only this debug package and this machine's
actual APK signing certificate**. It was extracted from the installed build using
`apksigner verify --print-certs`. It is not the clipboard certificate fingerprint.
For a production release, replace/extend the association with the fork's real
release application ID and release signing certificate; do not authorize an
upstream package using guessed certificate data. Remove the debug association
from the production hostname after developer testing.

Do not enable analytics, Zaraz or third-party script injection for this site.
Pairing credentials live only in the URL fragment, which the browser does not
send to the server. The fallback script validates bounds/expiry, removes the
fragment from browser history and opens the installed app only on a user tap.
It never sends invitation contents to Cloudflare. Clipboard traffic continues
directly between the paired devices on the LAN.

After deploying, ask Android to reverify and inspect the actual result:

```powershell
adb shell pm verify-app-links --re-verify org.localsend.localsend_app.debug
adb shell pm get-app-links org.localsend.localsend_app.debug
```

Wait for `localsend.currenta.tech: verified`. A manual system override is not
verification evidence. Test a fresh QR using the normal camera app with the
LocalSend app closed, then repeat with it already open. Both cases must reach
the code-comparison screen and still require approval on both devices.

Malformed, expired or foreign-domain links must not create trust. Test the
in-app scanner separately: it handles HTTPS invitations even before deployment.
References: [Cloudflare custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/),
[Android asset links](https://developer.android.com/training/app-links/configure-assetlinks).
