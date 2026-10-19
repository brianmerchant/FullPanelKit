// FullPanelKit Electron test app.
//
//   electron test-app/main.js                   interactive hardware test
//   electron test-app/main.js --bridge-check    Phase 1 bridge checks only
//   electron test-app/main.js --autotest        bridge + automated regression suite
//   electron test-app/main.js --shutdown-check [--fullscreen]
//                                               quits with a session attached (run by --autotest)
//
// Window A: BrowserWindow, titleBarStyle 'hidden', FullPanel session enabled.
// Window B: ordinary BrowserWindow, no session (control).
// Mission Control and physical clicks are never simulated. Manual steps record
// the tester's verdict together with the pointer events and window-state
// changes observed while the step was armed.
'use strict';

const { app, BrowserWindow, ipcMain, screen } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const fullPanel = require('..');
const { bridgeChecks, runAutotest, waitFor, waitForEvent } = require('./autotest');

const MODE = process.argv.includes('--bridge-check') ? 'bridge-check'
  : process.argv.includes('--autotest') ? 'autotest'
    : process.argv.includes('--shutdown-check') ? 'shutdown-check' : 'interactive';

// kind 'pointer': passes on evidence only with a trusted pointerdown in each
// region while FullPanel is Active and covers the display. `away`: the step is
// about a Mission Control return; pointer evidence must come after it.
const MANUAL_STEPS = [
  { id: 'notch-pixels-visible', label: 'Magenta (left) and cyan (right) are visible beside the notch' },
  { id: 'pointer-left', label: 'Click left of the notch', regions: ['auxiliaryLeftArea'] },
  { id: 'pointer-right', label: 'Click right of the notch', regions: ['auxiliaryRightArea'] },
  { id: 'mc-thumbnail-return', label: 'Mission Control → small Space thumbnail: back to Active, whole display', away: true },
  { id: 'mc-window-thumbnail-return', label: 'Mission Control → large window thumbnail: back to Active, whole display', away: true },
  { id: 'mc-swipe-return', label: 'Mission Control opened and closed by swipe: back to Active, whole display', away: true },
  { id: 'post-mc-pointer', label: 'After a Mission Control return: click left AND right of the notch',
    regions: ['auxiliaryLeftArea', 'auxiliaryRightArea'], away: true },
  { id: 'exit-restore',
    label: 'Exit fullscreen restores the original frame and traffic lights; the titlebar stays hidden' },
  { id: 'opt-resize-before', label: 'Optional: resize, then fullscreen and exit: size restored', optional: true },
  { id: 'opt-move-before', label: 'Optional: move, then fullscreen and exit: position restored', optional: true },
  { id: 'opt-disable-reenable', label: 'Optional: Disable → fullscreen is ordinary (1130); Enable → whole display again',
    optional: true },
  { id: 'opt-repeated-cycles', label: 'Optional: three fullscreen cycles in a row stay Active', optional: true },
  { id: 'opt-display-switch', label: 'Optional (external display): Fallback there, Active again on the built-in display',
    optional: true },
];

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const reportPath = path.join(__dirname, 'reports', `${MODE}-${stamp}.json`);
const report = {
  mode: MODE,
  startedAt: new Date().toISOString(),
  versions: {
    electron: process.versions.electron,
    node: process.versions.node,
    napi: process.versions.napi,
    chrome: process.versions.chrome,
  },
  addon: null,
  checks: [],
  manualTests: [],
  manualVerdicts: [],
  pointerEvents: [],
  timeline: [],
  snapshots: {},
  events: [],
};
const windows = {};
const armedSteps = {};
const verdicts = {};

function check(id, name, pass, detail = {}, { informational = false } = {}) {
  report.checks.push({ id, name, pass: Boolean(pass), informational, detail });
  const label = pass ? 'PASS' : informational ? 'INFO' : 'FAIL';
  console.log(`${label}  ${id}  ${name}`);
  if (!pass) console.log(`      ${JSON.stringify(detail)}`);
  return Boolean(pass);
}

function logEvent(name, detail = {}) {
  report.events.push({ at: new Date().toISOString(), name, detail });
}

function writeReport() {
  if (MODE === 'shutdown-check') return null;
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  report.writtenAt = new Date().toISOString();
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  return reportPath;
}

// ---- Windows -------------------------------------------------------------------

function createWindow(role) {
  const display = screen.getAllDisplays().find((d) => d.internal) || screen.getPrimaryDisplay();
  const area = display.workArea;
  const geometry = role === 'B'
    ? { x: area.x + area.width - 700, y: area.y + 140, width: 640, height: 460 }
    : { x: area.x + (role === 'A' ? 60 : 200), y: area.y + 60, width: 1000, height: 680 };
  const win = new BrowserWindow({
    ...geometry,
    ...(role === 'B' ? {} : { titleBarStyle: 'hidden' }),
    title: `FullPanelKit Electron — ${role}`,
    backgroundColor: role === 'B' ? '#2a2a2a' : '#15171c',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  windows[role] = win;
  win.on('closed', () => {
    if (windows[role] === win) delete windows[role];
  });
  const loaded = waitForEvent(win.webContents, 'did-finish-load', 15000);
  win.loadFile(path.join(__dirname, 'index.html'), { query: { role } });
  return loaded.then(() => win);
}

function roleOf(webContents) {
  return Object.keys(windows).find((role) => windows[role].webContents === webContents);
}

function liveFacts(win) {
  return {
    native: fullPanel.inspect(win),
    state: fullPanel.getState(win),
    geometry: fullPanel.getGeometry(win),
  };
}

// ---- Window-state timeline and manual evidence (window A) ----------------------------

const TIMELINE_KEYS = ['fullScreen', 'onActiveSpace', 'occlusionVisible', 'isKey', 'windowServerMatchesFrame',
  'frameCoversScreen', 'windowServerCoversDisplay'];
let lastTimelineKey = '';

function recordTimeline(facts, event) {
  const entry = { atMs: Date.now(), at: new Date().toISOString(), state: facts.state.stateName };
  for (const key of TIMELINE_KEYS) entry[key] = facts.native[key];
  if (event) entry.event = event;
  const key = JSON.stringify({ ...entry, atMs: 0, at: 0 });
  if (!event && key === lastTimelineKey) return;
  lastTimelineKey = key;
  report.timeline.push(entry);
}

// Away from the fullscreen Space (Mission Control open): AppKit no longer
// reports the window on the active Space, visible or key, the window was
// blurred, or WindowServer shows it at another size than its frame (the
// Mission Control thumbnail).
const isAway = (t) => t.fullScreen && (t.event === 'blur' || !t.onActiveSpace || !t.occlusionVisible ||
  !t.isKey || !t.windowServerMatchesFrame);
const isPresent = (t) => !t.event && t.fullScreen && t.onActiveSpace && t.occlusionVisible &&
  t.windowServerMatchesFrame && t.state === 'Active' && t.frameCoversScreen && t.windowServerCoversDisplay;
const qualifies = (p, region) => p.isTrusted && p.region === region && p.state === 'Active' && p.fullScreen &&
  p.frameCoversScreen && p.windowServerCoversDisplay;

function evidenceFor(step) {
  const armed = armedSteps[step.id];
  if (!armed) return { armed: false, satisfied: false };
  const timeline = report.timeline.filter((t) => t.atMs >= armed.atMs);
  const pointers = report.pointerEvents.filter((p) => p.role === 'A' && p.atMs >= armed.atMs);
  const away = timeline.find(isAway);
  const back = away && timeline.find((t) => t.atMs >= away.atMs && isPresent(t));
  const evidence = {
    armed: true,
    armedAt: armed.at,
    awayObserved: Boolean(away),
    awaySignals: away ? Object.keys(away).filter((k) => TIMELINE_KEYS.includes(k) && away[k] === false)
      .concat(away.event ? [away.event] : []) : [],
    returnObserved: Boolean(back),
    returnedAt: back ? back.at : null,
    pointerEventsSinceArmed: pointers.length,
    satisfied: null,
  };
  if (step.regions) {
    evidence.regions = {};
    for (const region of step.regions) {
      evidence.regions[region] = pointers.find((p) => qualifies(p, region) &&
        (!step.away || (back && p.atMs > back.atMs))) || null;
    }
    evidence.satisfied = step.regions.every((r) => evidence.regions[r]) && (!step.away || evidence.returnObserved);
  } else if (step.away) {
    evidence.satisfied = evidence.awayObserved && evidence.returnObserved;
  }
  return evidence;
}

function manualStatus() {
  const status = {};
  for (const step of MANUAL_STEPS) {
    const evidence = evidenceFor(step);
    const parts = [];
    if (verdicts[step.id]) parts.push(verdicts[step.id].toUpperCase());
    if (evidence.armed) {
      if (step.away) parts.push(`Mission Control away ${evidence.awayObserved ? '✓' : '—'} return ${evidence.returnObserved ? '✓' : '—'}`);
      for (const region of step.regions || []) {
        const p = evidence.regions[region];
        parts.push(`${region === 'auxiliaryLeftArea' ? 'left' : 'right'} ${p ? `✓ (${Math.round(p.clientX)},${Math.round(p.clientY)})` : '—'}`);
      }
      if (evidence.satisfied === false && verdicts[step.id] === 'pass') parts.push('evidence missing');
    } else {
      parts.push('not started');
    }
    status[step.id] = { armed: evidence.armed, satisfied: evidence.satisfied, text: parts.join('  ') };
  }
  return status;
}

function pushUpdates() {
  for (const [role, win] of Object.entries(windows)) {
    if (win.isDestroyed()) continue;
    try {
      const facts = liveFacts(win);
      if (role === 'A') recordTimeline(facts);
      win.webContents.send('fullpanel:update', {
        role, ...facts, manual: role === 'A' && MODE === 'interactive' ? manualStatus() : null,
      });
    } catch (error) {
      logEvent('update-failed', { role, error: String(error) });
    }
  }
}

// ---- IPC (test pages) ------------------------------------------------------------------

ipcMain.handle('fullpanel:manual-steps', () => MANUAL_STEPS);

ipcMain.handle('fullpanel:command', async (event, command) => {
  const role = roleOf(event.sender);
  const win = role && windows[role];
  if (!win) return { ok: false };
  logEvent('command', { role, command });
  switch (command) {
    case 'enter': win.setFullScreen(true); return { ok: true };
    case 'exit': win.setFullScreen(false); return { ok: true };
    case 'detach': return role === 'A' ? fullPanel.detach(win) : { ok: false };
    case 'attach': {
      if (role !== 'A') return { ok: false };
      const result = fullPanel.attach(win);
      if (result.ok) fullPanel.setEnabled(win, true);
      return result;
    }
    case 'disable': return role === 'A' ? fullPanel.setEnabled(win, false) : { ok: false };
    case 'enable': return role === 'A' ? fullPanel.setEnabled(win, true) : { ok: false };
    case 'save': return { ok: true, path: writeReport() };
    default: return { ok: false };
  }
});

ipcMain.on('fullpanel:pointer', (event, pointer) => {
  const role = roleOf(event.sender);
  if (!role) return;
  const facts = liveFacts(windows[role]);
  const entry = {
    atMs: Date.now(),
    at: new Date().toISOString(),
    role,
    ...pointer,
    state: facts.state.stateName,
    fullScreen: facts.native.fullScreen,
    frameCoversScreen: facts.native.frameCoversScreen,
    windowServerCoversDisplay: facts.native.windowServerCoversDisplay,
    windowFrame: facts.native.windowFrame,
    windowServerBounds: facts.native.windowServerBounds,
  };
  report.pointerEvents.push(entry);
  console.log(`pointer ${role} ${pointer.region} client ${pointer.clientX},${pointer.clientY} ` +
    `trusted=${pointer.isTrusted} state=${entry.state} fullscreen=${entry.fullScreen}`);
});

ipcMain.on('fullpanel:manual-arm', (event, { test }) => {
  const role = roleOf(event.sender);
  const step = MANUAL_STEPS.find((s) => s.id === test);
  if (role !== 'A' || !step) return;
  const facts = liveFacts(windows.A);
  armedSteps[step.id] = { atMs: Date.now(), at: new Date().toISOString(), state: facts.state.stateName,
    windowFrame: facts.native.windowFrame };
  delete verdicts[step.id];
  recordTimeline(facts, 'start');
  logEvent('manual-arm', { test });
  console.log(`manual ${test}: started`);
});

ipcMain.on('fullpanel:verdict', (event, { test, verdict }) => {
  const role = roleOf(event.sender);
  const step = MANUAL_STEPS.find((s) => s.id === test);
  if (role !== 'A' || !step || !['pass', 'fail'].includes(verdict)) return;
  const facts = liveFacts(windows.A);
  recordTimeline(facts, 'verdict');
  const evidence = evidenceFor(step);
  verdicts[step.id] = verdict;
  report.manualVerdicts.push({
    at: new Date().toISOString(), test, label: step.label, optional: Boolean(step.optional), verdict,
    evidence: {
      ...evidence,
      armedState: armedSteps[step.id] || null,
      pointerEvents: report.pointerEvents.filter((p) => armedSteps[step.id] && p.atMs >= armedSteps[step.id].atMs),
      timeline: report.timeline.filter((t) => armedSteps[step.id] && t.atMs >= armedSteps[step.id].atMs),
    },
    atVerdict: {
      state: facts.state, windowFrame: facts.native.windowFrame, screenName: facts.native.screenName,
      windowServerBounds: facts.native.windowServerBounds,
      windowServerCoversDisplay: facts.native.windowServerCoversDisplay,
      frameCoversScreen: facts.native.frameCoversScreen,
    },
  });
  console.log(`manual ${test}: ${verdict.toUpperCase()} (tester)` +
    (evidence.satisfied === null ? '' : `, evidence ${evidence.satisfied ? 'satisfied' : 'MISSING'}`));
  writeReport();
});

// ---- Modes -------------------------------------------------------------------------------

async function shutdownCheck() {
  await createWindow('A');
  await createWindow('B');
  const A = windows.A;
  fullPanel.attach(A);
  fullPanel.setEnabled(A, true);
  if (process.argv.includes('--fullscreen')) {
    const entered = waitForEvent(A, 'enter-full-screen', 15000);
    A.setFullScreen(true);
    await entered;
    await waitFor(() => fullPanel.getState(A).stateName === 'Active', 5000);
  }
  const before = fullPanel.getState(A);
  let detachedBeforeWillQuit = false;
  A.once('closed', () => {
    // index.js's own 'closed' listener (registered at attach) has run.
    detachedBeforeWillQuit = fullPanel.liveSessions().every((r) => !r.sessionAttached);
  });
  // Emitted after Electron has closed every window.
  app.on('will-quit', () => {
    const result = {
      attachedBeforeQuit: before.attached,
      stateBeforeQuit: before.stateName,
      detachedBeforeWillQuit,
      sessions: fullPanel.liveSessions(),
      windowsOpen: BrowserWindow.getAllWindows().length,
    };
    process.stdout.write(`FULLPANEL_SHUTDOWN ${JSON.stringify(result)}\n`);
  });
  app.quit();
}

async function interactive() {
  report.addon = fullPanel.addonInfo();
  report.manualSteps = MANUAL_STEPS;
  const attached = fullPanel.attach(windows.A);
  const enabled = attached.ok ? fullPanel.setEnabled(windows.A, true) : null;
  logEvent('attach-A', { attached, enabled });
  console.log(`Window A: ${attached.ok ? `attached (${attached.windowClass}), enabled` : attached.message}`);
  console.log(`Report: ${reportPath}`);
  for (const name of ['blur', 'focus', 'enter-full-screen', 'leave-full-screen']) {
    windows.A.on(name, () => {
      if (windows.A && !windows.A.isDestroyed()) recordTimeline(liveFacts(windows.A), name);
    });
  }
  // before-quit runs while the windows still exist (their sessions are still
  // attached); will-quit runs after Electron closed them.
  app.on('before-quit', () => {
    report.liveSessionsBeforeQuit = fullPanel.liveSessions();
    writeReport();
  });
  app.on('will-quit', () => {
    report.liveSessionsAfterWindowsClosed = fullPanel.liveSessions();
    writeReport();
  });
  app.on('window-all-closed', () => app.quit());
}

async function automated() {
  let exitCode = 0;
  try {
    if (!bridgeChecks({ fullPanel, windows, check, report })) {
      console.log('Bridge check failed: not continuing with FullPanel integration.');
      exitCode = 1;
    } else if (MODE === 'autotest') {
      await runAutotest({ fullPanel, windows, check, report, createWindow, pushUpdates });
    }
  } catch (error) {
    check('crash', 'Test run completed without an exception', false,
      { error: String(error), stack: error.stack });
  }
  for (const step of MANUAL_STEPS) {
    report.manualTests.push({ id: step.id, name: step.label, optional: Boolean(step.optional),
      status: 'NOT RUN (manual hardware test)' });
  }
  for (const win of Object.values(windows)) {
    try {
      if (fullPanel.getState(win).attached) fullPanel.detach(win);
    } catch {
      // The window may already be gone.
    }
  }
  report.liveSessionsAtEnd = fullPanel.liveSessions();
  report.frameCorrections = fullPanel.addonInfo().frameCorrections;
  const required = report.checks.filter((c) => !c.informational);
  const informational = report.checks.filter((c) => c.informational);
  const failed = required.filter((c) => !c.pass);
  if (failed.length) exitCode = 1;
  console.log(`\n${required.length - failed.length}/${required.length} automated checks passed;` +
    ` informational ${informational.filter((c) => c.pass).length}/${informational.length}.`);
  if (failed.length) console.log(`Failed: ${failed.map((c) => c.id).join(', ')}`);
  console.log(`Manual steps not run here: ${MANUAL_STEPS.length} (${MANUAL_STEPS.filter((s) => s.optional).length} optional)`);
  console.log(`Report: ${writeReport()}`);
  app.exit(exitCode);
}

async function main() {
  await app.whenReady();
  if (MODE === 'shutdown-check') {
    await shutdownCheck();
    return;
  }
  await Promise.all([createWindow('A'), createWindow('B')]);
  setInterval(pushUpdates, 250);
  if (MODE === 'interactive') {
    await interactive();
  } else {
    await automated();
  }
}

main();
