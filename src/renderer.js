((cssText, version) => {
  const STATE_KEY = "__CODEX_NATIVE_DOCK_STATE__";
  const ROOT_ID = "codex-native-dock-root";
  const STYLE_ID = "codex-native-dock-style";
  const USAGE_BINDING = "__codexNativeDockUsageRequest";
  const USAGE_UPDATE = "__CODEX_NATIVE_DOCK_USAGE_UPDATE__";
  const rootElement = document.documentElement;

  const previous = window[STATE_KEY];
  previous?.cleanup?.();

  let mutationObserver = null;
  let composerObserver = null;
  let observedComposer = null;
  let layoutFrame = null;
  let ensureFrame = null;
  let pollTimer = null;
  let focusTimer = null;
  let activeScroller = null;
  let activeThreadId = null;
  let latestUsage = null;
  let nativeQuota = null;
  let lastNativeQuotaScan = 0;
  let lastUsageRequest = 0;
  let focusState = { active: false, sidebarWasExpanded: false, startedAt: 0 };

  const ICONS = {
    focus: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 3H4a1 1 0 0 0-1 1v4M16 3h4a1 1 0 0 1 1 1v4M8 21H4a1 1 0 0 1-1-1v-4M16 21h4a1 1 0 0 0 1-1v-4"/><circle cx="12" cy="12" r="3"/></svg>',
    sidebar: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M8.5 4v16M5.5 8h.01M5.5 12h.01"/></svg>',
    top: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h14M7 12l5-5 5 5M12 7v12"/></svg>',
    bottom: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 19h14M7 12l5 5 5-5M12 5v12"/></svg>',
  };

  const sidebarTrigger = () => document.querySelector("[data-app-shell-sidebar-trigger]");
  const threadScroller = () => document.querySelector(".thread-scroll-container");
  const composerSurface = () => document.querySelector(".composer-surface-chrome");
  const isChatGpt = () => /^\s*ChatGPT\b/i.test(
    document.querySelector("aside.app-shell-left-panel button")?.innerText || "",
  );
  const motionEnabled = () => {
    try {
      return !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    } catch {
      return true;
    }
  };
  const sidebarExpanded = () => {
    const label = sidebarTrigger()?.getAttribute?.("aria-label") || "";
    if (/hide|collapse|隐藏|收起/i.test(label)) return true;
    if (/show|expand|显示|展开/i.test(label)) return false;
    const width = document.querySelector("aside.app-shell-left-panel")?.getBoundingClientRect?.().width || 0;
    return width > 80;
  };

  const currentThreadId = () => {
    const active = document.querySelector('[data-app-action-sidebar-thread-id][aria-current="page"]');
    const raw = active?.getAttribute?.("data-app-action-sidebar-thread-id") || "";
    const normalized = raw.replace(/^local:/, "");
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)
      ? normalized
      : null;
  };

  const compactNumber = (value) => {
    const number = Number(value);
    if (!Number.isFinite(number)) return "--";
    if (Math.abs(number) >= 1_000_000) return `${(number / 1_000_000).toFixed(1)}M`;
    if (Math.abs(number) >= 1_000) return `${(number / 1_000).toFixed(number >= 100_000 ? 1 : 2)}K`;
    return Math.round(number).toLocaleString();
  };

  const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

  const scanNativeAccountQuota = () => {
    const candidates = [
      document.querySelector("aside.app-shell-left-panel"),
      document.querySelector(".composer-surface-chrome"),
      document.querySelector("#root"),
      document.body?.firstElementChild,
    ].filter(Boolean);
    let rootFiber = null;
    for (const host of candidates) {
      const fiberKey = Object.getOwnPropertyNames(host).find((key) => key.startsWith("__reactFiber"));
      if (!fiberKey) continue;
      rootFiber = host[fiberKey];
      while (rootFiber?.return) rootFiber = rootFiber.return;
      if (rootFiber) break;
    }
    if (!rootFiber) return null;

    const seen = new WeakSet();
    let inspectedObjects = 0;
    const inspect = (value, depth = 0) => {
      if (!value || typeof value !== "object" || depth > 7 || inspectedObjects > 16000 || seen.has(value)) return null;
      seen.add(value);
      inspectedObjects += 1;
      const usedPercent = Number(value.used_percent);
      const windowSeconds = Number(value.limit_window_seconds);
      if (Number.isFinite(usedPercent) && usedPercent >= 0 && usedPercent <= 100 &&
          Number.isFinite(windowSeconds) && windowSeconds > 0 &&
          Object.prototype.hasOwnProperty.call(value, "reset_at")) {
        const resetAt = Number(value.reset_at);
        const resetAfter = Number(value.reset_after_seconds);
        const resetsAt = Number.isFinite(resetAt) && resetAt > 0
          ? resetAt
          : Number.isFinite(resetAfter) && resetAfter >= 0
            ? Math.floor(Date.now() / 1000) + resetAfter
            : null;
        return {
          usedPercent,
          remainingPercent: clamp(100 - usedPercent, 0, 100),
          windowMinutes: windowSeconds / 60,
          resetsAt,
          source: "codex-native-account-state",
        };
      }
      for (const key of Object.getOwnPropertyNames(value).slice(0, 100)) {
        if (/^(?:return|child|sibling|alternate|stateNode|_owner|current|elementType|type)$/.test(key)) continue;
        let child;
        try { child = value[key]; } catch { continue; }
        const found = inspect(child, depth + 1);
        if (found) return found;
      }
      return null;
    };

    const stack = [rootFiber];
    let inspectedFibers = 0;
    while (stack.length > 0 && inspectedFibers < 14000) {
      const fiber = stack.pop();
      inspectedFibers += 1;
      const found = inspect(fiber.memoizedState) || inspect(fiber.memoizedProps);
      if (found) return found;
      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
    }
    return null;
  };

  const refreshNativeQuota = () => {
    if (Date.now() - lastNativeQuotaScan < 12000) return;
    lastNativeQuotaScan = Date.now();
    try {
      const detected = scanNativeAccountQuota();
      if (detected) nativeQuota = detected;
    } catch {}
  };

  const formatElapsed = (elapsedMs) => {
    const seconds = Math.max(0, Math.floor(Number(elapsedMs) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const rest = seconds % 60;
    return hours > 0
      ? `${hours}:${String(minutes).padStart(2, "0")}:${String(rest).padStart(2, "0")}`
      : `${String(minutes).padStart(2, "0")}:${String(rest).padStart(2, "0")}`;
  };

  const ensureStyle = () => {
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      style.dataset.codexNativeDockVersion = version;
      style.textContent = cssText;
      (document.head || document.documentElement).appendChild(style);
    }
    return style;
  };

  const makeTool = (tools, action, label, handler) => {
    const item = document.createElement("div");
    item.className = "cnd-tool-item";
    item.dataset.action = action;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "cnd-tool-button";
    button.dataset.action = action;
    button.setAttribute("aria-label", label);
    button.title = label;
    button.innerHTML = ICONS[action];
    button.addEventListener("click", handler);
    const tooltip = document.createElement("span");
    tooltip.className = "cnd-tooltip";
    tooltip.setAttribute("role", "tooltip");
    tooltip.textContent = label;
    item.append(button, tooltip);
    item.addEventListener("pointerleave", () => {
      if (item.contains(document.activeElement)) button.blur();
    });
    tools.appendChild(item);
    return button;
  };

  const ensureRoot = () => {
    let root = document.getElementById(ROOT_ID);
    if (root) return root;
    root = document.createElement("section");
    root.id = ROOT_ID;
    root.dataset.version = version;
    root.setAttribute("aria-label", "Codex Native Dock");

    const usage = document.createElement("div");
    usage.className = "cnd-usage is-unavailable";
    usage.tabIndex = 0;
    usage.setAttribute("aria-label", "Codex usage details");
    usage.innerHTML = [
      '<div class="cnd-usage-popover">',
      '  <div class="cnd-usage-cell"><span>Remaining</span><strong data-role="remaining">Unavailable</strong></div>',
      '  <div class="cnd-usage-cell"><span>Context</span><strong data-role="context">Unavailable</strong></div>',
      '  <div class="cnd-usage-cell"><span>Reset</span><strong data-role="reset">--</strong></div>',
      '</div>',
      '<div class="cnd-usage-track"><div class="cnd-usage-fill"></div></div>',
    ].join("");
    let pointerFocused = false;
    usage.addEventListener("pointerdown", () => { pointerFocused = true; });
    usage.addEventListener("pointerleave", () => {
      if (pointerFocused && usage.contains(document.activeElement)) usage.blur();
      pointerFocused = false;
    });

    const tools = document.createElement("nav");
    tools.className = "cnd-tools";
    tools.setAttribute("aria-label", "Codex quick controls");
    const orb = document.createElement("output");
    orb.className = "cnd-quota-orb";
    orb.dataset.role = "orb";
    orb.textContent = "--";
    orb.setAttribute("aria-label", "Usage unavailable");
    const divider = document.createElement("div");
    divider.className = "cnd-divider";
    divider.setAttribute("aria-hidden", "true");
    tools.append(orb, divider);
    makeTool(tools, "focus", "Focus mode", () => setFocusMode(!focusState.active));
    const focusTime = document.createElement("output");
    focusTime.className = "cnd-focus-time";
    focusTime.textContent = "00:00";
    tools.appendChild(focusTime);
    makeTool(tools, "sidebar", "Show or hide sidebar", () => sidebarTrigger()?.click?.());
    makeTool(tools, "top", "Current turn or previous turn", scrollToCurrentTurnTop);
    makeTool(tools, "bottom", "Latest message", scrollToLatest);

    root.append(usage, tools);
    document.body.appendChild(root);
    return root;
  };

  const updateFocusTime = () => {
    const output = document.querySelector(`#${ROOT_ID} .cnd-focus-time`);
    if (!output) return;
    const text = formatElapsed(focusState.active ? Date.now() - focusState.startedAt : 0);
    if (output.textContent !== text) output.textContent = text;
    output.setAttribute("aria-label", `Focus time ${text}`);
  };

  const stopFocusTimer = () => {
    if (focusTimer) clearInterval(focusTimer);
    focusTimer = null;
  };

  const restoreFocus = () => {
    if (!focusState.active) return;
    rootElement.classList.remove("codex-native-dock-focus");
    if (focusState.sidebarWasExpanded && !sidebarExpanded()) sidebarTrigger()?.click?.();
    focusState = { active: false, sidebarWasExpanded: false, startedAt: 0 };
    stopFocusTimer();
    updateFocusTime();
  };

  const setFocusMode = (active) => {
    if (active && !focusState.active) {
      focusState = {
        active: true,
        sidebarWasExpanded: sidebarExpanded(),
        startedAt: Date.now(),
      };
      if (focusState.sidebarWasExpanded) sidebarTrigger()?.click?.();
      rootElement.classList.add("codex-native-dock-focus");
      stopFocusTimer();
      focusTimer = setInterval(updateFocusTime, 1000);
    } else if (!active) {
      restoreFocus();
    }
    updateDockState();
  };

  const turns = (scroller) => [...(scroller?.querySelectorAll?.("[data-turn-key]") || [])]
    .map((element) => ({ element, rect: element.getBoundingClientRect?.() }))
    .filter(({ rect }) => rect && rect.height > 1);

  const scrollByAmount = (scroller, amount) => {
    if (!scroller || !Number.isFinite(amount)) return false;
    scroller.scrollTo?.({
      top: scroller.scrollTop + amount,
      behavior: motionEnabled() ? "smooth" : "auto",
    });
    return true;
  };

  function scrollToCurrentTurnTop() {
    const scroller = threadScroller();
    if (!scroller) return false;
    const entries = turns(scroller);
    if (entries.length === 0) return scrollByAmount(scroller, -Math.max(160, scroller.clientHeight * .82));
    const viewport = scroller.getBoundingClientRect();
    const tolerance = Math.max(6, Math.min(16, viewport.height * .018));
    const aligned = entries.findIndex(({ rect }) =>
      Math.abs(rect.top - viewport.top) <= tolerance && rect.bottom > viewport.top + tolerance);
    if (aligned >= 0) {
      if (aligned > 0) return scrollByAmount(scroller, entries[aligned - 1].rect.top - viewport.top);
      return scrollByAmount(scroller, -Math.max(160, scroller.clientHeight * .82));
    }
    const readingY = viewport.top + viewport.height * .5;
    let index = entries.findIndex(({ rect }) => rect.top <= readingY && rect.bottom > readingY);
    if (index < 0) {
      let bestOverlap = 0;
      entries.forEach(({ rect }, candidate) => {
        const overlap = Math.max(0, Math.min(rect.bottom, viewport.bottom) - Math.max(rect.top, viewport.top));
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          index = candidate;
        }
      });
    }
    if (index < 0) return false;
    if (entries[index].rect.top >= viewport.top - tolerance && index > 0) index -= 1;
    return scrollByAmount(scroller, entries[index].rect.top - viewport.top);
  }

  function scrollToLatest() {
    const scroller = threadScroller();
    if (!scroller) return false;
    scroller.scrollTo?.({
      top: scroller.scrollHeight,
      behavior: motionEnabled() ? "smooth" : "auto",
    });
    return true;
  }

  const setText = (root, role, value) => {
    const element = root?.querySelector?.(`[data-role="${role}"]`);
    if (element && element.textContent !== value) element.textContent = value;
  };

  const resetLabel = (value) => {
    const numeric = Number(value);
    if (!Number.isFinite(numeric) || numeric <= 0) return "--";
    const milliseconds = numeric < 1e12 ? numeric * 1000 : numeric;
    return new Date(milliseconds).toLocaleDateString([], { month: "2-digit", day: "2-digit" });
  };

  const renderUsage = () => {
    const root = document.getElementById(ROOT_ID);
    const usage = root?.querySelector?.(".cnd-usage");
    const orb = root?.querySelector?.(".cnd-quota-orb");
    if (!usage || !orb) return;
    if (isChatGpt()) {
      usage.hidden = true;
      if (orb.textContent !== "∞") orb.textContent = "∞";
      orb.style.setProperty("--cnd-quota", "100%");
      orb.setAttribute("aria-label", "ChatGPT usage meter hidden");
      return;
    }
    usage.hidden = !threadScroller();
    const data = latestUsage?.threadId === activeThreadId ? latestUsage : null;
    const nativeRemaining = Number(nativeQuota?.remainingPercent);
    const sessionRemaining = Number(data?.rateLimits?.primary?.remainingPercent);
    const remaining = Number.isFinite(nativeRemaining) ? nativeRemaining : sessionRemaining;
    const available = Number.isFinite(remaining);
    usage.classList.toggle("is-unavailable", !available);
    usage.dataset.level = available ? remaining <= 15 ? "critical" : remaining <= 35 ? "low" : "normal" : "unknown";
    if (available) {
      const bounded = Math.min(100, Math.max(0, remaining));
      const first = usage.dataset.initialized !== "true";
      if (first) usage.classList.add("is-initializing");
      usage.style.setProperty("--cnd-remaining", `${bounded}%`);
      orb.style.setProperty("--cnd-quota", `${bounded}%`);
      usage.dataset.initialized = "true";
      if (first) {
        usage.querySelector(".cnd-usage-fill")?.getBoundingClientRect?.();
        usage.classList.remove("is-initializing");
      }
      const orbText = `${Math.round(bounded)}`;
      if (orb.textContent !== orbText) orb.textContent = orbText;
      orb.setAttribute("aria-label", `${bounded.toFixed(1)} percent usage remaining`);
    } else {
      if (orb.textContent !== "--") orb.textContent = "--";
      orb.style.setProperty("--cnd-quota", "0%");
      orb.setAttribute("aria-label", "Usage unavailable");
    }
    setText(usage, "remaining", available ? `${remaining.toFixed(1)}% remaining` : "Unavailable");
    const used = Number(data?.context?.usedTokens);
    const windowTokens = Number(data?.context?.windowTokens);
    setText(usage, "context", Number.isFinite(used) && Number.isFinite(windowTokens) && windowTokens > 0
      ? `${compactNumber(used)} / ${compactNumber(windowTokens)}`
      : "Unavailable");
    setText(usage, "reset", resetLabel(nativeQuota?.resetsAt ?? data?.rateLimits?.primary?.resetsAt));
  };

  const positionUsage = () => {
    layoutFrame = null;
    const usage = document.querySelector(`#${ROOT_ID} .cnd-usage`);
    const composer = observedComposer;
    if (!usage || !composer?.getBoundingClientRect) return;
    const rect = composer.getBoundingClientRect();
    const viewportWidth = Number(window.innerWidth) || document.documentElement.clientWidth;
    const viewportHeight = Number(window.innerHeight) || document.documentElement.clientHeight;
    const left = Math.max(8, rect.left);
    const width = Math.max(120, Math.min(rect.width, viewportWidth - left - 8));
    const top = Math.max(4, Math.min(viewportHeight - 8, rect.bottom + 1));
    usage.style.setProperty("width", `${width}px`, "important");
    usage.style.setProperty("transform", `translate3d(${left}px, ${top}px, 0)`, "important");
  };

  const scheduleLayout = () => {
    if (layoutFrame !== null) return;
    layoutFrame = requestAnimationFrame(positionUsage);
  };

  const requestUsage = () => {
    const nextThread = currentThreadId();
    if (nextThread !== activeThreadId) {
      activeThreadId = nextThread;
      latestUsage = null;
      renderUsage();
    }
    if (!activeThreadId || isChatGpt() || Date.now() - lastUsageRequest < 3000) return;
    const binding = window[USAGE_BINDING];
    if (typeof binding !== "function") return;
    lastUsageRequest = Date.now();
    try {
      binding(JSON.stringify({ action: "usage", threadId: activeThreadId }));
    } catch {}
  };

  function updateDockState() {
    const root = document.getElementById(ROOT_ID);
    if (!root) return;
    const scroller = threadScroller();
    const scrollable = Boolean(scroller && scroller.scrollHeight > scroller.clientHeight + 1);
    const focus = root.querySelector('[data-action="focus"].cnd-tool-button');
    const sidebar = root.querySelector('[data-action="sidebar"].cnd-tool-button');
    const top = root.querySelector('[data-action="top"].cnd-tool-button');
    const bottom = root.querySelector('[data-action="bottom"].cnd-tool-button');
    if (focus) {
      focus.classList.toggle("is-active", focusState.active);
      focus.setAttribute("aria-pressed", String(focusState.active));
    }
    if (sidebar) {
      sidebar.disabled = focusState.active || !sidebarTrigger();
      sidebar.setAttribute("aria-pressed", String(sidebarExpanded()));
    }
    if (top) top.disabled = !scrollable;
    if (bottom) bottom.disabled = !scrollable;
    updateFocusTime();
  }

  const ensure = () => {
    ensureFrame = null;
    if (!document.body || !composerSurface() || !sidebarTrigger()) return;
    ensureStyle();
    ensureRoot();
    const composer = composerSurface();
    if (composer !== observedComposer) {
      composerObserver?.disconnect?.();
      observedComposer = composer;
      composerObserver = typeof ResizeObserver === "function" ? new ResizeObserver(scheduleLayout) : null;
      composerObserver?.observe?.(composer);
    }
    positionUsage();
    const scroller = threadScroller();
    if (scroller !== activeScroller) {
      activeScroller?.removeEventListener?.("scroll", updateDockState);
      activeScroller = scroller;
      activeScroller?.addEventListener?.("scroll", updateDockState, { passive: true });
    }
    updateDockState();
    refreshNativeQuota();
    renderUsage();
    requestUsage();
  };

  const scheduleEnsure = () => {
    if (ensureFrame !== null) return;
    ensureFrame = requestAnimationFrame(ensure);
  };

  const cleanup = () => {
    restoreFocus();
    mutationObserver?.disconnect?.();
    composerObserver?.disconnect?.();
    activeScroller?.removeEventListener?.("scroll", updateDockState);
    window.removeEventListener("resize", scheduleLayout);
    if (layoutFrame !== null) cancelAnimationFrame(layoutFrame);
    if (ensureFrame !== null) cancelAnimationFrame(ensureFrame);
    if (pollTimer) clearInterval(pollTimer);
    stopFocusTimer();
    document.getElementById(ROOT_ID)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    rootElement.classList.remove("codex-native-dock-focus");
    if (window[USAGE_UPDATE]) delete window[USAGE_UPDATE];
    if (window[STATE_KEY]?.installToken === installToken) delete window[STATE_KEY];
    return true;
  };

  const installToken = {};
  window[USAGE_UPDATE] = (metrics) => {
    if (!metrics || metrics.threadId !== activeThreadId) return;
    latestUsage = metrics;
    renderUsage();
  };
  window.addEventListener("resize", scheduleLayout, { passive: true });
  mutationObserver = new MutationObserver((records) => {
    const root = document.getElementById(ROOT_ID);
    if (records.some(({ target }) => !root?.contains?.(target))) scheduleEnsure();
  });
  mutationObserver.observe(document.documentElement, { childList: true, subtree: true });
  pollTimer = setInterval(() => {
    ensure();
    requestUsage();
  }, 4000);
  window[STATE_KEY] = { cleanup, ensure, installToken, version };
  ensure();
  return { installed: true, version, palette: "codex-native-dark", adaptiveTheme: false };
})(__CND_CSS_JSON__, __CND_VERSION_JSON__)
