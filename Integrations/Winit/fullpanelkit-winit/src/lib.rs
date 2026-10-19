// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

//! FullPanelKit for winit windows on macOS: native fullscreen that covers the
//! whole display, including the areas beside the MacBook camera housing.
//!
//! This is the FullPanelKit engine and its `FullPanelSession` API, compiled
//! unchanged from `Sources/FullPanelKitCore` and reached through a small C-ABI
//! bridge (`src/fullpanel_winit.m`).
//!
//! ```ignore
//! fullpanelkit_winit::attach(&window)?;
//! fullpanelkit_winit::set_enabled(&window, true)?;            // before entering fullscreen
//! window.set_fullscreen(Some(Fullscreen::Borderless(None)));  // native fullscreen Space
//! ```
//!
//! Every function takes anything that implements raw-window-handle 0.6's
//! `HasWindowHandle` with an AppKit handle, such as `winit::window::Window`
//! (0.30). The bridge resolves the handle's `NSView` to its owning `NSWindow`.
//!
//! Main thread only: call from winit's `ApplicationHandler` methods, which run
//! on the macOS main thread. Elsewhere every call returns
//! `ERR_FULLPANEL_THREAD` without touching AppKit. Results are JSON objects
//! from the bridge; `Err` carries the bridge's error `code` and `message`.

#![cfg(target_os = "macos")]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::fmt;

use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde_json::Value;

mod ffi {
    use std::ffi::{c_char, c_int, c_void};
    extern "C" {
        pub fn fpw_is_main_thread() -> c_int;
        pub fn fpw_free(json: *mut c_char);
        pub fn fpw_info() -> *mut c_char;
        pub fn fpw_attach(ns_view: *const c_void) -> *mut c_char;
        pub fn fpw_set_enabled(ns_view: *const c_void, enabled: c_int) -> *mut c_char;
        pub fn fpw_detach(ns_view: *const c_void) -> *mut c_char;
        pub fn fpw_state(ns_view: *const c_void) -> *mut c_char;
        pub fn fpw_diagnostics(ns_view: *const c_void) -> *mut c_char;
        pub fn fpw_test_click(ns_view: *const c_void, x: f64, y: f64, post: c_int) -> *mut c_char;
    }
}

/// A failed call: the bridge's error `code` (for example `ERR_FULLPANEL_ATTACH`,
/// `ERR_FULLPANEL_NO_WINDOW` or `ERR_FULLPANEL_THREAD`), its message, and the
/// full result object.
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
        write!(f, "fullpanelkit-winit: {}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// A rectangle in the window's top-left coordinates, in points (winit's
/// logical pixels).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            x: value["x"].as_f64()?,
            y: value["y"].as_f64()?,
            width: value["width"].as_f64()?,
            height: value["height"].as_f64()?,
        })
    }

    /// Scales to physical pixels, for example by `Window::scale_factor()`.
    pub fn to_physical(self, scale_factor: f64) -> Self {
        Self {
            x: self.x * scale_factor,
            y: self.y * scale_factor,
            width: self.width * scale_factor,
            height: self.height * scale_factor,
        }
    }

    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.width && y < self.y + self.height
    }
}

/// The areas beside the camera housing, relative to the window. They lie inside
/// the window only while the session is `Active`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NotchRegions {
    pub left: Rect,
    pub right: Rect,
    pub housing: Rect,
    /// `NSWindow.backingScaleFactor`.
    pub scale_factor: f64,
    /// `FullPanelSession.isActive`.
    pub active: bool,
}

/// Attaches FullPanelKit to the window, or returns its existing session. The
/// session starts disabled.
pub fn attach<W: HasWindowHandle + ?Sized>(window: &W) -> Result<Value> {
    call(window, |view| unsafe { ffi::fpw_attach(view) })
}

/// Opt the attached window in or out. Enable before entering fullscreen; while
/// in fullscreen, disabling restores the menu bar at once and the window style
/// when fullscreen exits.
pub fn set_enabled<W: HasWindowHandle + ?Sized>(window: &W, enabled: bool) -> Result<Value> {
    call(window, |view| unsafe { ffi::fpw_set_enabled(view, enabled as c_int) })
}

/// Detaches FullPanelKit: restores the menu bar, presentation options and
/// window style, and removes every observer. Idempotent. Also done
/// automatically when the window closes (when winit's `Window` is dropped).
pub fn detach<W: HasWindowHandle + ?Sized>(window: &W) -> Result<Value> {
    call(window, |view| unsafe { ffi::fpw_detach(view) })
}

/// Session state (`attached`, `enabled`, `stateName`: `NoSession`, `Disabled`,
/// `Inactive`, `Active` or `Fallback`) and the display geometry, including the
/// notch-side areas in the window's top-left coordinates (`leftInWindow`,
/// `rightInWindow`).
pub fn state<W: HasWindowHandle + ?Sized>(window: &W) -> Result<Value> {
    call(window, |view| unsafe { ffi::fpw_state(view) })
}

/// `state` plus native window facts (classes, style, frame, WindowServer
/// bounds, content view and layer frames) and FullPanelSession's own
/// diagnostics.
pub fn diagnostics<W: HasWindowHandle + ?Sized>(window: &W) -> Result<Value> {
    call(window, |view| unsafe { ffi::fpw_diagnostics(view) })
}

/// The notch-side areas of the window's screen, or `None` when the screen has
/// no camera housing (or the window has no screen).
pub fn notch_regions<W: HasWindowHandle + ?Sized>(window: &W) -> Result<Option<NotchRegions>> {
    let value = state(window)?;
    let geometry = &value["geometry"];
    if geometry["hasAuxiliaryAreas"].as_bool() != Some(true) {
        return Ok(None);
    }
    let (Some(left), Some(right)) =
        (Rect::from_json(&geometry["leftInWindow"]), Rect::from_json(&geometry["rightInWindow"]))
    else {
        return Ok(None);
    };
    Ok(Some(NotchRegions {
        left,
        right,
        housing: Rect::from_json(&geometry["housingInWindow"]).unwrap_or_default(),
        scale_factor: geometry["backingScaleFactor"].as_f64().unwrap_or(1.0),
        active: value["state"]["active"].as_bool() == Some(true),
    }))
}

/// Bridge facts and the weakly tracked attachments (`liveSessions`, `records`).
pub fn bridge_info() -> Result<Value> {
    require_main_thread()?;
    parse(unsafe { ffi::fpw_info() })
}

/// Test support for the development app's automated suite; not part of the
/// supported API.
#[doc(hidden)]
pub mod testing {
    use super::*;

    /// Hit-tests the window at (`x`, `y`) in top-left points and, if `post`,
    /// posts a synthetic left click there to the application's event queue.
    pub fn click<W: HasWindowHandle + ?Sized>(window: &W, x: f64, y: f64, post: bool) -> Result<Value> {
        call(window, |view| unsafe { ffi::fpw_test_click(view, x, y, post as c_int) })
    }
}

fn require_main_thread() -> Result<()> {
    if unsafe { ffi::fpw_is_main_thread() } != 0 {
        Ok(())
    } else {
        Err(Error::new("ERR_FULLPANEL_THREAD", "must be called on the macOS main thread"))
    }
}

fn call<W, F>(window: &W, bridge: F) -> Result<Value>
where
    W: HasWindowHandle + ?Sized,
    F: FnOnce(*const c_void) -> *mut c_char,
{
    require_main_thread()?;
    let handle = window.window_handle().map_err(|e| Error::new("ERR_FULLPANEL_HANDLE", e.to_string()))?;
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return Err(Error::new("ERR_FULLPANEL_HANDLE", "not an AppKit window handle"));
    };
    // The bridge checks the view against the live windows before using it.
    parse(bridge(appkit.ns_view.as_ptr().cast_const()))
}

fn parse(json: *mut c_char) -> Result<Value> {
    if json.is_null() {
        return Err(Error::new("ERR_FULLPANEL_BRIDGE", "bridge returned no result"));
    }
    let text = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
    unsafe { ffi::fpw_free(json) };
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| Error::new("ERR_FULLPANEL_BRIDGE", format!("invalid bridge JSON: {e}")))?;
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(value);
    }
    let field = |key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    Err(Error { code: field("code"), message: field("message"), details: value })
}
