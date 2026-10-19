// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

//! FullPanelKit for Tauri 2 windows on macOS: native fullscreen that covers the
//! whole display, including the areas beside the MacBook camera housing.
//!
//! This is the FullPanelKit engine and its `FullPanelSession` API, compiled
//! unchanged from `Sources/FullPanelKitCore` and reached through a small C-ABI
//! bridge (`src/fullpanel_tauri.m`).
//!
//! ```ignore
//! fullpanelkit_tauri::attach(&window)?;
//! fullpanelkit_tauri::set_enabled(&window, true)?;  // before entering fullscreen
//! window.set_fullscreen(true)?;                      // native fullscreen Space
//! ```
//!
//! Every function may be called from any thread. The work runs on the macOS main
//! thread: inline when already there, otherwise through the window's
//! `run_on_main_thread`, waiting for the result. Results are JSON objects from
//! the bridge; `Err` carries the bridge's error `code` and `message`.

#![cfg(target_os = "macos")]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::fmt;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::Value;
use tauri::{AppHandle, Runtime, WebviewWindow, Window};

mod ffi {
    use std::ffi::{c_char, c_int, c_void};
    extern "C" {
        pub fn fpt_is_main_thread() -> c_int;
        pub fn fpt_free(json: *mut c_char);
        pub fn fpt_info() -> *mut c_char;
        pub fn fpt_attach(ns_window: *const c_void) -> *mut c_char;
        pub fn fpt_set_enabled(ns_window: *const c_void, enabled: c_int) -> *mut c_char;
        pub fn fpt_detach(ns_window: *const c_void) -> *mut c_char;
        pub fn fpt_state(ns_window: *const c_void) -> *mut c_char;
        pub fn fpt_diagnostics(ns_window: *const c_void) -> *mut c_char;
    }
}

/// How long a call from another thread waits for the main thread.
const MAIN_THREAD_TIMEOUT: Duration = Duration::from_secs(10);

/// A failed call: the bridge's error `code` (for example `ERR_FULLPANEL_ATTACH`
/// or `ERR_FULLPANEL_NO_WINDOW`), its message, and the full result object.
#[derive(Debug, Clone)]
pub struct Error {
    pub code: String,
    pub message: String,
    pub details: Value,
}

impl Error {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into(), details: Value::Null }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "fullpanelkit-tauri: {}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

type MainThreadJob = Box<dyn FnOnce() + Send + 'static>;

/// A Tauri window FullPanelKit can attach to: `tauri::Window` or
/// `tauri::WebviewWindow`.
pub trait NativeWindow: Clone + Send + 'static {
    #[doc(hidden)]
    fn fpt_ns_window(&self) -> tauri::Result<*mut c_void>;
    #[doc(hidden)]
    fn fpt_run_on_main_thread(&self, job: MainThreadJob) -> tauri::Result<()>;
}

impl<R: Runtime> NativeWindow for Window<R> {
    fn fpt_ns_window(&self) -> tauri::Result<*mut c_void> {
        self.ns_window()
    }
    fn fpt_run_on_main_thread(&self, job: MainThreadJob) -> tauri::Result<()> {
        self.run_on_main_thread(job)
    }
}

impl<R: Runtime> NativeWindow for WebviewWindow<R> {
    fn fpt_ns_window(&self) -> tauri::Result<*mut c_void> {
        self.ns_window()
    }
    fn fpt_run_on_main_thread(&self, job: MainThreadJob) -> tauri::Result<()> {
        self.run_on_main_thread(job)
    }
}

/// Attaches FullPanelKit to the window, or returns its existing session. The
/// session starts disabled.
pub fn attach<W: NativeWindow>(window: &W) -> Result<Value> {
    call(window, |ns_window| unsafe { ffi::fpt_attach(ns_window) })
}

/// Opt the attached window in or out. Enable before entering fullscreen; while
/// in fullscreen, disabling restores the menu bar at once and the window style
/// when fullscreen exits.
pub fn set_enabled<W: NativeWindow>(window: &W, enabled: bool) -> Result<Value> {
    call(window, move |ns_window| unsafe { ffi::fpt_set_enabled(ns_window, enabled as c_int) })
}

/// Detaches FullPanelKit: restores the menu bar, presentation options and
/// window style, and removes every observer. Idempotent. Also done
/// automatically when the window closes.
pub fn detach<W: NativeWindow>(window: &W) -> Result<Value> {
    call(window, |ns_window| unsafe { ffi::fpt_detach(ns_window) })
}

/// Session state (`attached`, `enabled`, `stateName`: `NoSession`, `Disabled`,
/// `Inactive`, `Active` or `Fallback`) and the display geometry, including the
/// notch-side areas in the window's top-left coordinates (`leftInWindow`,
/// `rightInWindow`).
pub fn state<W: NativeWindow>(window: &W) -> Result<Value> {
    call(window, |ns_window| unsafe { ffi::fpt_state(ns_window) })
}

/// `state` plus native window facts (classes, style, frame, WindowServer
/// bounds, WKWebView frame) and FullPanelSession's own diagnostics.
pub fn diagnostics<W: NativeWindow>(window: &W) -> Result<Value> {
    call(window, |ns_window| unsafe { ffi::fpt_diagnostics(ns_window) })
}

/// Bridge facts and the weakly tracked attachments (`liveSessions`, `records`).
pub fn bridge_info<R: Runtime>(app: &AppHandle<R>) -> Result<Value> {
    let app_handle = app.clone();
    on_main_thread(move |job| app_handle.run_on_main_thread(job), || {
        parse(unsafe { ffi::fpt_info() })
    })
}

fn call<W, F>(window: &W, bridge: F) -> Result<Value>
where
    W: NativeWindow,
    F: FnOnce(*const c_void) -> *mut c_char + Send + 'static,
{
    let target = window.clone();
    let runner = window.clone();
    on_main_thread(move |job| runner.fpt_run_on_main_thread(job), move || {
        // Tauri returns the NSWindow (autoreleased) of a live window, or an
        // error for a closed one. The bridge still checks it against NSApp.windows.
        let ns_window = target
            .fpt_ns_window()
            .map_err(|e| Error::new("ERR_FULLPANEL_NO_WINDOW", e.to_string()))?;
        parse(bridge(ns_window))
    })
}

fn on_main_thread<T, S, J>(schedule: S, job: J) -> Result<T>
where
    T: Send + 'static,
    S: FnOnce(MainThreadJob) -> tauri::Result<()>,
    J: FnOnce() -> Result<T> + Send + 'static,
{
    if unsafe { ffi::fpt_is_main_thread() } != 0 {
        return job();
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    schedule(Box::new(move || {
        let _ = sender.send(job());
    }))
    .map_err(|e| Error::new("ERR_FULLPANEL_MAIN_THREAD", e.to_string()))?;
    receiver
        .recv_timeout(MAIN_THREAD_TIMEOUT)
        .map_err(|e| Error::new("ERR_FULLPANEL_MAIN_THREAD", format!("main thread did not run the call: {e}")))?
}

fn parse(json: *mut c_char) -> Result<Value> {
    if json.is_null() {
        return Err(Error::new("ERR_FULLPANEL_BRIDGE", "bridge returned no result"));
    }
    let text = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
    unsafe { ffi::fpt_free(json) };
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| Error::new("ERR_FULLPANEL_BRIDGE", format!("invalid bridge JSON: {e}")))?;
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(value);
    }
    let field = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    Err(Error { code: field("code"), message: field("message"), details: value })
}
