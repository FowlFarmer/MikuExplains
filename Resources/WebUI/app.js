(function () {
  const h = React.createElement;

  const EMPTY_ITEM = {
    type: "note",
    title: "Ready",
    body: "Highlight text anywhere, then press the shortcut.",
    confidence: null
  };

  const initialState = {
    view: "message",
    title: "Miku Explains",
    status: "ready",
    subtitle: "",
    loadingPhase: "local",
    loadingCompleteToken: 0,
    debug: "",
    debugVisible: false,
    shortcutLabel: "⌃⇧M",
    shortcutError: "",
    items: [EMPTY_ITEM],
    summaries: [],
    selectedModel: "codex",
    installedModels: [],
    ollamaAvailable: true,
    modelPull: null
  };
  let updateState = null;
  let pendingState = null;

  window.MikuPanel = {
    setState(nextState) {
      if (updateState) {
        updateState((previous) => Object.assign({}, previous, nextState || {}));
      } else {
        pendingState = Object.assign({}, pendingState || initialState, nextState || {});
      }
    }
  };

  // ---------------------------------------------------------------------------
  // Preset model catalogue
  // ---------------------------------------------------------------------------
  const PRESET_MODELS = [
    { id: "codex",        label: "Codex CLI",   tag: null,            size: null,     speed: null },
    { id: "qwen2.5:3b",   label: "Qwen 2.5 3B", tag: "qwen2.5:3b",   size: "2 GB",   speed: "~90 t/s" },
    { id: "qwen3:4b",     label: "Qwen 3 4B",   tag: "qwen3:4b",     size: "2.5 GB", speed: "~75 t/s" },
    { id: "llama3.2:3b",  label: "Llama 3.2 3B",tag: "llama3.2:3b",  size: "2 GB",   speed: "~90 t/s" },
    { id: "gemma3:4b",    label: "Gemma 3 4B",  tag: "gemma3:4b",    size: "3 GB",   speed: "~65 t/s" },
    { id: "mistral:7b",   label: "Mistral 7B",  tag: "mistral:7b",   size: "4.5 GB", speed: "~50 t/s" },
  ];

  function modelShortLabel(modelId) {
    const found = PRESET_MODELS.find((m) => m.id === modelId);
    if (found) return found.label;
    // For unknown installed models, truncate tag
    return modelId.length > 14 ? modelId.slice(0, 12) + "…" : modelId;
  }

  function ModelPill({ state }) {
    const [open, setOpen] = React.useState(false);
    const btnRef = React.useRef(null);
    const [dropRect, setDropRect] = React.useState(null);

    React.useEffect(() => {
      if (!open) return;
      function onOutside(e) {
        if (!e.target.closest(".model-dropdown") && !e.target.closest(".model-pill")) {
          setOpen(false);
        }
      }
      document.addEventListener("mousedown", onOutside);
      return () => document.removeEventListener("mousedown", onOutside);
    }, [open]);

    function handleToggle() {
      if (!open && btnRef.current) {
        setDropRect(btnRef.current.getBoundingClientRect());
      }
      setOpen((o) => !o);
    }

    const pull = state.modelPull;
    const installed = new Set(state.installedModels || []);

    // Normalise Ollama tag names — Ollama appends ":latest" to bare names.
    function isInstalled(tag) {
      if (!tag) return false;
      if (installed.has(tag)) return true;
      const withLatest = tag.includes(":") ? tag : tag + ":latest";
      return installed.has(withLatest);
    }

    function handleSelectOrPull(preset) {
      if (preset.id === "codex") {
        send("setModel", { model: "codex" });
        setOpen(false);
        return;
      }
      if (isInstalled(preset.tag)) {
        send("setModel", { model: preset.id });
        setOpen(false);
      } else {
        send("pullModel", { model: preset.id });
        // keep open so user can see progress
      }
    }

    const rows = PRESET_MODELS.map((preset) => {
      const isSelected = state.selectedModel === preset.id;
      const isPulling = pull && !pull.done && pull.model === preset.id;
      const isInstd = preset.tag === null || isInstalled(preset.tag);
      const pullFailed = pull && pull.done && pull.error && pull.model === preset.id;

      return h(
        "button",
        {
          key: preset.id,
          type: "button",
          className: `model-row${isSelected ? " is-selected" : ""}${isPulling ? " is-pulling" : ""}`,
          onClick: () => handleSelectOrPull(preset),
          disabled: isPulling
        },
        h(
          "span",
          { className: "model-row-label" },
          isSelected ? h("span", { className: "model-check" }, "✓ ") : null,
          preset.label
        ),
        isPulling
          ? h(
              "span",
              { className: "model-row-right" },
              h("span", { className: "model-pull-pct" }, pull.statusText || `${Math.round((pull.progress || 0) * 100)}%`),
              h("div", { className: "model-pull-bar" },
                h("div", { className: "model-pull-fill", style: { width: `${(pull.progress || 0) * 100}%` } })
              )
            )
          : pullFailed
          ? h("span", { className: "model-row-error" }, "failed")
          : isInstd
          ? h("span", { className: "model-row-speed" }, preset.speed || "")
          : h(
              "span",
              { className: "model-row-dl" },
              `↓ ${preset.size || ""}`
            )
      );
    });

    // Portal: render the dropdown directly on document.body so it escapes
    // every stacking context (transforms, filters on shell/sticker/cards).
    const dropdown = open && dropRect
      ? ReactDOM.createPortal(
          h(
            "div",
            {
              className: "model-dropdown",
              style: {
                position: "fixed",
                top: dropRect.bottom + 5,
                right: window.innerWidth - dropRect.right,
                zIndex: 99999
              }
            },
            state.ollamaAvailable === false
              ? h("div", { className: "model-no-ollama" }, "Install Ollama to use local models")
              : null,
            rows
          ),
          document.body
        )
      : null;

    return h(
      "div",
      { className: "model-pill-wrap" },
      h(
        "button",
        {
          ref: btnRef,
          type: "button",
          className: `model-pill${open ? " is-open" : ""}`,
          title: "Change model",
          onClick: handleToggle
        },
        h("span", null, "model:"),
        h("strong", null, modelShortLabel(state.selectedModel || "codex"))
      ),
      dropdown
    );
  }

  function send(type, payload) {    const handler = window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.mikuPanel;

    if (handler) {
      handler.postMessage(Object.assign({ type }, payload || {}));
    }
  }

  function cleanType(type) {
    return String(type || "note")
      .toLowerCase()
      .replace(/[^a-z0-9_-]+/g, "_")
      .replace(/^_+|_+$/g, "") || "note";
  }

  function labelForView(state) {
    if (state.subtitle) return state.subtitle;
    if (state.view === "loading") {
      return state.loadingPhase === "web" ? "checking the outside world" : "reading what you selected";
    }
    if (state.view === "history") return "previous explanations";
    if (state.view === "result") return "what Miku thinks you wanted";
    if (state.view === "shortcut") return "press a new shortcut";
    return "highlight to ask";
  }

  function statusForState(state) {
    if (state.status) return state.status;
    if (state.view === "history") return `${(state.summaries || []).length} saved`;
    if (state.view === "loading") return state.loadingPhase === "web" ? "web" : "thinking";
    return "";
  }

  function AppFrame({ state, wiggleToken, children }) {
    const showBack = state.view !== "history";
    const status = statusForState(state);
    const showStatus = false && status;

    return h(
      "main",
      { className: "stage" },
      h("img", {
        key: wiggleToken,
        className: `sticker${wiggleToken > 0 ? " sticker-wiggle" : ""}`,
        src: "./miku.png",
        alt: ""
      }),
      h(
        "section",
        { className: "shell" },
        h(
          "header",
          { className: "masthead" },
          h(
            "div",
            { className: "toolbar" },
            h("div", { className: "toolbar-fill" }),
            h(ModelPill, { state }),
            h(
              "button",
              {
                type: "button",
                className: `shortcut-pill${state.view === "shortcut" ? " is-recording" : ""}`,
                title: "Change shortcut",
                onClick: () => send("openShortcutSettings")
              },
              h("span", null, "shortcut:"),
              h("strong", null, state.shortcutLabel || "⌃⇧M")
            ),
            h("button", {
              type: "button",
              className: `toggle${state.debugVisible ? " is-on" : ""}`,
              title: "Toggle debug",
              onClick: () => send("toggleDebug")
            }),
            h(
              "button",
              {
                type: "button",
                className: "close",
                title: "Close",
                onClick: () => send("close")
              },
              "×"
            )
          ),
          h("div", { className: "brandline" }, "Miku Explains"),
          h("h1", { className: "headline", title: state.title }, state.title || "Miku Explains"),
          h("p", { className: "subline" }, labelForView(state))
        ),
        h("div", { className: "body" }, children),
        showBack
          ? h(
              "div",
              { className: "bottom-back-bar" },
              h(
                "button",
                {
                  type: "button",
                  className: "ghost-button back",
                  onClick: () => send("back")
                },
                "←",
                h("span", null, "History")
              )
            )
          : null,
        state.debugVisible ? h(DebugDrawer, { text: state.debug }) : null
      )
    );
  }

  function ResultCard({ item }) {
    const type = cleanType(item.type);
    return h(
      "article",
      { className: `answer-card type-${type}` },
      h("div", { className: "answer-chrome" }),
      h(
        "div",
        { className: "answer-content" },
        h("h2", null, item.title || "Note"),
        h("p", null, item.body || ""),
        item.confidence
          ? h("div", { className: "confidence" }, `confidence ${item.confidence}`)
          : null
      )
    );
  }

  function ResultsPage({ state }) {
    const items = state.items && state.items.length ? state.items : [EMPTY_ITEM];
    return h(
      "div",
      { className: "scroll result-scroll" },
      h(
        "div",
        { className: "answer-stack" },
        items.map((item, index) => h(ResultCard, { key: `${cleanType(item.type)}-${index}`, item }))
      )
    );
  }

  function HistoryPage({ state }) {
    const summaries = state.summaries || [];

    return h(
      "div",
      { className: "scroll history-scroll" },
      summaries.length
        ? h(
            "div",
            { className: "history-stack" },
            summaries.map((summary) =>
              h(
                "button",
                {
                  key: summary.id,
                  type: "button",
                  className: "history-item",
                  onClick: () => send("selectHistory", { id: summary.id })
                },
                h("span", { className: "history-date" }, summary.displayTimestamp || ""),
                h("span", { className: "history-title" }, summary.tagline || "Untitled")
              )
            )
          )
        : h("div", { className: "empty-state" }, "No saved explanations yet.")
    );
  }

  function ShortcutPage({ state }) {
    React.useEffect(() => {
      if (state.view !== "shortcut") return undefined;

      const modifierCodes = new Set([
        "MetaLeft",
        "MetaRight",
        "ShiftLeft",
        "ShiftRight",
        "AltLeft",
        "AltRight",
        "ControlLeft",
        "ControlRight",
        "Fn"
      ]);

      function onKeyDown(event) {
        if (event.repeat || modifierCodes.has(event.code)) return;
        event.preventDefault();
        event.stopPropagation();
        send("recordShortcut", {
          code: event.code,
          controlKey: event.ctrlKey,
          altKey: event.altKey,
          shiftKey: event.shiftKey,
          metaKey: event.metaKey
        });
      }

      window.addEventListener("keydown", onKeyDown, true);
      return () => window.removeEventListener("keydown", onKeyDown, true);
    }, [state.view]);

    return h(
      "div",
      { className: "shortcut-page" },
      h("div", { className: "shortcut-current" }, state.shortcutLabel || "⌃⇧M"),
      h("div", { className: "shortcut-target" }, "listening"),
      state.shortcutError ? h("div", { className: "shortcut-error" }, state.shortcutError) : null
    );
  }

  function LoadingPage({ state }) {
    const phase = state.loadingPhase === "web" ? "web" : "local";
    const [progress, setProgress] = React.useState(0);

    React.useEffect(() => {
      setProgress(0);
      const start = performance.now();
      let frame = 0;

      function tick(now) {
        const elapsed = now - start;
        const divisor = phase === "web" ? 2450 : 3200;
        setProgress(Math.min(0.96, 1 - Math.exp(-elapsed / divisor)));
        frame = requestAnimationFrame(tick);
      }

      frame = requestAnimationFrame(tick);
      return () => cancelAnimationFrame(frame);
    }, [phase, state.title]);

    React.useEffect(() => {
      if (!state.loadingCompleteToken) return;
      const startValue = progress;
      const start = performance.now();
      let frame = 0;

      function tick(now) {
        const ratio = Math.min(1, (now - start) / 260);
        const eased = 1 - Math.pow(1 - ratio, 3);
        setProgress(startValue + (1 - startValue) * eased);
        if (ratio < 1) frame = requestAnimationFrame(tick);
      }

      frame = requestAnimationFrame(tick);
      return () => cancelAnimationFrame(frame);
    }, [state.loadingCompleteToken]);

    const percent = Math.round(progress * 100);
    const caption = phase === "web" ? "searching web" : "reading";

    return h(
      "div",
      { className: `loading-page phase-${phase}` },
      h(
        "div",
        { className: "meter", style: { "--angle": `${progress * 360}deg` } },
        h("div", { className: "meter-inner" }, `${percent}%`)
      ),
      h("div", { className: "meter-caption" }, caption)
    );
  }

  function DebugDrawer({ text }) {
    return h("pre", { className: "debug" }, text || "debug enabled");
  }

  function CurrentPage({ state }) {
    if (state.view === "loading") return h(LoadingPage, { state });
    if (state.view === "history") return h(HistoryPage, { state });
    if (state.view === "shortcut") return h(ShortcutPage, { state });
    return h(ResultsPage, { state });
  }

  function App() {
    const [state, setState] = React.useState(pendingState || initialState);
    const [wiggleToken, setWiggleToken] = React.useState(0);
    const lastWiggleTrigger = React.useRef("");

    React.useEffect(() => {
      updateState = setState;
      if (pendingState) {
        setState(pendingState);
        pendingState = null;
      }
      send("ready");

      return () => {
        updateState = null;
      };
    }, []);

    React.useEffect(() => {
      let trigger = "";

      if (state.loadingCompleteToken) {
        trigger = `complete:${state.loadingCompleteToken}`;
      }

      if (state.view === "history") {
        trigger = `history:${(state.summaries || []).map((summary) => summary.id).join("|")}`;
      }

      if (state.view === "result") {
        trigger = `result:${state.title}:${(state.items || [])
          .map((item) => `${item.type}:${item.title}:${item.body}`)
          .join("|")}`;
      }

      if (!trigger || trigger === lastWiggleTrigger.current) {
        return;
      }

      lastWiggleTrigger.current = trigger;
      setWiggleToken((value) => value + 1);
    }, [state.view, state.title, state.loadingCompleteToken, state.items, state.summaries]);

    return h(AppFrame, { state, wiggleToken }, h(CurrentPage, { state }));
  }

  const root = document.getElementById("root");
  if (ReactDOM.createRoot) {
    ReactDOM.createRoot(root).render(h(App));
  } else {
    ReactDOM.render(h(App), root);
  }
})();
