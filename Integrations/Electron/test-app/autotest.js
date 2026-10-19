// Automated regression suite for the FullPanelKit Electron integration.
//
// Fullscreen transitions are real AppKit transitions on the built-in display.
// Waits are bounded and tied to a condition: Electron's fullscreen events,
// FullPanel state, WindowServer bounds or the renderer's own resize. There are
// no fixed delays. Mission Control and physical clicks are not simulated.
'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');

// Hardware baseline: MacBook Pro 14-inch, "More Space" (see docs/HARDWARE_BASELINE.md).
const BASELINE = { width: 1800, height: 1169 };
const MAGENTA = { r: 255, g: 0, b: 255 };
const CYAN = { r: 0, g: 255, b: 255 };

// ---- Generic helpers ----------------------------------------------------------------

const nearly = (a, b, tolerance = 0.5) => Math.abs(a - b) <= tolerance;
const sameRect = (a, b, tolerance = 0.5) => Boolean(a && b) &&
  nearly(a.x, b.x, tolerance) && nearly(a.y, b.y, tolerance) &&
  nearly(a.width, b.width, tolerance) && nearly(a.height, b.height, tolerance);

async function waitFor(predicate, timeoutMs, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await predicate();
    if (value || Date.now() >= deadline) return value;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

function waitForEvent(emitter, name, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      emitter.removeListener(name, listener);
      reject(new Error(`timed out waiting for '${name}'`));
    }, timeoutMs);
    function listener(...args) {
      clearTimeout(timer);
      resolve(args);
    }
    emitter.once(name, listener);
  });
}

const STYLE_KEYS = ['titled', 'resizable', 'fullSizeContentView', 'titlebarAppearsTransparent',
  'titleHidden', 'fullScreenPrimary', 'closeButtonHidden'];
const styleOf = (native) => Object.fromEntries(STYLE_KEYS.map((key) => [key, native[key]]));
const styleDiff = (a, b) => STYLE_KEYS.filter((key) => a[key] !== b[key])
  .map((key) => `${key}: ${a[key]} → ${b[key]}`);
const sameStyle = (a, b) => styleDiff(styleOf(a), styleOf(b)).length === 0;

// ---- Harness bound to the app's context --------------------------------------------

function harness(ctx) {
  const { fullPanel, report } = ctx;

  async function readViewport(win) {
    try {
      return await win.webContents.executeJavaScript('window.readViewport()');
    } catch (error) {
      return { error: String(error) };
    }
  }

  // Two animation frames in the renderer: everything the browser process sent
  // before has been applied and painted.
  const rendererBarrier = (win) => win.webContents.executeJavaScript(
    'new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))');

  const waitViewport = (win, width, height) => waitFor(async () => {
    const viewport = await readViewport(win);
    return viewport.innerWidth === Math.round(width) && viewport.innerHeight === Math.round(height);
  }, 4000);

  // WindowServer applies frames asynchronously.
  const waitWindowServer = (win) => waitFor(() => fullPanel.inspect(win).windowServerMatchesFrame, 4000);

  async function snapshot(win, label) {
    await rendererBarrier(win);
    const diagnostics = fullPanel.getDiagnostics(win);
    const result = {
      electron: {
        bounds: win.getBounds(),
        contentBounds: win.getContentBounds(),
        isFullScreen: win.isFullScreen(),
        isSimpleFullScreen: win.isSimpleFullScreen(),
      },
      native: diagnostics.native,
      state: diagnostics.state,
      session: diagnostics.session,
      geometry: fullPanel.getGeometry(win),
      viewport: await readViewport(win),
    };
    if (label) report.snapshots[label] = result;
    return result;
  }

  const viewportMatchesContent = (snap) => {
    const content = snap.geometry.content || {};
    return snap.viewport.innerWidth === Math.round(content.width) &&
      snap.viewport.innerHeight === Math.round(content.height);
  };

  async function setWindowed(win, bounds) {
    win.setBounds(bounds);
    await waitWindowServer(win);
    const content = win.getContentBounds();
    await waitViewport(win, content.width, content.height);
  }

  async function enterFullScreen(win, label, expectFullPanel) {
    const entered = waitForEvent(win, 'enter-full-screen', 15000);
    win.setFullScreen(true);
    await entered;
    if (expectFullPanel) {
      await waitFor(() => ['Active', 'Fallback'].includes(fullPanel.getState(win).stateName), 5000);
    }
    await waitWindowServer(win);
    const content = fullPanel.getGeometry(win).content;
    await waitViewport(win, content.width, content.height);
    return snapshot(win, label);
  }

  // `expected`: the windowed bounds the exit should restore. The integration
  // corrects the frame on the main queue right after the exit notification;
  // the snapshot's renderer barrier runs after that.
  async function exitFullScreen(win, label, expected) {
    const left = waitForEvent(win, 'leave-full-screen', 15000);
    win.setFullScreen(false);
    await left;
    if (expected) await waitFor(() => sameRect(win.getBounds(), expected, 1), 4000);
    await waitWindowServer(win);
    const content = win.getContentBounds();
    await waitViewport(win, content.width, content.height);
    return snapshot(win, label);
  }

  const corrections = () => fullPanel.addonInfo().frameCorrections;

  async function sampleNotchPixels(win, geometry) {
    const content = geometry.content;
    ctx.pushUpdates();
    const markers = await waitFor(async () => {
      const m = await win.webContents.executeJavaScript('window.readMarkers()');
      return m.left && m.right && sameRect(m.left, content.auxiliaryLeftArea, 1) &&
        sameRect(m.right, content.auxiliaryRightArea, 1) ? m : null;
    }, 3000);
    await rendererBarrier(win);
    const image = await win.webContents.capturePage();
    const size = image.getSize();
    const bitmap = image.toBitmap();
    // getSize() can report device pixels or DIPs; the bitmap decides. Sample
    // points are in content-view coordinates (DIPs).
    const rowPixels = size.width * size.height * 4 === bitmap.length ? size.width
      : Math.round(Math.sqrt((bitmap.length / 4) * (size.width / size.height)));
    const rows = bitmap.length / 4 / rowPixels;
    const scale = rowPixels / content.width;
    const pixel = (x, y) => {
      const px = Math.min(Math.floor(x * scale), rowPixels - 1);
      const py = Math.min(Math.floor(y * scale), rows - 1);
      const i = (py * rowPixels + px) * 4;
      return { r: bitmap[i + 2], g: bitmap[i + 1], b: bitmap[i], a: bitmap[i + 3] };
    };
    const near = (p, target) => Math.abs(p.r - target.r) <= 48 &&
      Math.abs(p.g - target.g) <= 48 && Math.abs(p.b - target.b) <= 48;
    const sampleRect = (rect, target) => {
      if (!rect) return { rect, ok: false, samples: [] };
      const inset = 3;
      const points = [
        [rect.x + rect.width / 2, rect.y + rect.height / 2],
        [rect.x + inset, rect.y + inset],
        [rect.x + rect.width - inset, rect.y + inset],
        [rect.x + inset, rect.y + rect.height - inset],
        [rect.x + rect.width - inset, rect.y + rect.height - inset],
      ];
      const samples = points.map(([x, y]) => ({ x, y, ...pixel(x, y) }));
      return { rect, ok: samples.every((s) => near(s, target)), samples };
    };
    return {
      captureSize: size,
      captureScale: scale,
      markers,
      left: sampleRect(content.auxiliaryLeftArea, MAGENTA),
      right: sampleRect(content.auxiliaryRightArea, CYAN),
    };
  }

  return {
    readViewport, rendererBarrier, snapshot, viewportMatchesContent, setWindowed,
    enterFullScreen, exitFullScreen, corrections, sampleNotchPixels,
  };
}

// ---- Phase 1: bridge -------------------------------------------------------------------

function bridgeChecks(ctx) {
  const { fullPanel, windows, check, report } = ctx;
  const info = fullPanel.addonInfo();
  report.addon = info;
  let ok = true;
  ok = check('P1.1', 'Addon loads into Electron 44.7.0 (Node-API)',
    process.versions.electron === '44.7.0' && info.runtimeNapiVersion >= info.builtForNapiVersion,
    { electron: process.versions.electron, node: info.runtimeNodeVersion,
      runtimeNapi: info.runtimeNapiVersion, builtForNapi: info.builtForNapiVersion }) && ok;
  ok = check('P1.2', 'Calls run on the macOS main thread',
    info.pthreadMainThread && info.nsThreadMainThread, info) && ok;
  ok = check('P1.dup', 'FullPanelKitCore classes come from this addon only',
    info.duplicateClassProblem === null,
    { problem: info.duplicateClassProblem, image: info.fullPanelSessionImage }) && ok;

  for (const role of ['A', 'B']) {
    const handle = windows[role].getNativeWindowHandle();
    const handleAddress = `0x${handle.readBigUInt64LE(0).toString(16)}`;
    ok = check(`P1.3-${role}`, `${role}: getNativeWindowHandle() is a pointer-sized Buffer`,
      Buffer.isBuffer(handle) && handle.length === 8, { length: handle.length }) && ok;
    let facts;
    try {
      facts = fullPanel.inspect(handle);
    } catch (error) {
      check(`P1.4-${role}`, `${role}: handle resolves to a live NSView`, false,
        { error: String(error), code: error.code });
      return false;
    }
    report.snapshots[`bridge-${role}`] = facts;
    ok = check(`P1.4-${role}`, `${role}: handle is an NSView of a live window (not the NSWindow)`,
      facts.handleViewAddress === handleAddress && facts.windowAddress !== handleAddress,
      { handleAddress, handleViewClass: facts.handleViewClass,
        handleIsContentView: facts.handleIsContentView, windowAddress: facts.windowAddress }) && ok;
    ok = check(`P1.5-${role}`, `${role}: owning NSWindow found`,
      Boolean(facts.windowAddress && facts.windowNumber > 0),
      { windowAddress: facts.windowAddress, windowNumber: facts.windowNumber }) && ok;
    ok = check(`P1.6-${role}`, `${role}: class ${facts.windowClass}, runtime class ${facts.windowRuntimeClass}`,
      Boolean(facts.windowClass && facts.windowRuntimeClass),
      { superclassChain: facts.superclassChain, image: facts.windowClassImage }) && ok;
    ok = check(`P1.7-${role}`, `${role}: class is eligible for FullPanelSession attachment`,
      facts.eligibleForAttachment && facts.isElectronNSWindow && !facts.hasSession,
      { reason: facts.ineligibleReason, hasSession: facts.hasSession }) && ok;
  }

  const rejects = (buffer, code) => {
    try {
      fullPanel.inspect(buffer);
      return false;
    } catch (error) {
      return error.code === code;
    }
  };
  const bogus = Buffer.alloc(8);
  bogus.writeBigUInt64LE(0x10n);
  ok = check('P1.safe', 'Malformed, null and unknown handles are rejected without dereferencing',
    rejects(Buffer.alloc(4), 'ERR_FULLPANEL_HANDLE') && rejects(Buffer.alloc(8), 'ERR_FULLPANEL_HANDLE') &&
      rejects(bogus, 'ERR_FULLPANEL_NO_WINDOW')) && ok;
  return ok;
}

// ---- Shutdown with a session attached (separate Electron process) ------------------------

function runShutdownChild(variant) {
  return new Promise((resolve) => {
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    const args = [path.join(__dirname, 'main.js'), '--shutdown-check'];
    if (variant === 'fullscreen') args.push('--fullscreen');
    const child = spawn(process.execPath, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (data) => { output += data; });
    child.stderr.on('data', (data) => { output += data; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 45000);
    child.on('exit', (code, signal) => {
      clearTimeout(timer);
      const prefix = 'FULLPANEL_SHUTDOWN ';
      const line = output.split('\n').find((l) => l.startsWith(prefix));
      resolve({ code, signal, result: line ? JSON.parse(line.slice(prefix.length)) : null,
        tail: output.slice(-1500) });
    });
  });
}

// ---- Regression suite ---------------------------------------------------------------------

async function runAutotest(ctx) {
  const { fullPanel, windows, check, createWindow, report } = ctx;
  const h = harness(ctx);
  const A = windows.A;
  const B = windows.B;

  // Fullscreen tests need the test windows on the active Space. A Space switch
  // or Mission Control in progress (someone using the Mac) shows up as
  // WindowServer bounds that differ from the frame.
  const settled = (win) => {
    const n = fullPanel.inspect(win);
    return n.onActiveSpace && n.windowServerMatchesFrame;
  };
  const ready = await waitFor(() => settled(A) && settled(B), 5000);
  if (!check('ENV', 'Test windows are on the active Space and settled (leave the Mac idle during the run)',
    ready, { A: fullPanel.inspect(A), B: fullPanel.inspect(B) })) return;
  const bStart = fullPanel.inspect(B);

  // -- Windowed attach and the root cause of the titlebar growth ------------------------------
  const preAttach = await h.snapshot(A, 'A-windowed-before-attach');
  const conversion = preAttach.native.frameConversion;
  const growth = conversion.growth;
  check('R1', 'Root cause: Electron reports the whole frame as content; AppKit adds a titlebar back',
    !preAttach.native.fullSizeContentView && growth > 0 &&
      sameRect(conversion.contentRectForFrame, preAttach.native.windowFrame),
    { frame: preAttach.native.windowFrame, ...conversion });
  const attached = fullPanel.attach(A);
  check('A.attach', 'Attach FullPanelSession to window A', attached.ok && !attached.alreadyAttached, attached);
  if (!attached.ok) return;
  check('A.enable', 'Enable FullPanel on window A', fullPanel.setEnabled(A, true).enabled);
  const enabled = await h.snapshot(A, 'A-windowed-enabled');
  check('R2', 'With fullSizeContentView the same conversion keeps the frame (no growth)',
    enabled.native.fullSizeContentView && nearly(enabled.native.frameConversion.growth, 0),
    enabled.native.frameConversion);
  check('W1', 'Enabling keeps the frame, content bounds and WindowServer bounds',
    sameRect(preAttach.electron.bounds, enabled.electron.bounds) &&
      sameRect(preAttach.electron.contentBounds, enabled.electron.contentBounds) &&
      enabled.native.windowServerMatchesFrame,
    { before: preAttach.electron, after: enabled.electron });
  check('W2', 'Enabling keeps the renderer viewport and traffic lights',
    preAttach.viewport.innerWidth === enabled.viewport.innerWidth &&
      preAttach.viewport.innerHeight === enabled.viewport.innerHeight &&
      sameRect(preAttach.native.closeButtonFrame, enabled.native.closeButtonFrame),
    { before: preAttach.viewport, after: enabled.viewport });
  check('W3', 'Enabling changes only fullSizeContentView (and fullScreenPrimary if missing)',
    styleDiff(styleOf(preAttach.native), styleOf(enabled.native))
      .every((c) => c.startsWith('fullSizeContentView') || c.startsWith('fullScreenPrimary')),
    { changes: styleDiff(styleOf(preAttach.native), styleOf(enabled.native)) });

  // -- L1: enable → disable → enable, windowed ------------------------------------------------
  let mark = h.corrections().length;
  fullPanel.setEnabled(A, false);
  const disabled = await h.snapshot(A, 'A-windowed-disabled');
  const disableCorrections = h.corrections().slice(mark);
  check('L1.disable', 'Disable (windowed): Disabled, original style, same frame and WindowServer bounds',
    disabled.state.stateName === 'Disabled' && sameStyle(preAttach.native, disabled.native) &&
      sameRect(disabled.electron.bounds, enabled.electron.bounds) && disabled.native.windowServerMatchesFrame &&
      disabled.viewport.innerHeight === enabled.viewport.innerHeight,
    { state: disabled.state.stateName, bounds: disabled.electron.bounds, viewport: disabled.viewport,
      changes: styleDiff(styleOf(preAttach.native), styleOf(disabled.native)) });
  check('L1.correction', `Disable corrected exactly the titlebar growth (${growth} pt), once`,
    disableCorrections.length === 1 && disableCorrections[0].applied &&
      nearly(disableCorrections[0].from.height - disableCorrections[0].to.height, growth),
    { corrections: disableCorrections });
  mark = h.corrections().length;
  fullPanel.setEnabled(A, true);
  const reenabled = await h.snapshot(A, 'A-windowed-reenabled');
  check('L1.reenable', 'Re-enable (windowed): Inactive, enabled style, same frame, no correction',
    reenabled.state.stateName === 'Inactive' && sameStyle(enabled.native, reenabled.native) &&
      sameRect(reenabled.electron.bounds, enabled.electron.bounds) && h.corrections().length === mark,
    { state: reenabled.state.stateName, bounds: reenabled.electron.bounds });

  // -- F1: fullscreen through Electron's API, geometry, pixels, exit ------------------------------
  let windowed = A.getBounds();
  const fs1 = await h.enterFullScreen(A, 'A-fullscreen-1', true);
  check('T1', 'Fullscreen entered with BrowserWindow.setFullScreen(true) (native, not simple)',
    fs1.electron.isFullScreen && !fs1.electron.isSimpleFullScreen && fs1.native.fullScreen, fs1.electron);
  check('T1.state', 'FullPanel state is Active', fs1.state.stateName === 'Active', fs1.state);
  check('T2', 'NSWindow frame covers the whole screen', fs1.native.frameCoversScreen,
    { windowFrame: fs1.native.windowFrame, screenFrame: fs1.native.screenFrame });
  check('T2.baseline', `NSWindow frame is ${BASELINE.width}×${BASELINE.height} (hardware baseline)`,
    nearly(fs1.native.windowFrame.width, BASELINE.width) && nearly(fs1.native.windowFrame.height, BASELINE.height),
    { windowFrame: fs1.native.windowFrame }, { informational: true });
  check('T3', 'WindowServer bounds cover the display', fs1.native.windowServerCoversDisplay,
    { windowServerBounds: fs1.native.windowServerBounds, displayQuartzBounds: fs1.native.displayQuartzBounds });
  check('T4.viewport', 'Renderer viewport equals the native content view (recorded separately)',
    h.viewportMatchesContent(fs1),
    { viewport: fs1.viewport, contentView: { width: fs1.geometry.content.width, height: fs1.geometry.content.height } });
  const pixels = await h.sampleNotchPixels(A, fs1.geometry);
  report.snapshots['A-fullscreen-1-pixels'] = pixels;
  check('T4', 'Chromium rendered the markers in both notch-side regions (capturePage)',
    pixels.left.ok && pixels.right.ok, { left: pixels.left, right: pixels.right, captureSize: pixels.captureSize });
  const out1 = await h.exitFullScreen(A, 'A-exit-1', windowed);
  check('T8', 'Exit restores the windowed frame (native and WindowServer), state Inactive',
    sameRect(out1.electron.bounds, windowed, 1) && out1.native.windowServerMatchesFrame &&
      !out1.native.fullScreen && out1.state.stateName === 'Inactive' && sameStyle(enabled.native, out1.native) &&
      out1.viewport.innerHeight === enabled.viewport.innerHeight,
    { windowed, after: out1.electron.bounds, state: out1.state.stateName, viewport: out1.viewport });

  // -- F2: move and resize before fullscreen; repeated cycles ------------------------------------
  const origin = windowed;
  const layouts = [
    { x: origin.x + 80, y: origin.y + 40, width: 900, height: 600 },
    { x: origin.x + 20, y: origin.y + 10, width: 1120, height: 720 },
    { ...origin },
  ];
  for (const [index, target] of layouts.entries()) {
    const id = `F2.${index + 1}`;
    await h.setWindowed(A, target);
    const before = fullPanel.inspect(A);
    check(`${id}.windowed`, `Moved/resized to ${target.width}×${target.height}: native frame and WindowServer agree`,
      sameRect(A.getBounds(), target, 1) && before.windowServerMatchesFrame,
      { target, bounds: A.getBounds(), windowServerBounds: before.windowServerBounds });
    mark = h.corrections().length;
    const fs = await h.enterFullScreen(A, `A-${id}-fullscreen`, true);
    check(`${id}.fullscreen`, 'Fullscreen: Active, frame covers screen, WindowServer covers display',
      fs.state.stateName === 'Active' && fs.native.frameCoversScreen && fs.native.windowServerCoversDisplay &&
        h.viewportMatchesContent(fs),
      { state: fs.state.stateName, windowFrame: fs.native.windowFrame, windowServerBounds: fs.native.windowServerBounds });
    const out = await h.exitFullScreen(A, `A-${id}-exit`, target);
    check(`${id}.exit`, 'Exit restores the moved/resized frame (native and WindowServer), no correction needed',
      sameRect(out.electron.bounds, target, 1) && out.native.windowServerMatchesFrame &&
        out.state.stateName === 'Inactive' && h.corrections().length === mark,
      { target, after: out.electron.bounds, corrections: h.corrections().slice(mark) });
  }

  // -- F3: disable inside fullscreen ---------------------------------------------------------
  windowed = { x: origin.x + 40, y: origin.y + 30, width: 940, height: 620 };
  await h.setWindowed(A, windowed);
  mark = h.corrections().length;
  const fs3 = await h.enterFullScreen(A, 'A-fullscreen-disable', true);
  fullPanel.setEnabled(A, false);
  const insideDisabled = fullPanel.getState(A);
  const out3 = await h.exitFullScreen(A, 'A-exit-after-disable', windowed);
  const exitCorrections = h.corrections().slice(mark);
  check('F3', 'Disable inside fullscreen: exit restores the moved/resized frame and the original style',
    fs3.state.stateName === 'Active' && insideDisabled.stateName === 'Disabled' &&
      sameRect(out3.electron.bounds, windowed, 1) && out3.native.windowServerMatchesFrame &&
      sameStyle(preAttach.native, out3.native) && out3.state.stateName === 'Disabled',
    { inside: insideDisabled.stateName, windowed, after: out3.electron.bounds, state: out3.state.stateName,
      changes: styleDiff(styleOf(preAttach.native), styleOf(out3.native)) });
  check('F3.correction', 'The exit correction removed exactly the titlebar growth, once',
    exitCorrections.length === 1 && exitCorrections[0].applied &&
      exitCorrections[0].when === 'after fullscreen exit' &&
      nearly(exitCorrections[0].from.height - exitCorrections[0].to.height, growth),
    { corrections: exitCorrections });
  fullPanel.setEnabled(A, true);
  const reenabled3 = await h.snapshot(A, 'A-reenabled-after-fullscreen-disable');
  check('F3.reenable', 'Re-enable after that exit: Inactive, same frame',
    reenabled3.state.stateName === 'Inactive' && sameRect(reenabled3.electron.bounds, windowed, 1),
    { state: reenabled3.state.stateName, bounds: reenabled3.electron.bounds });

  // -- F4: resize, then detach inside fullscreen ----------------------------------------------
  windowed = { ...windowed, width: 980, height: 650 };
  await h.setWindowed(A, windowed);
  const fs4 = await h.enterFullScreen(A, 'A-fullscreen-detach', true);
  const detachedInside = fullPanel.detach(A);
  const out4 = await h.exitFullScreen(A, 'A-exit-after-detach', windowed);
  check('F4', 'Detach inside fullscreen: exit restores the resized frame and the original style',
    fs4.state.stateName === 'Active' && detachedInside.wasAttached && out4.state.stateName === 'NoSession' &&
      sameRect(out4.electron.bounds, windowed, 1) && out4.native.windowServerMatchesFrame &&
      sameStyle(preAttach.native, out4.native),
    { windowed, after: out4.electron.bounds, changes: styleDiff(styleOf(preAttach.native), styleOf(out4.native)) });

  // -- F5: attach inside a fullscreen session that started without FullPanel --------------------
  const fs5 = await h.enterFullScreen(A, 'A-fullscreen-unattached', false);
  check('F5.ordinary', 'Without a session, entry is ordinary fullscreen',
    fs5.native.fullScreen && !fs5.native.frameCoversScreen, { windowFrame: fs5.native.windowFrame });
  const attached5 = fullPanel.attach(A);
  fullPanel.setEnabled(A, true);
  fullPanel.detach(A);
  const out5 = await h.exitFullScreen(A, 'A-exit-attach-detach-inside', windowed);
  check('F5.detach', 'Attach + enable + detach inside fullscreen: exit restores the windowed frame',
    attached5.ok && sameRect(out5.electron.bounds, windowed, 1) && out5.native.windowServerMatchesFrame &&
      sameStyle(preAttach.native, out5.native),
    { windowed, after: out5.electron.bounds, corrections: h.corrections().slice(-2) });
  await h.enterFullScreen(A, 'A-fullscreen-unattached-2', false);
  const attached6 = fullPanel.attach(A);
  fullPanel.setEnabled(A, true);
  const out6 = await h.exitFullScreen(A, 'A-exit-attached-inside', windowed);
  check('F5.exit', 'Attach + enable inside fullscreen: exit restores the windowed frame',
    attached6.ok && sameRect(out6.electron.bounds, windowed, 1) && out6.state.stateName === 'Inactive',
    { windowed, after: out6.electron.bounds, state: out6.state.stateName });
  const fs6 = await h.enterFullScreen(A, 'A-fullscreen-after-attach-inside', true);
  check('F5.next', 'The next entry is FullPanel: Active, whole display',
    fs6.state.stateName === 'Active' && fs6.native.frameCoversScreen && fs6.native.windowServerCoversDisplay,
    { state: fs6.state.stateName, windowFrame: fs6.native.windowFrame });
  const out7 = await h.exitFullScreen(A, 'A-exit-after-attach-inside', windowed);
  check('F5.restore', 'And its exit restores the windowed frame',
    sameRect(out7.electron.bounds, windowed, 1) && out7.native.windowServerMatchesFrame,
    { windowed, after: out7.electron.bounds });

  // -- Window B: unattached control -------------------------------------------------------------
  const bNow = fullPanel.inspect(B);
  check('B.untouched', 'B kept its frame, WindowServer bounds and style through all of A\'s tests',
    sameRect(bNow.windowFrame, bStart.windowFrame) && sameRect(bNow.windowServerBounds, bStart.windowServerBounds) &&
      bNow.windowServerMatchesFrame && sameStyle(bStart, bNow) && !bNow.hasSession,
    { start: bStart.windowFrame, now: bNow.windowFrame, changes: styleDiff(styleOf(bStart), styleOf(bNow)) });
  check('B.class', 'B is the same class as A and has no session',
    bNow.windowClass === fs1.native.windowClass && !bNow.hasSession,
    { windowClass: bNow.windowClass, hasSession: bNow.hasSession });
  const bWindowed = B.getBounds();
  const bfs = await h.enterFullScreen(B, 'B-fullscreen', false);
  const safeTop = bfs.native.screenSafeAreaTop;
  check('B.ordinary', 'B uses ordinary fullscreen below the camera housing (native and WindowServer)',
    bfs.native.fullScreen && !bfs.native.frameCoversScreen && !bfs.native.windowServerCoversDisplay &&
      bfs.native.windowServerMatchesFrame &&
      nearly(bfs.native.windowFrame.height, bfs.native.screenFrame.height - safeTop, 1),
    { windowFrame: bfs.native.windowFrame, windowServerBounds: bfs.native.windowServerBounds, safeTop,
      viewport: bfs.viewport });
  check('B.A', 'A unaffected while B is fullscreen',
    fullPanel.getState(A).stateName === 'Inactive' && sameRect(A.getBounds(), windowed, 1),
    { state: fullPanel.getState(A).stateName, bounds: A.getBounds() });
  const bout = await h.exitFullScreen(B, 'B-exit', bWindowed);
  check('B.exit', 'B exit restores its frame (native and WindowServer); still no session',
    sameRect(bout.electron.bounds, bWindowed, 1) && bout.native.windowServerMatchesFrame &&
      fullPanel.getState(B).stateName === 'NoSession',
    { before: bWindowed, after: bout.electron.bounds });

  // -- Close and cleanup -----------------------------------------------------------------------
  const recordOf = (address) => fullPanel.liveSessions().find((r) => r.windowAddress === address);
  async function attachNew(role) {
    const win = await createWindow(role);
    const result = fullPanel.attach(win);
    fullPanel.setEnabled(win, true);
    return { win, result, handle: win.getNativeWindowHandle(), address: fullPanel.inspect(win).windowAddress };
  }
  // index.js detaches in its own 'closed' listener, registered at attach and
  // so run before this one.
  async function closeAndCheck(entry) {
    const closed = waitForEvent(entry.win, 'closed', 10000);
    entry.win.close();
    await closed;
    return recordOf(entry.address);
  }
  const released = (record) => Boolean(record) && !record.sessionAttached && !record.closeObserverInstalled;
  const rejectsHandle = (handle) => {
    try {
      fullPanel.getState(handle);
      return null;
    } catch (error) {
      return error.code;
    }
  };

  const C = await attachNew('C');
  const cBefore = recordOf(C.address);
  const cAfter = await closeAndCheck(C);
  check('C1.close', 'Closing an attached window detaches its session at Electron\'s \'closed\' event',
    C.result.ok && cBefore && cBefore.sessionAttached && released(cAfter), { cBefore, cAfter });
  let destroyedError = null;
  try {
    fullPanel.getState(C.win);
  } catch (error) {
    destroyedError = String(error.message);
  }
  // AppKit closes the NSWindow shortly after Electron's 'closed' (measured ~14 ms).
  const staleCode = await waitFor(() => rejectsHandle(C.handle), 3000);
  const cClosed = recordOf(C.address);
  check('C1.stale', 'A destroyed BrowserWindow and, once AppKit closed it, its raw handle are rejected',
    /destroyed/.test(destroyedError || '') && staleCode === 'ERR_FULLPANEL_NO_WINDOW' && released(cClosed),
    { destroyedError, staleCode, record: cClosed });

  const D = await attachNew('D');
  const E = await attachNew('E');
  const dAfter = await closeAndCheck(D);
  const eState = fullPanel.getState(E.win);
  const eGeometry = fullPanel.getGeometry(E.win);
  check('C2.independent', 'Closing D leaves E attached and working',
    released(dAfter) && eState.attached && eState.stateName === 'Inactive' && Boolean(eGeometry.content),
    { dAfter, eState });
  const eAfter = await closeAndCheck(E);
  check('C2.second', 'Closing E then releases its own session', released(eAfter), { eAfter });

  const cycles = [];
  for (let i = 0; i < 5; i += 1) {
    const entry = await attachNew(`R${i}`);
    cycles.push({ ok: entry.result.ok, record: await closeAndCheck(entry) });
  }
  check('C3.repeat', 'Five create → attach → enable → close cycles each release their session',
    cycles.every((c) => c.ok && released(c.record)), { cycles });
  const addresses = [C, D, E].map((x) => x.address).concat(cycles.map((c) => c.record && c.record.windowAddress));
  const deallocated = await waitFor(() => addresses.every((a) => !(recordOf(a) || {}).windowAlive), 5000);
  check('C3.dealloc', 'Closed NSWindows deallocated (Electron lifecycle)', deallocated,
    { alive: addresses.filter((a) => (recordOf(a) || {}).windowAlive) }, { informational: true });
  check('C3.A', 'Window A is still attached after the other windows closed',
    fullPanel.getState(A).attached && fullPanel.getState(A).stateName === 'Inactive');

  // -- Application shutdown with a session attached (separate processes) -----------------------
  for (const variant of ['windowed', 'fullscreen']) {
    const run = await runShutdownChild(variant);
    report.snapshots[`shutdown-${variant}`] = run;
    const sessions = (run.result && run.result.sessions) || [];
    check(`S1.${variant}`, `Quit with an attached ${variant} window: clean exit, session detached when Electron closed the window`,
      run.code === 0 && !run.signal && run.result && run.result.attachedBeforeQuit &&
        (variant !== 'fullscreen' || run.result.stateBeforeQuit === 'Active') &&
        sessions.length === 1 && sessions.every(released) && run.result.detachedBeforeWillQuit &&
        run.result.windowsOpen === 0,
      { code: run.code, signal: run.signal, result: run.result, tail: run.result ? undefined : run.tail });
  }
}

module.exports = { bridgeChecks, runAutotest, waitFor, waitForEvent, sameRect };
