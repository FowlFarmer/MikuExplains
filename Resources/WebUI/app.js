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
    toolMessage: "",
    items: [EMPTY_ITEM],
    summaries: [],
    selectedModel: "codex",
    installedModels: [],
    modelCatalog: [],
    localBackendAvailable: true,
    geminiAPIKeyConfigured: null,
    geminiKeyWarning: false,
    modelPull: null,
    isFocused: false
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
    { id: "qwen3.5:2b",   label: "Qwen 3.5 2B", tag: "qwen3.5:2b",   size: "1.28 GB", speed: null },
    { id: "qwen3:4b",     label: "Qwen 3 4B",   tag: "qwen3:4b",     size: "2.5 GB", speed: "~75 t/s" },
    { id: "phi3:mini",    label: "Phi-3 Mini",  tag: "phi3:mini",    size: "2.3 GB", speed: "~75 t/s" },
    { id: "mistral:7b",   label: "Mistral 7B",  tag: "mistral:7b",   size: "4.5 GB", speed: "~50 t/s" },
  ];

  const HOSTED_GEMINI_API_MODELS = [
    { id: "google:gemma-4-26b-a4b-it", label: "Gemma 4 MoE", tag: null, provider: "google", size: null, speed: "api" },
    { id: "google:gemini-3.1-flash-lite", label: "Gemini 3.1 Flash Lite", tag: null, provider: "google", size: null, speed: "api" },
  ];

  function modelShortLabel(modelId, state) {
    const catalog = currentModelCatalog(state || initialState);
    const found = catalog.find((m) => m.id === modelId);
    if (found) return found.label;
    // For unknown installed models, truncate tag
    return modelId.length > 14 ? modelId.slice(0, 12) + "…" : modelId;
  }

  function currentModelCatalog(state) {
    const localCatalog = Array.isArray(state.modelCatalog) && state.modelCatalog.length
      ? state.modelCatalog
      : PRESET_MODELS.filter((model) => model.id !== "codex");
    return [PRESET_MODELS[0]].concat(localCatalog, HOSTED_GEMINI_API_MODELS);
  }

  function modelPullLabel(pull) {
    const percent = `${Math.round(Math.max(0, Math.min(1, pull.progress || 0)) * 100)}%`;
    const status = String(pull.statusText || "").trim();
    if (!status) return percent;
    if (status.length > 18 || /^downloading\s+/i.test(status)) return percent;
    return status;
  }

  function ModelPill({ state }) {
    const [open, setOpen] = React.useState(false);
    const [apiKeyDraft, setApiKeyDraft] = React.useState("");
    const apiInputRef = React.useRef(null);
    const btnRef = React.useRef(null);
    const [dropRect, setDropRect] = React.useState(null);
    const openedAtRef = React.useRef(0);
    const ignoreOutsideUntilRef = React.useRef(0);

    const geminiConfigured = state.geminiAPIKeyConfigured === true;
    const geminiKeyMissing = state.geminiAPIKeyConfigured === false;
    const geminiKeyLocked = state.geminiAPIKeyConfigured == null;

    React.useEffect(() => {
      if (!open) return;
      function onOutside(e) {
        if (Date.now() < ignoreOutsideUntilRef.current) return;
        if (!e.target.closest(".model-dropdown") && !e.target.closest(".model-pill-wrap")) {
          setOpen(false);
        }
      }
      document.addEventListener("mousedown", onOutside);
      return () => document.removeEventListener("mousedown", onOutside);
    }, [open]);

    React.useEffect(() => {
      if (state.geminiKeyWarning) {
        sendDebug("ModelPill: closing dropdown because geminiKeyWarning=true");
        setOpen(false);
      }
    }, [state.geminiKeyWarning]);

    function openDropdown() {
      if (btnRef.current) {
        setDropRect(btnRef.current.getBoundingClientRect());
      }
      const now = Date.now();
      openedAtRef.current = now;
      ignoreOutsideUntilRef.current = now + 400;
      setOpen(true);
    }

    function handleToggle() {
      if (open) {
        // Fast double-click after focus (first click opens, second closes) — ignore.
        if (Date.now() - openedAtRef.current < 400) return;
        setOpen(false);
        return;
      }
      openDropdown();
    }

    const pull = state.modelPull;
    const modelCatalog = currentModelCatalog(state);
    const installed = new Set(state.installedModels || []);

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
      if (preset.provider === "google") {
        sendDebug(`ModelPill: Gemma row selected id=${preset.id} geminiAPIKeyConfigured=${state.geminiAPIKeyConfigured}`);
        send("setModel", { model: preset.id });
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

    const rows = modelCatalog.map((preset) => {
      const isSelected = state.selectedModel === preset.id;
      const isPulling = pull && !pull.done && pull.model === preset.id;
      const isHosted = preset.provider === "google";
      const isLocal = !isHosted && preset.id !== "codex" && preset.tag;
      const isLocalInstalled = isLocal && isInstalled(preset.tag);
      const isInstd = preset.tag === null || isInstalled(preset.tag) || isHosted;
      const pullFailed = pull && pull.done && pull.error && pull.model === preset.id;

      let rightSlot = null;
      if (isPulling) {
        rightSlot = h(
          "span",
          { className: "model-row-right", title: pull.statusText || "" },
          h("span", { className: "model-pull-pct" }, modelPullLabel(pull)),
          h("div", { className: "model-pull-bar" },
            h("div", { className: "model-pull-fill", style: { width: `${(pull.progress || 0) * 100}%` } })
          )
        );
      } else if (pullFailed) {
        rightSlot = h("span", { className: "model-row-error" }, "failed");
      } else if (isHosted && geminiKeyLocked) {
        rightSlot = h("span", { className: "model-row-speed" }, "keychain");
      } else if (isHosted && geminiKeyMissing) {
        rightSlot = h("span", { className: "model-row-error" }, "needs key");
      } else if (isLocalInstalled) {
        rightSlot = h(
          "button",
          {
            type: "button",
            className: "model-row-delete",
            title: `Delete ${preset.label}`,
            onClick: (event) => {
              event.preventDefault();
              event.stopPropagation();
              send("deleteModel", { model: preset.id });
            }
          },
          "delete"
        );
      } else if (isInstd) {
        rightSlot = h("span", { className: "model-row-speed" }, preset.speed || "");
      } else {
        rightSlot = h(
          "span",
          { className: "model-row-dl" },
          `↓ ${preset.size || ""}`
        );
      }

      return h(
        "div",
        {
          key: preset.id,
          className: `model-row${isSelected ? " is-selected" : ""}${isPulling ? " is-pulling" : ""}`,
          role: "button",
          tabIndex: isPulling ? -1 : 0,
          onClick: (event) => {
            if (isPulling) return;
            if (event.target.closest(".model-row-delete")) return;
            handleSelectOrPull(preset);
          },
          onKeyDown: (event) => {
            if (isPulling) return;
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              handleSelectOrPull(preset);
            }
          }
        },
        h(
          "span",
          { className: "model-row-label" },
          isSelected ? h("span", { className: "model-check" }, "✓ ") : null,
          preset.label
        ),
        rightSlot
      );
    });
    const showGeminiKeyForm = String(state.selectedModel || "").startsWith("google:");
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
            state.localBackendAvailable === false
              ? h("div", { className: "model-no-local" }, "Local backend not ready — llama-server will download on first model pull")
              : null,
            rows,
            showGeminiKeyForm ? h(
              "form",
              {
                className: "gemini-key-form",
                onSubmit: (event) => {
                  event.preventDefault();
                  const apiKey = (apiInputRef.current?.value || apiKeyDraft || "").trim();
                  if (!apiKey) return;
                  send("setGeminiAPIKey", { apiKey });
                  setApiKeyDraft("");
                  if (apiInputRef.current) {
                    apiInputRef.current.value = "";
                  }
                }
              },
              h("div", { className: "gemini-key-label" },
                geminiConfigured
                  ? "Gemini key saved"
                  : geminiKeyLocked
                  ? "Gemini key in Keychain"
                  : "Gemini key required"
              ),
              h("div", { className: "gemini-key-row" },
                h("input", {
                  className: "gemini-key-input",
                  type: "password",
                  ref: apiInputRef,
                  autoComplete: "off",
                  spellCheck: false,
                  value: apiKeyDraft,
                  placeholder: geminiConfigured ? "Replace key" : "Paste API key",
                  onChange: (event) => setApiKeyDraft(event.target.value),
                  onInput: (event) => setApiKeyDraft(event.target.value),
                  onKeyDown: (event) => {
                    if ((event.metaKey || event.ctrlKey) && String(event.key || "").toLowerCase() === "v") {
                      event.preventDefault();
                      send("pasteGeminiAPIKey");
                      setApiKeyDraft("");
                    }
                  }
                }),
                h("button", { className: "gemini-key-button", type: "submit" }, "save"),
                h("button", {
                  className: "gemini-key-button",
                  type: "button",
                  onClick: () => {
                    send("pasteGeminiAPIKey");
                    setApiKeyDraft("");
                  }
                }, "paste"),
                geminiConfigured
                  ? h("button", {
                      className: "gemini-key-button is-clear",
                      type: "button",
                      onClick: () => {
                        send("setGeminiAPIKey", { apiKey: "" });
                        setApiKeyDraft("");
                      }
                    }, "clear")
                  : null
              )
            ) : null
          ),
          document.body
        )
      : null;

    return h(
      "div",
      {
        className: "model-pill-wrap",
        onClick: handleToggle
      },
      h(
        "button",
        {
          ref: btnRef,
          type: "button",
          className: `model-pill${open ? " is-open" : ""}`,
          title: "Change model"
        },
        h("span", null, "model:"),
        h("strong", null, modelShortLabel(state.selectedModel || "codex", state))
      ),
      dropdown
    );
  }

  function ApolloKeyWarning({ onDismiss }) {
    React.useEffect(() => {
      sendDebug("ApolloKeyWarning: overlay mounted in body portal");
      return () => sendDebug("ApolloKeyWarning: overlay unmounted");
    }, []);

    return h(
      "div",
      { className: "apollo-key-warning", role: "status" },
      h("div", { className: "apollo-key-warning-note" },
        h("span", { className: "apollo-key-warning-head" }, "heads up!"),
        h("p", null, "This key is saved to your macOS Keychain."),
        h("p", null, "When the system asks, press ", h("strong", null, "Always Allow"), " so Miku can read it later without re-asking you.")
      ),
        h("button", {
        type: "button",
        className: "apollo-key-warning-dismiss",
        onClick: () => {
          sendDebug("ApolloKeyWarning: got it clicked");
          onDismiss();
        }
      }, "got it")
    );
  }

  function send(type, payload) {
    const handler = window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.mikuPanel;

    if (handler) {
      handler.postMessage(Object.assign({ type }, payload || {}));
    }
  }

  function sendDebug(message) {
    send("logDebug", { message: String(message || "") });
  }

  function cleanType(type) {
    return String(type || "note")
      .toLowerCase()
      .replace(/[^a-z0-9_-]+/g, "_")
      .replace(/^_+|_+$/g, "") || "note";
  }

  function cardHeaderSignature(items) {
    return (items || [])
      .map((item, index) => `${index}:${cleanType(item.type)}:${String(item.title || "").trim()}`)
      .join("|");
  }

  function labelForView(state) {
    if (state.subtitle) return state.subtitle;
    if (state.view === "loading") {
      if (state.loadingPhase === "web") return "checking the outside world";
      if (state.loadingPhase === "hosted") return "waiting on the hosted model";
      return "reading what you selected";
    }
    if (state.view === "history") return "previous explanations";
    if (state.view === "result") return "what Miku thinks you wanted";
    if (state.view === "shortcut") return "press a new shortcut";
    return "highlight to ask";
  }

  function statusForState(state) {
    if (state.status) return state.status;
    if (state.view === "history") return `${(state.summaries || []).length} saved`;
    if (state.view === "loading") {
      if (state.loadingPhase === "web") return "web";
      if (state.loadingPhase === "hosted") return "hosted";
      return "thinking";
    }
    return "";
  }

  function AppFrame({ state, wiggleToken, children }) {
    const showBack = state.view !== "history";
    const status = statusForState(state);
    const showStatus = false && status;
    const [sleepFrame, setSleepFrame] = React.useState(0);
    const prevGeminiWarningRef = React.useRef(state.geminiKeyWarning);

    React.useEffect(() => {
      if (prevGeminiWarningRef.current !== state.geminiKeyWarning) {
        sendDebug(
          `AppFrame: geminiKeyWarning ${prevGeminiWarningRef.current} -> ${state.geminiKeyWarning} view=${state.view} selectedModel=${state.selectedModel}`
        );
        prevGeminiWarningRef.current = state.geminiKeyWarning;
      }
    }, [state.geminiKeyWarning, state.view, state.selectedModel]);

    React.useEffect(() => {
      if (state.isFocused) {
        setSleepFrame(0);
        return undefined;
      }

      let timeoutID = null;
      let isActive = true;

      function showFrame(frame) {
        if (!isActive) return;
        setSleepFrame(frame);
        timeoutID = window.setTimeout(
          () => showFrame(frame === 0 ? 1 : 0),
          frame === 0 ? 2500 : 1000
        );
      }

      showFrame(0);
      return () => {
        isActive = false;
        if (timeoutID !== null) window.clearTimeout(timeoutID);
      };
    }, [state.isFocused]);

    const stickerMode = state.isFocused ? "awake" : "sleep";
    const stickerSrc = state.isFocused
      ? "./miku.png"
      : `./miku_sleep${sleepFrame + 1}.png`;
    const stickerSize = state.isFocused
      ? { width: 474, height: 441 }
      : sleepFrame === 0
      ? { width: 287, height: 248 }
      : { width: 289, height: 257 };

    const showGeminiKeychainNotice = state.geminiKeyWarning;
    const geminiKeyWarningOverlay = showGeminiKeychainNotice
      ? ReactDOM.createPortal(
          h(
            "div",
            {
              className: "apollo-key-warning-overlay apollo-key-warning-overlay-portal",
              style: { zIndex: 100000 }
            },
            h(ApolloKeyWarning, {
              onDismiss: () => send("dismissGeminiKeyWarning")
            })
          ),
          document.body
        )
      : null;

    return h(
      "main",
      { className: `stage ${state.isFocused ? "is-focused" : "is-unfocused"}` },
      h("img", {
        key: `${stickerMode}:${wiggleToken}`,
        className: `sticker sticker-${stickerMode}${
          state.isFocused ? "" : ` sticker-sleep-${sleepFrame + 1}`
        }${wiggleToken > 0 ? " sticker-wiggle" : ""}`,
        src: stickerSrc,
        width: stickerSize.width,
        height: stickerSize.height,
        decoding: "async",
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
              className: `debug-pill${state.debugVisible ? " is-on" : ""}`,
              title: "Toggle debug",
              onClick: () => send("toggleDebug")
            }, "debug"),
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
        geminiKeyWarningOverlay,
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
        state.debugVisible ? h(DebugDrawer, { text: state.debug }) : null,
        state.toolMessage ? h("div", { className: "tool-toast" }, state.toolMessage) : null
      )
    );
  }

  function ResultCard({ item }) {
    const type = cleanType(item.type);
    const [sent, setSent] = React.useState(false);
    const tool = item.tool || null;
    const toolLabel = tool && (tool.label || defaultToolLabel(tool.name));

    function handleToolClick() {
      if (!tool) return;
      setSent(true);
      send("executeTool", { tool });
    }

    return h(
      "article",
      { className: `answer-card type-${type}` },
      h("div", { className: "answer-paper" }),
      h("div", { className: "answer-outline" }),
      h("div", { className: "answer-tape" }),
      h("div", { className: "answer-chrome" }),
      h(
        "div",
        { className: "answer-content" },
        h("h2", null, item.title || "Note"),
        h("p", null, item.body || ""),
        item.confidence
          ? h("div", { className: "confidence" }, `confidence ${item.confidence}`)
          : null,
        tool
          ? h(
              "button",
              {
                type: "button",
                className: `tool-action${sent ? " is-sent" : ""}`,
                onClick: handleToolClick,
                disabled: sent,
                title: toolLabel
              },
              sent ? "sent" : toolLabel
            )
          : null
      )
    );
  }

  function defaultToolLabel(name) {
    if (name === "calendar.create_event") return "Add to Calendar";
    if (name === "reminders.create_reminder") return "Add Reminder";
    return "Accept";
  }

  function ResultsPage({ state }) {
    const items = state.items || [];
    const isThinking = state.loadingPhase === "thinking" || state.status === "thinking";

    return h(
      "div",
      { className: "scroll result-scroll" },
      items.length
        ? h(
            "div",
            { className: "answer-stack" },
            items.map((item, index) => h(ResultCard, { key: `${cleanType(item.type)}-${index}`, item }))
          )
        : h(InferenceStatus, { mode: isThinking ? "thinking" : "parsing" })
    );
  }

  function InferenceStatus({ mode }) {
    const [dotIndex, setDotIndex] = React.useState(0);

    React.useEffect(() => {
      const interval = window.setInterval(() => {
        setDotIndex((value) => (value + 1) % 3);
      }, 430);
      return () => window.clearInterval(interval);
    }, []);

    const label = "Thinking";
    const dots = [".", "..", "..."][dotIndex];

    return h(
      "div",
      { className: `inference-status is-${mode || "thinking"}` },
      h("span", { className: "inference-status-label" }, label),
      h("span", { className: "inference-dots", "aria-hidden": "true" }, dots)
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
    const [fakeThinking, setFakeThinking] = React.useState(false);

    React.useEffect(() => {
      setFakeThinking(false);
      if (state.loadingPhase !== "local") {
        return undefined;
      }
      if (state.loadingCompleteToken > 0) {
        return undefined;
      }

      const timeout = window.setTimeout(() => setFakeThinking(true), 3000);
      return () => window.clearTimeout(timeout);
    }, [state.loadingPhase, state.title, state.loadingCompleteToken]);

    if (state.loadingPhase === "thinking" || (fakeThinking && state.loadingCompleteToken === 0)) {
      return h(
        "div",
        { className: "scroll result-scroll" },
        h(InferenceStatus, { mode: "thinking" })
      );
    }

    return h(LoadingMeterPage, { state });
  }

  function LoadingMeterPage({ state }) {
    const phase =
      state.loadingPhase === "web" ? "web" : state.loadingPhase === "hosted" ? "hosted" : "local";
    const [progress, setProgress] = React.useState(0);

    React.useEffect(() => {
      setProgress(0);
      const start = performance.now();
      let frame = 0;

      function tick(now) {
        const elapsed = now - start;
        const divisor = phase === "web" ? 2450 : phase === "hosted" ? 5200 : 3200;
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
    const caption =
      phase === "web" ? "searching web" : phase === "hosted" ? "waiting on model" : "reading";

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
        const headerSignature = cardHeaderSignature(state.items || []);
        trigger = headerSignature ? `result-cards:${headerSignature}` : "";
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
