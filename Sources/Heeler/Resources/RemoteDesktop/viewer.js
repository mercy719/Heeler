// Heeler's script in the Moonlight Web viewer page (upstream v3.0.1). Ported from OpenBot's viewer-page-script.ts
// (apps/mobile/src/features/remote-desktop/model/; Copyright 2026 Synthetify Labs sp. z o.o., PolyForm Noncommercial
// 1.0.0; licence in Resources/Notices/OpenBot-PolyForm-Noncommercial-1.0.0.txt). Heeler's changes: the WebSocket
// transport, the codec rewrite, stats over the app's message handler instead of a POST to the page's origin, and a
// stream size Swift computes. This script only sets values in the page; the app calls in through `window.__heelerRD`
// and reads samples from `heelerRD`.
(() => {
  const CONFIG = window.__heelerRDConfig || {};
  const post = (payload) => {
    try { window.webkit.messageHandlers.heelerRD.postMessage(payload); } catch {}
  };
  // Only the characters of a CSS colour value, so it cannot end the rule.
  const cssColor = (value) => /^[#A-Za-z0-9(),.%\s-]{1,64}$/u.test(String(value)) ? String(value) : "black";
  // Moonlight reads `mlSettings` from local storage when its stream page starts. The transport must be WebSocket.
  try {
    const current = JSON.parse(localStorage.getItem("mlSettings") || "{}");
    localStorage.setItem("mlSettings", JSON.stringify(Object.assign({}, current, {
      fps: CONFIG.fps, bitrate: CONFIG.bitrate, videoSize: "custom",
      videoSizeCustom: { width: CONFIG.width, height: CONFIG.height },
      videoCodec: "h264",  // every phone decodes H.264 in hardware
      dataTransport: "websocket", playAudioLocal: false,
      enterFullscreenOnStreamStart: false, touchMode: CONFIG.touchMode, mouseMode: "follow",
    })));
  } catch {}
  // The app's black page in place of Moonlight's blue one; Moonlight's stats overlay and pointer stay hidden.
  try {
    const style = document.createElement("style");
    style.textContent = "html,body,#root,.video-stream{background:" + cssColor(CONFIG.background) +
      " !important}body::before{display:none !important}.video-stats{display:none !important}" +
      ".video-stream{transition:none !important}.local-touch-cursor{display:none !important}";
    (document.head || document.documentElement).appendChild(style);
  } catch {}
  // iOS WebKit rejects the codec strings Moonlight v3 hard-codes (`avc3.…`, `hev1.…`) and falls back to its 4.5 MB
  // software pipeline. Rewriting that one field is the whole difference; every other field passes through
  // (docs/rc/exp2-report.md).
  let frames = 0, secondFrames = 0, firstFrameSent = false, statsTimer = null;
  const rewriteCodec = (config) => {
    if (!config || typeof config.codec !== "string") return config;
    const codec = config.codec.replace(/^avc3\./i, "avc1.").replace(/^hev1\./i, "hvc1.");
    return codec === config.codec ? config : Object.assign({}, config, { codec });
  };
  const NativeDecoder = window.VideoDecoder;
  if (typeof NativeDecoder === "function") {
    // A function rather than a subclass: it hands back the native decoder.
    const Patched = function (init) {
      const options = Object.assign({}, init);
      const output = init && init.output;
      if (typeof output === "function") {
        options.output = (frame) => {
          frames += 1; secondFrames += 1;
          // The first picture is what ends "connecting" in the app.
          if (!firstFrameSent) { firstFrameSent = true; post({ firstFrame: true }); }
          output(frame);
        };
      }
      return new NativeDecoder(options);
    };
    Patched.prototype = NativeDecoder.prototype;
    Patched.isConfigSupported = (config) => NativeDecoder.isConfigSupported(rewriteCodec(config));
    const configure = NativeDecoder.prototype.configure;
    NativeDecoder.prototype.configure = function (config) { return configure.call(this, rewriteCodec(config)); };
    window.VideoDecoder = Patched;
  }
  if (window.__heelerRD) return;
  // The keys of a US keyboard for each printable ASCII character: code, Shift.
  const KEYS = { " ": ["Space", false], "\n": ["Enter", false], "\t": ["Tab", false] };
  for (const letter of "abcdefghijklmnopqrstuvwxyz") {
    const code = "Key" + letter.toUpperCase();
    KEYS[letter] = [code, false]; KEYS[letter.toUpperCase()] = [code, true];
  }
  "0123456789".split("").forEach((digit) => { KEYS[digit] = ["Digit" + digit, false]; });
  ")!@#$%^&*(".split("").forEach((symbol, digit) => { KEYS[symbol] = ["Digit" + digit, true]; });
  [["-", "_", "Minus"], ["=", "+", "Equal"], ["[", "{", "BracketLeft"], ["]", "}", "BracketRight"],
    ["\\", "|", "Backslash"], [";", ":", "Semicolon"], ["'", '"', "Quote"], [",", "<", "Comma"],
    [".", ">", "Period"], ["/", "?", "Slash"], ["`", "~", "Backquote"],
  ].forEach(([plain, shifted, code]) => { KEYS[plain] = [code, false]; KEYS[shifted] = [code, true]; });

  const FLAGS = { ShiftLeft: "shiftKey", ControlLeft: "ctrlKey", AltLeft: "altKey", MetaLeft: "metaKey" };
  const held = new Set();
  const flags = (extra) => Object.assign(
    Object.fromEntries([...held].map((code) => [FLAGS[code], true])), extra ? { shiftKey: true } : {});
  const press = (type, code, key, shift) => document.dispatchEvent(new KeyboardEvent(type,
    Object.assign({ code, key, bubbles: true, cancelable: true }, flags(shift))));
  const tap = (code, key, shift) => {
    const addShift = shift && !held.has("ShiftLeft");
    if (addShift) press("keydown", "ShiftLeft", "Shift", true);
    press("keydown", code, key, shift);
    press("keyup", code, key, shift);
    if (addShift) press("keyup", "ShiftLeft", "Shift", false);
  };
  const input = () => {
    const app = window.app;
    return app && app.stream && app.stream.getInput ? app.stream.getInput() : null;
  };
  // Zoom is a transform of Moonlight's video element: it is `position: fixed`, so a parent's transform would move it
  // instead, and the page animates transforms while a place read mid-animation is wrong, so its transition is off.
  // Moonlight maps a touch through the box, which includes the transform.
  const view = { scale: 1, x: 0, y: 0 };
  const COVERED = {
    top: Math.max(0, Math.round((CONFIG.covered && CONFIG.covered.top) || 0)),
    bottom: Math.max(0, Math.round((CONFIG.covered && CONFIG.covered.bottom) || 0)),
  };
  const videos = () => Array.from(document.querySelectorAll(".video-stream"));
  const apply = () => {
    for (const video of videos()) video.style.transform = view.scale === 1 ? "" :
      "translate(" + view.x + "px," + view.y + "px) translate(-50%,-50%) scale(" + view.scale + ")";
  };
  const base = () => {
    const video = videos().find((element) => element.getBoundingClientRect().width > 0);
    if (!video) return null;
    const rect = video.getBoundingClientRect();
    return { cx: rect.left + rect.width / 2 - view.x, cy: rect.top + rect.height / 2 - view.y,
      w: rect.width / view.scale, h: rect.height / view.scale };
  };
  const clampAxis = (offset, center, size, viewport) => size <= viewport ? viewport / 2 - center
    : Math.min(size / 2 - center, Math.max(viewport - size / 2 - center, offset));
  const zoomAt = (scale, ax, ay, dx, dy) => {
    const box = base();
    if (!box) return;
    const next = Math.min(5, Math.max(1, scale)), k = next / view.scale;
    const cx = box.cx + view.x, cy = box.cy + view.y;
    const x = ax + (cx - ax) * k - box.cx + (dx || 0), y = ay + (cy - ay) * k - box.cy + (dy || 0);
    if (next <= 1.02) { view.scale = 1; view.x = 0; view.y = 0; apply(); return; }
    view.scale = next;
    view.x = clampAxis(x, box.cx, box.w * next, innerWidth);
    view.y = clampAxis(y, box.cy, box.h * next, innerHeight);
    apply();
  };

  window.__heelerRD = {
    key(code, key) { tap(code, key, false); },
    modifier(code, down) {
      if (!(code in FLAGS)) return;
      if (down) { held.add(code); press("keydown", code, code.replace(/Left$/, ""), false); }
      else { held.delete(code); press("keyup", code, code.replace(/Left$/, ""), false); }
    },
    type(value) {
      let text = "";
      const flush = () => {
        const target = input();
        // Moonlight counts characters and the host counts code points, so a surrogate pair cannot go as text.
        if (target && target.sendText && text) target.sendText(text);
        text = "";
      };
      for (const character of Array.from(String(value))) {
        const known = KEYS[character];
        if (known) { flush(); tap(known[0], character, known[1]); }
        else if (character.length === 1) { text += character; if (text.length >= 64) flush(); }
      }
      flush();
    },
    touchMode(mode) {
      const app = window.app;
      if (app && app.getInputConfig && app.setInputConfig)
        app.setInputConfig(Object.assign({}, app.getInputConfig(), { touchMode: mode }));
    },
    fit() { view.scale = 1; view.x = 0; view.y = 0; apply(); },
    // Returns false until the page has a stream to measure.
    stats(on) {
      clearInterval(statsTimer);
      statsTimer = null;
      const app = window.app;
      const stream = app && app.getStream && app.getStream();
      const stats = stream && stream.getStats && stream.getStats();
      if (!stats || !stats.setEnabled) return false;
      stats.setEnabled(Boolean(on));
      if (!on) return true;
      // The page's own origin is the computer, so the sample goes to the app.
      statsTimer = setInterval(() => {
        let rttMs = null;
        try {
          const transport = stats.getCurrentStats().transport || {};
          if (typeof transport.relayToClientRttMs === "number") rttMs = Math.round(transport.relayToClientRttMs);
        } catch {}
        post({ fps: secondFrames, rttMs, frames });
        secondFrames = 0;
      }, 1000);
      return true;
    },
  };
  // A gesture the view owns from start to last lift: a pinch, or three fingers. Moonlight forgets the touches it
  // had, so a finger it saw first does not click or stay down.
  let gesture = null, pending = null;
  const measure = (touches) => {
    let x = 0, y = 0;
    for (const touch of touches) { x += touch.clientX; y += touch.clientY; }
    const [first, second] = touches;
    return { count: touches.length, x: x / touches.length, y: y / touches.length,
      d: second ? Math.max(1, Math.hypot(first.clientX - second.clientX, first.clientY - second.clientY)) : 1 };
  };
  const own = (touches, from) => {
    pending = null;
    gesture = { last: from || measure(touches) };
    const target = input(), app = window.app;
    if (target && app && app.getStreamRect) target.onTouchCancel({ changedTouches: [] }, app.getStreamRect());
  };
  const swallow = (event) => {
    event.stopImmediatePropagation();
    if (event.cancelable) event.preventDefault();
  };
  addEventListener("touchstart", (event) => {
    if (gesture) { gesture.last = measure(event.touches); return swallow(event); }
    if (event.touches.length >= 3) { own(event.touches); return swallow(event); }
    pending = event.touches.length === 2 ? measure(event.touches) : null;
  }, { capture: true, passive: false });
  addEventListener("touchmove", (event) => {
    if (!gesture && pending && event.touches.length === 2) {
      const now = measure(event.touches);
      // A pinch, not a scroll: the fingers move apart or together by an eighth.
      if (Math.abs(now.d / pending.d - 1) > 0.12) own(event.touches, pending);
    }
    if (!gesture) return;
    swallow(event);
    if (event.touches.length < 2) return;
    const now = measure(event.touches);
    // A change of fingers starts the count again, so the view does not jump.
    if (now.count !== gesture.last.count) { gesture.last = now; return; }
    const scale = now.count === 2 ? view.scale * (now.d / gesture.last.d) : view.scale;
    zoomAt(scale, now.x, now.y, now.x - gesture.last.x, now.y - gesture.last.y);
    gesture.last = now;
  }, { capture: true, passive: false });
  const lift = (event) => {
    if (event.touches.length < 2) pending = null;
    if (!gesture) return;
    swallow(event);
    gesture = event.touches.length === 0 ? null : { last: measure(event.touches) };
  };
  addEventListener("touchend", lift, { capture: true, passive: false });
  addEventListener("touchcancel", lift, { capture: true, passive: false });
  // While zoomed in, the view follows the pointer: one that moves near an edge, or under the app's bars, moves the
  // view until the pointer is in view again. Only a moving pointer does this, so a view the fingers moved away from
  // the pointer stays where they left it.
  const EDGE = 40;
  let lastCursor = null;
  const follow = () => {
    requestAnimationFrame(follow);
    const target = input(), app = window.app;
    if (!target || !target.getLocalCursorState || !app || !app.getStreamRect) return;
    const cursor = target.getLocalCursorState();
    if (!cursor || !cursor.visible) return;
    const moved = !lastCursor || lastCursor.x !== cursor.x || lastCursor.y !== cursor.y;
    lastCursor = { x: cursor.x, y: cursor.y };
    if (!moved || view.scale === 1 || gesture) return;
    const rect = app.getStreamRect();
    if (!rect || rect.width <= 0) return;
    const px = rect.left + cursor.x * rect.width, py = rect.top + cursor.y * rect.height;
    const left = EDGE, right = innerWidth - EDGE, top = COVERED.top + EDGE, bottom = innerHeight - COVERED.bottom - EDGE;
    const dx = px < left ? left - px : px > right ? right - px : 0;
    const dy = py < top ? top - py : py > bottom ? bottom - py : 0;
    if (dx !== 0 || dy !== 0) zoomAt(view.scale, 0, 0, dx, dy);
  };
  requestAnimationFrame(follow);
  // The app shows the latency and frame rate for the session; the stream arrives after this script.
  let waits = 0;
  const armStats = () => {
    if (window.__heelerRD.stats(true) || waits >= 120) return;
    waits += 1; setTimeout(armStats, 500);
  };
  armStats();
})();
