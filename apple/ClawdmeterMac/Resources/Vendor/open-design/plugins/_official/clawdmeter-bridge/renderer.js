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
//
// TODO(t8-integration): Open Design's plugin renderer ABI evolves
// between minor versions. Wire this against the engine API exposed
// by the bundled plugin-runtime package once we pin a contract.

(function() {
  "use strict";

  const channel = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.clawdmeter) || null;
  if (!channel) {
    return; // not inside a Clawdmeter WKWebView host
  }

  function injectButton() {
    // Find the artifact toolbar. Open Design's current DOM convention
    // uses a [data-od-region="artifact-toolbar"] container. Fallback
    // selectors keep us alive across small DOM refactors.
    const toolbar =
      document.querySelector('[data-od-region="artifact-toolbar"]') ||
      document.querySelector('.od-artifact-toolbar') ||
      null;
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
      const projectId = window.__OD_ACTIVE_PROJECT__?.id || null;
      const baseDir = window.__OD_ACTIVE_PROJECT__?.baseDir || null;
      const repoKey = (window.clawdmeter && window.clawdmeter.activeRepo) || baseDir || null;
      channel.postMessage({
        type: 'open-in-code',
        projectId,
        baseDir,
        repoKey,
      });
    });
    toolbar.appendChild(button);
  }

  // Inject on first render + on DOM mutations (Open Design's React UI
  // remounts the toolbar on tab switches).
  const observer = new MutationObserver(() => injectButton());
  observer.observe(document.body, { childList: true, subtree: true });
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    injectButton();
  } else {
    window.addEventListener('DOMContentLoaded', injectButton);
  }
})();
