// clawdmeter-bridge — Open Design UI plugin (renderer-side).
//
// Renders an "Open in Code →" button in the artifact toolbar that
// hands control back to the Clawdmeter host (Mac or iOS) via the
// window.webkit.messageHandlers.clawdmeter bridge that
// MacDesignView / IOSDesignView injects via WKUserScript.
//
// On Open Design daemons that are NOT inside a WKWebView (e.g.,
// regular browser, dev tools), the bridge channel is absent and the
// button is hidden — no-op.

(function () {
  "use strict";

  const channel = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.clawdmeter) || null;
  if (!channel) {
    return; // not inside a Clawdmeter WKWebView host
  }

  // Audit P1 fix: native side issues a per-session nonce by setting
  // `window.__CLAWDMETER_HANDOFF_NONCE__` from the WKUserScript that
  // injects this plugin. We forward it on every postMessage so the
  // native receiver can verify the call really originated from this
  // renderer context — preventing other plugins / injected scripts in
  // the same WebView from spoofing "Open in Code" with arbitrary paths.
  function currentNonce() {
    return (typeof window.__CLAWDMETER_HANDOFF_NONCE__ === "string"
      && window.__CLAWDMETER_HANDOFF_NONCE__.length > 0)
      ? window.__CLAWDMETER_HANDOFF_NONCE__
      : null;
  }

  // Audit P1 fix: validate projectId shape before forwarding. Open
  // Design project ids are UUID-like; reject anything else so a
  // compromised window global can't push opaque payloads through.
  function safeProjectId(raw) {
    if (typeof raw !== "string") return null;
    if (raw.length === 0 || raw.length > 64) return null;
    // Accept UUIDs and slug-ish ids.
    if (!/^[A-Za-z0-9_-]+$/.test(raw)) return null;
    return raw;
  }

  let toolbarMissingLogged = false;
  function findToolbar() {
    const toolbar =
      document.querySelector('[data-od-region="artifact-toolbar"]') ||
      document.querySelector('.od-artifact-toolbar') ||
      null;
    if (!toolbar && !toolbarMissingLogged) {
      // Audit P2 fix: surface a one-time warning if the selector goes
      // dark — future Open Design redesigns will silently break the
      // integration otherwise.
      toolbarMissingLogged = true;
      // eslint-disable-next-line no-console
      console.warn("[clawdmeter] artifact-toolbar selector not found; Open in Code button will not appear");
      try {
        channel.postMessage({
          type: "plugin-error",
          code: "toolbar-not-found",
          nonce: currentNonce(),
        });
      } catch { /* renderer may not have postMessage if channel disappeared */ }
    }
    return toolbar;
  }

  function injectButton() {
    const toolbar = findToolbar();
    if (!toolbar || toolbar.querySelector('[data-clawdmeter-button="open-in-code"]')) return;

    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.clawdmeterButton = 'open-in-code';
    button.textContent = 'Open in Code →';
    Object.assign(button.style, {
      marginLeft: '8px',
      padding: '4px 10px',
      borderRadius: '999px',
      border: '0.5px solid rgba(0,0,0,0.08)',
      background: 'oklch(0.74 0.18 320 / 0.18)', // Tahoe bloom accent at low alpha
      color: 'oklch(0.40 0.18 320)',
      font: '500 12px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui',
      cursor: 'pointer',
    });
    button.addEventListener('click', () => {
      const projectId = safeProjectId(window.__OD_ACTIVE_PROJECT__?.id);
      const baseDir = (typeof window.__OD_ACTIVE_PROJECT__?.baseDir === 'string')
        ? window.__OD_ACTIVE_PROJECT__.baseDir
        : null;
      const repoKey = (window.clawdmeter && typeof window.clawdmeter.activeRepo === 'string')
        ? window.clawdmeter.activeRepo
        : (baseDir || null);
      channel.postMessage({
        type: 'open-in-code',
        projectId,
        baseDir,
        repoKey,
        nonce: currentNonce(),
      });
    });
    toolbar.appendChild(button);
  }

  // Inject on first render + on DOM mutations (Open Design's React UI
  // remounts the toolbar on tab switches).
  //
  // Audit P2 fix: keep a handle on the observer so we can disconnect
  // on plugin teardown; otherwise repeated plugin reloads stack
  // observers and re-run injectButton() on every DOM mutation.
  const observer = new MutationObserver(() => injectButton());
  observer.observe(document.body, { childList: true, subtree: true });
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    injectButton();
  } else {
    window.addEventListener('DOMContentLoaded', injectButton);
  }

  // Expose teardown for Open Design plugin lifecycle hooks (or for
  // hot-reload during development).
  window.__clawdmeterPluginTeardown = function teardown() {
    try { observer.disconnect(); } catch { /* noop */ }
    const existing = document.querySelector('[data-clawdmeter-button="open-in-code"]');
    if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
  };
})();
