// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// FullPanelKit for Electron (main process only).
//
//   const fullPanel = require('fullpanelkit-electron');
//   fullPanel.attach(win);            // or win.getNativeWindowHandle()
//   fullPanel.setEnabled(win, true);  // before the window enters fullscreen
//   win.setFullScreen(true);          // native fullscreen, not simpleFullScreen
//
// Every function takes a BrowserWindow/BaseWindow or the Buffer returned by
// getNativeWindowHandle(). The native side resolves the handle against the
// application's live windows and throws for a closed or unknown window.
'use strict';

const path = require('node:path');

if (process.platform !== 'darwin') {
  throw new Error('fullpanelkit-electron: macOS only');
}
if (process.type !== 'browser') {
  throw new Error('fullpanelkit-electron: load it in the Electron main process');
}

const native = require(path.join(__dirname, 'build', 'Release', 'fullpanel_electron.node'));

function handleOf(target) {
  if (Buffer.isBuffer(target)) return target;
  if (target && typeof target.getNativeWindowHandle === 'function') {
    if (typeof target.isDestroyed === 'function' && target.isDestroyed()) {
      throw new Error('fullpanelkit-electron: the window is destroyed');
    }
    return target.getNativeWindowHandle();
  }
  throw new TypeError(
    'fullpanelkit-electron: expected a BrowserWindow or the Buffer from getNativeWindowHandle()');
}

// Electron emits 'closed' before AppKit closes the NSWindow, and when the app
// quits AppKit does not close it at all before the process exits. Detaching
// on 'closed' runs FullPanelKit's restore in both cases. The native
// NSWindowWillClose observer remains for callers that pass raw handles.
const detachOnClosed = new WeakSet();

function attach(window) {
  const handle = handleOf(window);
  const result = native.attach(handle);
  if (result.ok && !Buffer.isBuffer(window) && typeof window.once === 'function' &&
      !detachOnClosed.has(window)) {
    detachOnClosed.add(window);
    window.once('closed', () => {
      try {
        native.detach(handle);
      } catch {
        // AppKit already closed the window; its observer detached the session.
      }
    });
  }
  return result;
}

module.exports = {
  /** Addon build/runtime facts (Node-API version, image paths, main thread). */
  addonInfo: () => native.addonInfo(),
  /** Resolves the handle and reports the NSWindow's classes. Never attaches. */
  inspect: (window) => native.inspect(handleOf(window)),
  /**
   * Attaches a FullPanelSession (disabled). Returns { ok, ... } or { ok: false, code, message }.
   * Given a BrowserWindow, the session is detached when the window emits 'closed'.
   */
  attach,
  /** Opts the attached window in or out. Enable before entering fullscreen. */
  setEnabled: (window, enabled) => native.setEnabled(handleOf(window), Boolean(enabled)),
  getState: (window) => native.getState(handleOf(window)),
  /** Camera-housing geometry in screen and content-view (top-left) coordinates. */
  getGeometry: (window) => native.getGeometry(handleOf(window)),
  getDiagnostics: (window) => native.getDiagnostics(handleOf(window)),
  /** Restores the window and removes the session. Closing the window does this too. */
  detach: (window) => native.detach(handleOf(window)),
  /** Every window this addon attached, for cleanup checks. */
  liveSessions: () => native.liveSessions(),
};
