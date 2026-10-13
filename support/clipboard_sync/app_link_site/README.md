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

The supplied association covers the existing debug package/signer and the fork's
release package `org.localsend.localsend_app`, using the public certificate from
the permanent fork release key generated on 2026-10-13. This is not the clipboard
certificate fingerprint and does not authorize upstream LocalSend's signer.
Deploy this updated file before testing camera pairing on the first release APK.
The debug association can be removed when developer testing ends. Preserve the
release key for future APK updates; do not replace its fingerprint with a guessed
or temporary signing certificate.

Do not enable analytics, Zaraz or third-party script injection for this site.
Pairing credentials live only in the URL fragment, which the browser does not
send to the server. The fallback script validates bounds/expiry, removes the
fragment from browser history and opens the installed app only on a user tap.
It never sends invitation contents to Cloudflare. Clipboard traffic continues
directly between the paired devices on the LAN. This static site remains useful
for camera-app pairing links and Android domain verification; it is not a
clipboard backend. Canceling the hosted relay does not require removing it.

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
