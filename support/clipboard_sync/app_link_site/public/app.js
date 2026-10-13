"use strict";
(() => {
  const fragment = location.hash.slice(1);
  const status = document.getElementById("status");
  const open = document.getElementById("open");
  // Keep a live invitation out of browser history after reading it. No fetch,
  // analytics, storage or network calls carry this fragment or its contents.
  history.replaceState(null, "", location.pathname);
  try {
    if (!fragment || fragment.length > 5500 || !/^[A-Za-z0-9_-]+$/.test(fragment)) throw new Error();
    const padded = fragment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(fragment.length / 4) * 4, "=");
    const bytes = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
    if (bytes.length > 4096) throw new Error();
    const invite = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (invite.version !== 2 || invite.kind !== "localsend-clipboard-pair" ||
        !/^[A-F0-9]{64}$/.test(invite.fingerprint) || !/^[A-Fa-f0-9]{64}$/.test(invite.token) ||
        !Number.isInteger(invite.expires) || !Number.isInteger(invite.port) || invite.port < 1 || invite.port > 65535 ||
        !Array.isArray(invite.addresses) || !invite.addresses.length || invite.addresses.length > 16) throw new Error();
    const remaining = invite.expires * 1000 - Date.now();
    if (remaining <= 0) {
      status.textContent = "This invitation expired. Create a new QR code in LocalSend and scan it again.";
      return;
    }
    if (remaining > 300000) throw new Error();
    open.href = "localsend-clipboard://pair#" + fragment;
    open.hidden = false;
    setTimeout(() => {
      open.hidden = true;
      open.removeAttribute("href");
      status.textContent = "This invitation expired. Create a new QR code in LocalSend and scan it again.";
    }, remaining);
  } catch (_) {
    status.textContent = "This pairing link is invalid. Create a new QR code in LocalSend and scan it again.";
  }
})();
