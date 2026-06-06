(function () {
  if (window.__clawdmeterBrowserOverlayInstalled) return;
  window.__clawdmeterBrowserOverlayInstalled = true;

  const storageKey = "__clawdmeterBrowserAnnotations:v2:" + location.href.split("#")[0];
  const markers = new Map();
  const multiSelection = [];
  let hoverTarget = null;
  let hoverFrame = 0;
  let dragStart = null;
  let dragBox = null;
  let markerFrame = 0;

  const style = document.createElement("style");
  style.textContent = `
    .clawdmeter-browser-hover {
      outline: 2px solid rgba(25, 113, 194, 0.85) !important;
      outline-offset: 2px !important;
    }
    .clawdmeter-browser-marker {
      position: fixed !important;
      z-index: 2147483646 !important;
      border: 2px solid rgba(25, 113, 194, 0.95) !important;
      background: rgba(25, 113, 194, 0.07) !important;
      pointer-events: none !important;
      box-sizing: border-box !important;
      border-radius: 4px !important;
    }
    .clawdmeter-browser-marker-actions {
      position: absolute !important;
      top: -23px !important;
      left: -2px !important;
      display: flex !important;
      gap: 3px !important;
      pointer-events: auto !important;
      font: 11px -apple-system, BlinkMacSystemFont, sans-serif !important;
    }
    .clawdmeter-browser-marker-actions button {
      border: 0 !important;
      border-radius: 4px !important;
      padding: 2px 5px !important;
      color: white !important;
      background: rgba(20, 80, 145, 0.96) !important;
      cursor: pointer !important;
    }
    .clawdmeter-browser-drag {
      position: fixed !important;
      z-index: 2147483647 !important;
      border: 1.5px dashed rgba(25, 113, 194, 0.95) !important;
      background: rgba(25, 113, 194, 0.11) !important;
      pointer-events: none !important;
    }
  `;
  (document.head || document.documentElement).appendChild(style);

  function clean(text, limit) {
    return String(text || "").trim().replace(/\s+/g, " ").slice(0, limit);
  }

  function escapeIdent(value) {
    if (window.CSS && CSS.escape) return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function composedParent(node) {
    if (!node) return null;
    if (node.parentElement) return node.parentElement;
    const root = node.getRootNode && node.getRootNode();
    return root && root.host ? root.host : null;
  }

  function simpleSelector(node) {
    let sel = node.nodeName.toLowerCase();
    if (node.id) return { selector: "#" + escapeIdent(node.id), stable: true };
    const stableAttr = ["data-testid", "data-test", "aria-label"].find((name) => node.getAttribute(name));
    const stable = stableAttr && node.getAttribute(stableAttr);
    if (stableAttr && stable) {
      return {
        selector: sel + "[" + stableAttr + "='" + String(stable).replace(/'/g, "\\'") + "']",
        stable: true
      };
    }
    const classes = Array.from(node.classList || [])
      .filter((name) => !name.startsWith("clawdmeter-browser-"))
      .slice(0, 3)
      .map(escapeIdent);
    if (classes.length) return { selector: sel + "." + classes.join("."), stable: false };
    const parent = node.parentElement;
    const siblings = parent ? Array.from(parent.children).filter((c) => c.nodeName === node.nodeName) : [node];
    if (siblings.length > 1) sel += ":nth-of-type(" + (siblings.indexOf(node) + 1) + ")";
    return { selector: sel, stable: false };
  }

  function localPath(node) {
    const path = [];
    let current = node;
    while (current && current.nodeType === 1 && path.length < 8) {
      const simple = simpleSelector(current);
      path.unshift(simple.selector);
      if (simple.stable || !current.parentElement) break;
      current = current.parentElement;
    }
    return { selector: path.join(" > "), top: current };
  }

  function cssPath(el) {
    if (!(el instanceof Element)) return "";
    const chunks = [];
    let node = el;
    while (node && node.nodeType === 1 && chunks.length < 4) {
      const part = localPath(node);
      if (part.selector) chunks.unshift(part.selector);
      const root = part.top && part.top.getRootNode && part.top.getRootNode();
      node = root && root.host ? root.host : null;
    }
    return chunks.join(" >>> ");
  }

  function elementForSelector(selector) {
    try {
      if (!selector) return null;
      const parts = String(selector).split(/\s*>>>\s*/).filter(Boolean);
      let root = document;
      let current = null;
      for (let index = 0; index < parts.length; index += 1) {
        if (!root || !root.querySelector) return null;
        current = root.querySelector(parts[index]);
        if (!(current instanceof Element)) return null;
        root = current.shadowRoot;
        if (index < parts.length - 1 && !root) return null;
      }
      return current;
    } catch (_) {
      return null;
    }
  }

  function sourceHint(el) {
    let node = el;
    let depth = 0;
    while (node && depth < 6) {
      const value =
        node.getAttribute("data-source") ||
        node.getAttribute("data-file") ||
        node.getAttribute("data-component") ||
        node.getAttribute("data-testid") ||
        node.getAttribute("data-test");
      if (value) return clean(value, 300);
      node = composedParent(node);
      depth += 1;
    }
    return el && el.id ? "#" + clean(el.id, 120) : "";
  }

  function computedStyleSummary(el, rect) {
    if (!(el instanceof Element) || !window.getComputedStyle) return {};
    const s = window.getComputedStyle(el);
    return {
      display: s.display,
      position: s.position,
      overflow: s.overflow,
      color: s.color,
      backgroundColor: s.backgroundColor,
      fontSize: s.fontSize,
      fontWeight: s.fontWeight,
      zIndex: s.zIndex,
      opacity: s.opacity,
      size: Math.round(rect.width) + "x" + Math.round(rect.height)
    };
  }

  function loadMarkers() {
    try {
      JSON.parse(sessionStorage.getItem(storageKey) || "[]").forEach((marker) => {
        if (marker && marker.id && marker.selector) markers.set(marker.id, marker);
      });
    } catch (_) {}
  }

  function persistMarkers() {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(Array.from(markers.values()).slice(-40)));
    } catch (_) {}
  }

  function markerFor(target) {
    const selector = cssPath(target);
    const existing = Array.from(markers.values()).find((marker) => marker.selector === selector);
    if (existing) return existing.id;
    const id = "ann-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
    markers.set(id, { id, selector, createdAt: Date.now() });
    persistMarkers();
    scheduleMarkers();
    return id;
  }

  function payloadFor(target, extra) {
    if (!(target instanceof Element)) return null;
    const rect = target.getBoundingClientRect ? target.getBoundingClientRect() : { x: 0, y: 0, width: 0, height: 0 };
    const selection = clean(window.getSelection ? window.getSelection() : "", 1000);
    return Object.assign({
      eventType: "annotate",
      annotationId: markerFor(target),
      selector: cssPath(target),
      snippet: clean(target.textContent || target.getAttribute("alt") || target.getAttribute("title"), 240),
      selectedText: selection,
      nearbyText: clean(composedParent(target) && composedParent(target).textContent, 1200),
      accessibilityLabel: clean(target.getAttribute("aria-label") || target.getAttribute("alt") || target.getAttribute("title"), 240),
      sourceHint: sourceHint(target),
      computedStyleSummary: computedStyleSummary(target, rect),
      cssClasses: Array.from(target.classList || []).filter((name) => !name.startsWith("clawdmeter-browser-")).slice(0, 12),
      boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
    }, extra || {});
  }

  function post(payload) {
    if (!payload || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.clawdmeterComment) return;
    window.webkit.messageHandlers.clawdmeterComment.postMessage(payload);
  }

  function renderMarkers() {
    markerFrame = 0;
    document.querySelectorAll(".clawdmeter-browser-marker").forEach((node) => node.remove());
    markers.forEach((marker) => {
      const target = elementForSelector(marker.selector);
      if (!(target instanceof Element)) return;
      const rect = target.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      const overlay = document.createElement("div");
      overlay.className = "clawdmeter-browser-marker";
      overlay.style.left = rect.x + "px";
      overlay.style.top = rect.y + "px";
      overlay.style.width = rect.width + "px";
      overlay.style.height = rect.height + "px";
      overlay.dataset.annotationId = marker.id;
      const actions = document.createElement("div");
      actions.className = "clawdmeter-browser-marker-actions";
      const editButton = document.createElement("button");
      editButton.dataset.clawdmeterAction = "edit";
      editButton.dataset.id = marker.id;
      editButton.textContent = "Edit";
      const deleteButton = document.createElement("button");
      deleteButton.dataset.clawdmeterAction = "delete";
      deleteButton.dataset.id = marker.id;
      deleteButton.textContent = "Delete";
      actions.appendChild(editButton);
      actions.appendChild(deleteButton);
      overlay.appendChild(actions);
      document.documentElement.appendChild(overlay);
    });
  }

  function scheduleMarkers() {
    if (markerFrame) return;
    markerFrame = window.requestAnimationFrame(renderMarkers);
  }

  function selectionTargetsInRect(rect) {
    const candidates = Array.from(document.body.querySelectorAll("button,a,input,textarea,select,[role],h1,h2,h3,p,img,section,article,main,[data-testid],[data-source]"));
    return candidates.filter((el) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && r.left < rect.right && r.right > rect.left && r.top < rect.bottom && r.bottom > rect.top;
    }).slice(0, 12);
  }

  function rectFromPoints(a, b) {
    const left = Math.min(a.x, b.x);
    const top = Math.min(a.y, b.y);
    const right = Math.max(a.x, b.x);
    const bottom = Math.max(a.y, b.y);
    return { left, top, right, bottom, width: right - left, height: bottom - top };
  }

  document.addEventListener("mousemove", function (event) {
    if (dragStart && dragBox) {
      const rect = rectFromPoints(dragStart, { x: event.clientX, y: event.clientY });
      dragBox.style.left = rect.left + "px";
      dragBox.style.top = rect.top + "px";
      dragBox.style.width = rect.width + "px";
      dragBox.style.height = rect.height + "px";
      return;
    }
    if (hoverFrame) return;
    hoverFrame = window.requestAnimationFrame(function () {
      hoverFrame = 0;
      if (hoverTarget && hoverTarget !== event.target) hoverTarget.classList.remove("clawdmeter-browser-hover");
      hoverTarget = event.target instanceof Element ? event.target : null;
      if (hoverTarget) hoverTarget.classList.add("clawdmeter-browser-hover");
    });
  }, true);

  document.addEventListener("mousedown", function (event) {
    if (!event.shiftKey || event.metaKey || event.ctrlKey || event.button !== 0) return;
    dragStart = { x: event.clientX, y: event.clientY };
    dragBox = document.createElement("div");
    dragBox.className = "clawdmeter-browser-drag";
    document.documentElement.appendChild(dragBox);
    event.preventDefault();
    event.stopPropagation();
  }, true);

  document.addEventListener("mouseup", function (event) {
    if (dragStart && dragBox) {
      const rect = rectFromPoints(dragStart, { x: event.clientX, y: event.clientY });
      dragBox.remove();
      dragBox = null;
      dragStart = null;
      if (rect.width > 12 && rect.height > 12) {
        const targets = selectionTargetsInRect(rect);
        const primary = targets[0];
        if (primary) {
          const selectors = targets.map(cssPath).filter(Boolean);
          const snippets = targets.map((el) => clean(el.textContent || el.getAttribute("aria-label") || el.getAttribute("alt"), 80)).filter(Boolean);
          post(payloadFor(primary, {
            eventType: "areaSelect",
            annotationId: markerFor(primary),
            selector: selectors.join(", "),
            snippet: snippets.join(" | ").slice(0, 240),
            areaSelection: targets.length + " elements in " + Math.round(rect.width) + "x" + Math.round(rect.height) + " area",
            boundingBox: { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
          }));
        }
      }
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    const selection = clean(window.getSelection ? window.getSelection() : "", 1000);
    if (!selection) return;
    const range = window.getSelection().rangeCount ? window.getSelection().getRangeAt(0) : null;
    const node = range && range.commonAncestorContainer;
    const target = node && (node.nodeType === 1 ? node : node.parentElement);
    if (target instanceof Element) post(payloadFor(target, { eventType: "textSelection" }));
  }, true);

  document.addEventListener("click", function (event) {
    const action = event.target && event.target.closest && event.target.closest("[data-clawdmeter-action]");
    if (action) {
      const id = action.getAttribute("data-id");
      const marker = markers.get(id);
      const target = marker && elementForSelector(marker.selector);
      if (action.getAttribute("data-clawdmeter-action") === "delete") {
        markers.delete(id);
        persistMarkers();
        scheduleMarkers();
        post({ eventType: "markerDeleted", annotationId: id });
      } else if (target) {
        post(payloadFor(target, { eventType: "markerEdit", annotationId: id }));
      }
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    if (!(event.metaKey || event.ctrlKey)) return;
    if (!(event.target instanceof Element)) return;
    event.preventDefault();
    event.stopPropagation();

    if (event.shiftKey) {
      const selector = cssPath(event.target);
      if (!multiSelection.includes(selector)) multiSelection.push(selector);
      while (multiSelection.length > 8) multiSelection.shift();
      const id = markerFor(event.target);
      post(payloadFor(event.target, {
        eventType: "multiSelect",
        annotationId: id,
        selector: multiSelection.join(", "),
        areaSelection: multiSelection.length + " selected elements"
      }));
      return;
    }

    post(payloadFor(event.target, { eventType: "click" }));
  }, true);

  window.__clawdmeterBrowserOverlayTest = {
    storageKey: function () { return storageKey; },
    markerCount: function () { return markers.size; },
    renderedMarkerCount: function () { return document.querySelectorAll(".clawdmeter-browser-marker").length; },
    forceRender: renderMarkers,
    selectorFor: cssPath,
    canResolveSelector: function (selector) { return !!elementForSelector(selector); }
  };

  loadMarkers();
  scheduleMarkers();
  window.addEventListener("scroll", scheduleMarkers, true);
  window.addEventListener("resize", scheduleMarkers);
})();
