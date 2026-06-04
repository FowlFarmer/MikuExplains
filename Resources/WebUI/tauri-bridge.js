// Tauri bridge for Miku Explains.
//
// The React UI (app.js) was written for the Swift/WKWebView host: it posts
// events through `window.webkit.messageHandlers.mikuPanel.postMessage(...)` and
// receives state via `window.MikuPanel.setState(...)`. This shim re-points both
// channels at Tauri so app.js needs no changes:
//   - outbound: webkit.postMessage  ->  invoke("panel_event", { payload })
//   - inbound:  event "miku://state" ->  window.MikuPanel.setState(payload)
//
// Must load BEFORE app.js so the webkit shim exists when app.js first calls it.
(function () {
  var tauri = window.__TAURI__;
  if (!tauri) {
    console.warn("[miku] __TAURI__ not present; running outside Tauri shell.");
    return;
  }

  var invoke = tauri.core.invoke;
  var listen = tauri.event.listen;

  // Outbound: shim the webkit message handler app.js expects.
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.mikuPanel = {
    postMessage: function (message) {
      invoke("panel_event", { payload: message }).catch(function (err) {
        console.error("[miku] panel_event failed:", err);
      });
    }
  };

  // Inbound: forward host state pushes to the React state setter. Buffer until
  // window.MikuPanel exists (app.js defines it on load).
  var buffered = [];
  function deliver(state) {
    if (window.MikuPanel && typeof window.MikuPanel.setState === "function") {
      window.MikuPanel.setState(state);
    } else {
      buffered.push(state);
    }
  }

  listen("miku://state", function (event) {
    deliver(event.payload);
  });

  // Flush any states that arrived before MikuPanel was ready.
  var flushTimer = setInterval(function () {
    if (window.MikuPanel && typeof window.MikuPanel.setState === "function") {
      clearInterval(flushTimer);
      while (buffered.length) {
        window.MikuPanel.setState(buffered.shift());
      }
    }
  }, 16);
})();
