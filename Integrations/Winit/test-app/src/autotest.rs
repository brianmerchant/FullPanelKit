// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// Automated suite for the winit integration. Runs on its own thread and sends
// every AppKit-touching step to the main thread through the EventLoopProxy;
// FullPanelKit calls go through the public fullpanelkit_winit API and
// fullscreen through Window::set_fullscreen (winit's native, toggleFullScreen:
// path). Mouse checks post synthetic AppKit events to the application's event
// queue; they never move the pointer or simulate Mission Control.

use std::ffi::c_void;
use std::path::PathBuf;
use std::ptr::NonNull;
use std::sync::mpsc;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fullpanelkit_winit as fullpanel;
use raw_window_handle::{AppKitWindowHandle, HandleError, HasWindowHandle, RawWindowHandle, WindowHandle};
use serde_json::{json, Value};
use winit::dpi::{LogicalPosition, LogicalSize};
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::window::Fullscreen;

use crate::{App, UserEvent, Win, LEFT_COLOR, RIGHT_COLOR};

const POLL: Duration = Duration::from_millis(100);
const TRANSITION_TIMEOUT: Duration = Duration::from_secs(12);
const MAIN_TIMEOUT: Duration = Duration::from_secs(10);

pub fn spawn(proxy: EventLoopProxy<UserEvent>) {
    std::thread::spawn(move || {
        let mut suite = Suite { proxy: proxy.clone(), checks: Vec::new(), started: Instant::now() };
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| suite.run()));
        if let Err(panic) = outcome {
            let message = panic
                .downcast_ref::<String>().cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default();
            suite.check("PANIC", "suite aborted", false, json!({ "panic": message }));
        }
        let code = suite.finish();
        let _ = proxy.send_event(UserEvent::Exit(code));
    });
}

/// An AppKit handle for a view that may no longer exist, to check that the
/// bridge rejects stale handles without messaging them.
struct StaleView(NonNull<c_void>);

impl HasWindowHandle for StaleView {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let raw = RawWindowHandle::AppKit(AppKitWindowHandle::new(self.0));
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

struct Suite {
    proxy: EventLoopProxy<UserEvent>,
    checks: Vec<Value>,
    started: Instant,
}

// ---- Value helpers --------------------------------------------------------------

fn rect(v: &Value) -> Option<(f64, f64, f64, f64)> {
    Some((v["x"].as_f64()?, v["y"].as_f64()?, v["width"].as_f64()?, v["height"].as_f64()?))
}

fn rects_equal(a: &Value, b: &Value) -> bool {
    match (rect(a), rect(b)) {
        (Some(a), Some(b)) => {
            (a.0 - b.0).abs() <= 0.5 && (a.1 - b.1).abs() <= 0.5 && (a.2 - b.2).abs() <= 0.5 && (a.3 - b.3).abs() <= 0.5
        }
        _ => false,
    }
}

fn native(d: &Value) -> &Value {
    &d["native"]
}

fn state_name(d: &Value) -> String {
    d["state"]["stateName"].as_str().unwrap_or("?").to_string()
}

/// The window facts that FullPanelKit must leave as they were.
fn window_signature(d: &Value) -> Value {
    let n = native(d);
    json!({
        "frame": n["windowFrame"],
        "styleMaskRaw": n["styleMaskRaw"],
        "collectionBehaviorRaw": n["collectionBehaviorRaw"],
        "titlebarAppearsTransparent": n["titlebarAppearsTransparent"],
        "windowClass": n["windowClass"],
        "windowRuntimeClass": n["windowRuntimeClass"],
        "delegateClass": n["delegateClass"],
        "contentViewClass": n["contentViewClass"],
        "fullScreen": n["fullScreen"],
    })
}

fn signatures_equal(a: &Value, b: &Value) -> bool {
    rects_equal(&a["frame"], &b["frame"])
        && ["styleMaskRaw", "collectionBehaviorRaw", "titlebarAppearsTransparent", "windowClass",
            "windowRuntimeClass", "delegateClass", "contentViewClass", "fullScreen"]
            .iter()
            .all(|k| a[*k] == b[*k])
}

fn centre(r: &Value) -> Option<(f64, f64)> {
    let (x, y, w, h) = rect(r)?;
    Some((x + w / 2.0, y + h / 2.0))
}

fn err_string(r: &fullpanel::Result<Value>) -> Value {
    match r {
        Ok(v) => v.clone(),
        Err(e) => json!({ "error": e.to_string(), "details": e.details }),
    }
}

impl Suite {
    fn check(&mut self, id: &str, name: &str, pass: bool, details: Value) -> bool {
        println!("{} {id} {name}", if pass { "PASS" } else { "FAIL" });
        if !pass {
            println!("     {}", details);
        }
        self.checks.push(json!({ "id": id, "name": name, "pass": pass, "details": details }));
        pass
    }

    /// Runs `job` on the main thread and waits for its result.
    fn main<T, F>(&self, job: F) -> T
    where
        T: Send + 'static,
        F: FnOnce(&mut App, &ActiveEventLoop) -> T + Send + 'static,
    {
        let (sender, receiver) = mpsc::sync_channel(1);
        if self.proxy.send_event(UserEvent::Run(Box::new(move |app, event_loop| {
            let _ = sender.send(job(app, event_loop));
        }))).is_err() {
            panic!("event loop closed");
        }
        receiver.recv_timeout(MAIN_TIMEOUT).expect("main thread did not run the job")
    }

    /// Runs `job` on the main thread with the window labelled `label`.
    fn with<T, F>(&self, label: &str, job: F) -> T
    where
        T: Send + 'static,
        F: FnOnce(&mut Win) -> T + Send + 'static,
    {
        let label = label.to_string();
        self.main(move |app, _| {
            let win = app.win_mut(&label).unwrap_or_else(|| panic!("window {label} missing"));
            job(win)
        })
    }

    fn diag(&self, label: &str) -> Value {
        self.with(label, |w| {
            fullpanel::diagnostics(&*w.window).unwrap_or_else(|e| json!({ "error": e.to_string(), "details": e.details }))
        })
    }

    fn info(&self) -> Value {
        self.main(|_, _| fullpanel::bridge_info().unwrap_or_else(|e| json!({ "error": e.to_string() })))
    }

    fn attach(&self, label: &str) -> fullpanel::Result<Value> {
        self.with(label, |w| fullpanel::attach(&*w.window))
    }

    fn set_enabled(&self, label: &str, enabled: bool) -> fullpanel::Result<Value> {
        self.with(label, move |w| fullpanel::set_enabled(&*w.window, enabled))
    }

    fn detach(&self, label: &str) -> fullpanel::Result<Value> {
        self.with(label, |w| fullpanel::detach(&*w.window))
    }

    fn focus(&self, label: &str) {
        self.with(label, |w| w.window.focus_window());
        sleep(Duration::from_millis(300));
    }

    /// Waits until fullscreen is `target` (AppKit and winit agree) and the
    /// frame has been stable for 600 ms.
    fn wait_fullscreen(&self, label: &str, target: bool) -> (bool, Value, u128) {
        let start = Instant::now();
        let mut last = Value::Null;
        let mut stable_since = Instant::now();
        loop {
            sleep(POLL);
            let (d, winit_fullscreen) = {
                let label = label.to_string();
                self.main(move |app, _| {
                    let w = app.win(&label).expect("window");
                    (fullpanel::diagnostics(&*w.window).unwrap_or(Value::Null), w.window.fullscreen().is_some())
                })
            };
            let frame = native(&d)["windowFrame"].clone();
            if !rects_equal(&frame, &last) {
                last = frame;
                stable_since = Instant::now();
            }
            let reached = native(&d)["fullScreen"].as_bool() == Some(target) && winit_fullscreen == target;
            if reached && stable_since.elapsed() >= Duration::from_millis(600) {
                sleep(Duration::from_millis(300));
                return (true, self.diag(label), start.elapsed().as_millis());
            }
            if start.elapsed() > TRANSITION_TIMEOUT {
                return (false, d, start.elapsed().as_millis());
            }
        }
    }

    fn enter(&self, label: &str) -> (bool, Value, u128) {
        self.with(label, |w| w.window.set_fullscreen(Some(Fullscreen::Borderless(None))));
        self.wait_fullscreen(label, true)
    }

    fn exit(&self, label: &str) -> (bool, Value, u128) {
        self.with(label, |w| w.window.set_fullscreen(None));
        self.wait_fullscreen(label, false)
    }

    /// The last frame the app drew, after a fresh redraw.
    fn render(&self, label: &str) -> Value {
        self.with(label, |w| w.window.request_redraw());
        sleep(Duration::from_millis(300));
        self.with(label, |w| {
            json!({ "render": w.last_render, "inner": [w.window.inner_size().width, w.window.inner_size().height],
                    "scale": w.window.scale_factor() })
        })
    }

    /// Hit-tests and posts a synthetic click at (x, y), then returns the hit
    /// test and the clicks winit delivered to the app.
    fn click(&self, label: &str, x: f64, y: f64) -> (Value, Vec<Value>) {
        self.with(label, |w| w.clicks.clear());
        let hit = self.with(label, move |w| err_string(&fullpanel::testing::click(&*w.window, x, y, true)));
        sleep(Duration::from_millis(400));
        let clicks = self.with(label, |w| {
            w.clicks.iter().map(|c| json!({ "button": c.button, "x": c.x, "y": c.y, "region": c.region, "state": c.state }))
                .collect::<Vec<_>>()
        });
        (hit, clicks)
    }

    /// Fullscreen checks for an attached, enabled window.
    fn check_fullpanel_fullscreen(&mut self, prefix: &str, label: &str, d: &Value, ms: u128, mouse: bool) -> bool {
        let n = native(d);
        let screen = n["screenFrame"].clone();
        let mut ok = self.check(&format!("{prefix}.active"), "native fullscreen entered, FullPanel Active",
            n["fullScreen"] == true && state_name(d) == "Active",
            json!({ "stateName": state_name(d), "fullScreen": n["fullScreen"], "ms": ms, "session": d["session"] }));
        ok &= self.check(&format!("{prefix}.frame"), "frame equals the full screen frame",
            n["frameCoversScreen"] == true,
            json!({ "windowFrame": n["windowFrame"], "screenFrame": screen }));
        ok &= self.check(&format!("{prefix}.windowserver"), "WindowServer bounds cover the display",
            n["windowServerCoversDisplay"] == true,
            json!({ "windowServerBounds": n["windowServerBounds"], "displayQuartzBounds": n["displayQuartzBounds"] }));
        let full = json!({ "x": 0.0, "y": 0.0, "width": screen["width"], "height": screen["height"] });
        let layer = &n["contentLayer"];
        let surface_layer = layer["sublayers"].as_array().and_then(|s| s.first()).cloned().unwrap_or(Value::Null);
        ok &= self.check(&format!("{prefix}.content"), "WinitView and softbuffer's layer cover the whole window",
            rects_equal(&n["contentViewFrameInWindow"], &full) && rects_equal(&layer["layerBounds"], &full)
                && rects_equal(&surface_layer["frame"], &full) && surface_layer["hasContents"] == true,
            json!({ "contentView": n["contentViewFrameInWindow"], "layer": layer }));
        let r = self.render(label);
        let scale = r["scale"].as_f64().unwrap_or(0.0);
        let sw = screen["width"].as_f64().unwrap_or(0.0) * scale;
        let sh = screen["height"].as_f64().unwrap_or(0.0) * scale;
        let render = &r["render"];
        ok &= self.check(&format!("{prefix}.surface"), "winit inner size and softbuffer surface equal the screen in pixels",
            r["inner"][0].as_f64() == Some(sw) && r["inner"][1].as_f64() == Some(sh)
                && render["width"].as_f64() == Some(sw) && render["height"].as_f64() == Some(sh),
            json!({ "inner": r["inner"], "render": render, "screenPixels": [sw, sh] }));
        let regions = &render["regions"];
        let in_band = |v: &Value| rect(v).map(|(x, y, w, h)| x >= 0.0 && y == 0.0 && w > 0.0 && h > 0.0 && x + w <= sw).unwrap_or(false);
        ok &= self.check(&format!("{prefix}.render"), "app drew both notch-side regions at the top of its surface",
            in_band(&regions["left"]) && in_band(&regions["right"])
                && regions["leftCentrePixel"] == LEFT_COLOR && regions["rightCentrePixel"] == RIGHT_COLOR,
            json!({ "regions": regions, "leftInWindow": d["geometry"]["leftInWindow"],
                    "rightInWindow": d["geometry"]["rightInWindow"] }));
        if mouse {
            for (side, key) in [("notch-left", "leftInWindow"), ("notch-right", "rightInWindow")] {
                let Some((x, y)) = centre(&d["geometry"][key]) else {
                    ok &= self.check(&format!("{prefix}.mouse.{side}"), "notch-side region known", false, json!({}));
                    continue;
                };
                let (hit, clicks) = self.click(label, x, y);
                let delivered = clicks.len() == 1
                    && clicks[0]["region"] == side
                    && (clicks[0]["x"].as_f64().unwrap_or(-1.0) - x).abs() <= 1.0
                    && (clicks[0]["y"].as_f64().unwrap_or(-1.0) - y).abs() <= 1.0;
                ok &= self.check(&format!("{prefix}.mouse.{side}"),
                    &format!("click at the centre of {side}: hit WinitView, delivered by winit in {side}"),
                    hit["hitViewClass"] == "WinitView" && hit["hitIsContentView"] == true && delivered,
                    json!({ "point": [x, y], "hit": hit, "clicks": clicks }));
            }
        }
        ok
    }

    /// Exit checks: window back to `before` (signature taken windowed, just
    /// before entry).
    fn check_restored(&mut self, prefix: &str, label: &str, before: &Value, d: &Value, ms: u128, baseline_options: &Value) -> bool {
        let after = window_signature(d);
        let mut ok = self.check(&format!("{prefix}.restored"), "exit restores frame, style and class",
            signatures_equal(before, &after), json!({ "before": before, "after": after, "ms": ms }));
        ok &= self.check(&format!("{prefix}.ws"), "WindowServer bounds match the restored frame",
            native(d)["windowServerMatchesFrame"] == true,
            json!({ "windowServerBounds": native(d)["windowServerBounds"], "frame": native(d)["windowFrame"] }));
        ok &= self.check(&format!("{prefix}.options"), "application presentation options restored",
            &native(d)["appPresentationOptionsRaw"] == baseline_options,
            json!({ "now": native(d)["appPresentationOptionsRaw"], "baseline": baseline_options }));
        let r = self.render(label);
        ok &= self.check(&format!("{prefix}.surface-restored"), "softbuffer surface follows the restored size",
            r["inner"][0] == r["render"]["width"] && r["inner"][1] == r["render"]["height"]
                && r["render"]["regions"] == json!({}),
            json!({ "render": r }));
        ok
    }

    fn full_cycle(&mut self, prefix: &str, label: &str, baseline_options: &Value, mouse: bool) {
        let before = window_signature(&self.diag(label));
        let (entered, d, ms) = self.enter(label);
        if !entered {
            self.check(&format!("{prefix}.enter"), "fullscreen entry completed", false, json!({ "diag": d }));
        }
        self.check_fullpanel_fullscreen(prefix, label, &d, ms, mouse);
        let (exited, d, ms) = self.exit(label);
        if !exited {
            self.check(&format!("{prefix}.exit"), "fullscreen exit completed", false, json!({ "diag": d }));
        }
        self.check_restored(prefix, label, &before, &d, ms, baseline_options);
        let stateful = state_name(&d);
        self.check(&format!("{prefix}.inactive"), "session Inactive (enabled, windowed) after exit",
            stateful == "Inactive", json!({ "stateName": stateful }));
    }

    fn create(&self, label: &str, attach: bool, overlay: bool, size: (f64, f64), position: (f64, f64)) -> usize {
        let label = label.to_string();
        let view = self.main(move |app, event_loop| {
            let window = app.create_window(event_loop, &label, true, attach, overlay,
                LogicalSize::new(size.0, size.1), LogicalPosition::new(position.0, position.1));
            match window.window_handle().map(|h| h.as_raw()) {
                Ok(RawWindowHandle::AppKit(h)) => h.ns_view.as_ptr() as usize,
                _ => 0,
            }
        });
        sleep(Duration::from_millis(600));
        view
    }

    fn close(&self, label: &str) {
        let label = label.to_string();
        self.main(move |app, event_loop| {
            let id = app.win(&label).map(|w| w.window.id());
            if let Some(id) = id {
                app.close(event_loop, id);
            }
        });
    }

    fn exists(&self, label: &str) -> bool {
        let label = label.to_string();
        self.main(move |app, _| app.win(&label).is_some())
    }

    fn stale_state(&self, view: usize) -> fullpanel::Result<Value> {
        self.main(move |_, _| match NonNull::new(view as *mut c_void) {
            Some(ptr) => fullpanel::state(&StaleView(ptr)),
            None => Err(fullpanel::Error { code: "NULL".into(), message: "no view".into(), details: Value::Null }),
        })
    }

    fn run(&mut self) {
        sleep(Duration::from_millis(1200)); // windows shown and drawn
        self.focus("a");

        // ---- ENV --------------------------------------------------------------------
        let info = self.info();
        let a0 = self.diag("a");
        let b0 = self.diag("b");
        let baseline_options = native(&a0)["appPresentationOptionsRaw"].clone();
        let env_ok = self.check("ENV", "built-in display with camera housing; system support available",
            a0["geometry"]["hasCameraHousing"] == true && info["systemSupportAvailable"] == true
                && native(&a0)["fullScreen"] == false && native(&b0)["fullScreen"] == false,
            json!({ "geometry": a0["geometry"], "info": info, "screenName": native(&a0)["screenName"],
                    "aError": a0["error"], "bError": b0["error"] }));
        if !env_ok {
            return;
        }
        let threaded = fullpanel::state(&StaleView(NonNull::dangling()));
        self.check("ENV.thread", "calls off the main thread are refused without touching AppKit",
            threaded.as_ref().err().map(|e| e.code.as_str()) == Some("ERR_FULLPANEL_THREAD"),
            json!({ "result": err_string(&threaded) }));

        // ---- 1. Class identification ---------------------------------------------------
        let n = native(&a0);
        self.check("T1.class", "winit window is WinitWindow : NSWindow, registered at run time",
            n["windowClass"] == "WinitWindow" && n["isWinitWindow"] == true
                && n["superclassChain"][1] == "NSWindow" && n["windowClassRegisteredAtRuntime"] == true
                && native(&b0)["windowClass"] == "WinitWindow",
            json!({ "windowClass": n["windowClass"], "runtimeClass": n["windowRuntimeClass"],
                    "image": n["windowClassImage"], "chain": n["superclassChain"],
                    "windowB": native(&b0)["windowClass"], "windowBRuntime": native(&b0)["windowRuntimeClass"] }));
        self.check("T1.eligible", "eligible for FullPanelSession (not an AppKit-owned class)",
            n["eligibleForAttachment"] == true, json!({ "reason": n["ineligibleReason"] }));
        self.check("T1.overlay", "window A: full-size content view under a transparent titlebar (app configuration)",
            n["fullSizeContentView"] == true && n["titlebarAppearsTransparent"] == true && n["titled"] == true,
            json!({ "styleMaskRaw": n["styleMaskRaw"] }));
        self.check("T1.parts", "delegate WinitWindowDelegate; handle view is the WinitView content view; layer-backed",
            n["delegateClass"] == "WinitWindowDelegate" && n["contentViewClass"] == "WinitView"
                && n["handleIsContentView"] == true && n["contentLayer"]["layerBacked"] == true,
            json!({ "delegate": n["delegateClass"], "contentView": n["contentViewClass"],
                    "handleIsContentView": n["handleIsContentView"], "flipped": n["contentViewFlipped"],
                    "layer": n["contentLayer"], "frameConversionGrowth": n["frameConversionGrowth"],
                    "styleMaskRaw": n["styleMaskRaw"] }));

        // ---- 2. Attachment and ownership ----------------------------------------------
        let a_base = window_signature(&a0);
        let b_base = window_signature(&b0);
        let attached = self.attach("a");
        let d = self.diag("a");
        self.check("T2.attach", "attach succeeds; session starts Disabled; window untouched",
            attached.is_ok() && state_name(&d) == "Disabled" && signatures_equal(&a_base, &window_signature(&d)),
            json!({ "result": err_string(&attached), "after": window_signature(&d) }));
        let again = self.attach("a");
        self.check("T2.idempotent", "second attach returns the existing session",
            again.as_ref().map(|v| v["alreadyAttached"] == true).unwrap_or(false),
            json!({ "result": err_string(&again) }));
        let info = self.info();
        self.check("T2.owned", "one live session, weakly tracked by the bridge",
            info["liveSessions"] == 1, json!({ "info": info }));
        let b_now = self.diag("b");
        self.check("T2.b", "window B unaffected by A's attachment (same class, pass-through hooks)",
            signatures_equal(&b_base, &window_signature(&b_now)) && state_name(&b_now) == "NoSession",
            json!({ "before": b_base, "after": window_signature(&b_now) }));

        // ---- Windowed enable / disable ----------------------------------------------------
        let enabled = self.set_enabled("a", true);
        let d = self.diag("a");
        let sig = window_signature(&d);
        self.check("T8.enable-windowed", "enable keeps frame and WindowServer bounds; adds fullScreenPrimary",
            enabled.is_ok() && rects_equal(&sig["frame"], &a_base["frame"])
                && native(&d)["windowServerMatchesFrame"] == true && native(&d)["fullScreenPrimary"] == true
                && native(&d)["fullSizeContentView"] == true && state_name(&d) == "Inactive",
            json!({ "before": a_base, "after": sig, "stateName": state_name(&d) }));
        self.set_enabled("a", false).ok();
        sleep(Duration::from_millis(200));
        let d = self.diag("a");
        self.check("T8.disable-windowed", "disable restores the original window exactly",
            signatures_equal(&a_base, &window_signature(&d)) && state_name(&d) == "Disabled",
            json!({ "before": a_base, "after": window_signature(&d) }));
        self.set_enabled("a", true).ok();

        // ---- 3–5, 7. Fullscreen entry, rendering, mouse, exit --------------------------------
        self.full_cycle("T3", "a", &baseline_options, true);

        // ---- 9. Repeated cycles, with a move and resize in between ------------------------
        self.full_cycle("T9.c1", "a", &baseline_options, false);
        self.with("a", |w| {
            let _ = w.window.request_inner_size(LogicalSize::new(820.0, 560.0));
            w.window.set_outer_position(LogicalPosition::new(140.0, 120.0));
        });
        sleep(Duration::from_millis(400));
        self.full_cycle("T9.c2", "a", &baseline_options, true);
        self.full_cycle("T9.c3", "a", &baseline_options, false);

        // ---- 6. Window B: ordinary fullscreen, A unaffected -----------------------------------
        let a_before = window_signature(&self.diag("a"));
        let b_before = window_signature(&self.diag("b"));
        self.focus("b");
        let (entered, d, ms) = self.enter("b");
        let n = native(&d);
        let ordinary_options = n["appPresentationOptionsRaw"].clone();
        let screen_h = n["screenFrame"]["height"].as_f64().unwrap_or(0.0);
        let frame_h = n["windowFrame"]["height"].as_f64().unwrap_or(0.0);
        self.check("T6.b-fullscreen", "window B gets ordinary fullscreen (camera-housing band excluded)",
            entered && state_name(&d) == "NoSession" && frame_h > 0.0 && frame_h < screen_h,
            json!({ "windowFrame": n["windowFrame"], "screenFrame": n["screenFrame"], "ms": ms,
                    "windowServerBounds": n["windowServerBounds"] }));
        let (hit, clicks) = self.click("b", 100.0, 10.0);
        self.check("T6.b-mouse", "window B still receives clicks at the top of its content",
            hit["hitViewClass"] == "WinitView" && clicks.len() == 1 && clicks[0]["region"] == "content",
            json!({ "hit": hit, "clicks": clicks }));
        let (exited, d, _) = self.exit("b");
        self.check("T6.b-restored", "window B restored after its fullscreen",
            exited && signatures_equal(&b_before, &window_signature(&d)),
            json!({ "before": b_before, "after": window_signature(&d) }));
        let d = self.diag("a");
        self.check("T6.a-untouched", "window A unaffected by B's fullscreen",
            signatures_equal(&a_before, &window_signature(&d)) && state_name(&d) == "Inactive",
            json!({ "before": a_before, "after": window_signature(&d) }));
        self.focus("a");

        // ---- 8. Disable / detach inside fullscreen, reattach -------------------------------
        let before = window_signature(&self.diag("a"));
        let (_, d, ms) = self.enter("a");
        self.check_fullpanel_fullscreen("T8.disable-fs", "a", &d, ms, false);
        self.set_enabled("a", false).ok();
        sleep(Duration::from_millis(300));
        let d = self.diag("a");
        self.check("T8.disable-fs.menubar",
            "disable inside fullscreen restores ordinary fullscreen presentation options at once",
            native(&d)["fullScreen"] == true && state_name(&d) == "Disabled"
                && native(&d)["appPresentationOptionsRaw"] == ordinary_options,
            json!({ "stateName": state_name(&d), "options": native(&d)["appPresentationOptionsRaw"],
                    "ordinaryFullscreenOptions": ordinary_options }));
        let (_, d, ms) = self.exit("a");
        // Disabling restores the pre-enable style, which is the pre-attach baseline.
        let mut expected = before.clone();
        expected["collectionBehaviorRaw"] = a_base["collectionBehaviorRaw"].clone();
        expected["styleMaskRaw"] = a_base["styleMaskRaw"].clone();
        expected["titlebarAppearsTransparent"] = a_base["titlebarAppearsTransparent"].clone();
        self.check_restored("T8.disable-fs", "a", &expected, &d, ms, &baseline_options);

        self.set_enabled("a", true).ok();
        let (_, d, ms) = self.enter("a");
        self.check_fullpanel_fullscreen("T8.detach-fs", "a", &d, ms, false);
        let detached = self.detach("a");
        let (_, d, ms) = self.exit("a");
        self.check_restored("T8.detach-fs", "a", &expected, &d, ms, &baseline_options);
        let info = self.info();
        self.check("T8.detach-fs.session", "detached: no session, nothing live in the bridge",
            detached.is_ok() && state_name(&d) == "NoSession" && info["liveSessions"] == 0,
            json!({ "stateName": state_name(&d), "info": info }));

        let reattached = self.attach("a");
        self.set_enabled("a", true).ok();
        self.check("T8.reattach", "reattach creates a new session (not already attached)",
            reattached.as_ref().map(|v| v["alreadyAttached"] == false).unwrap_or(false),
            json!({ "result": err_string(&reattached) }));
        self.full_cycle("T8.reattach", "a", &baseline_options, true);

        let before_detach = self.diag("a");
        self.detach("a").ok();
        let d = self.diag("a");
        let mut expected_windowed = window_signature(&before_detach);
        expected_windowed["collectionBehaviorRaw"] = a_base["collectionBehaviorRaw"].clone();
        expected_windowed["styleMaskRaw"] = a_base["styleMaskRaw"].clone();
        expected_windowed["titlebarAppearsTransparent"] = a_base["titlebarAppearsTransparent"].clone();
        self.check("T8.detach-windowed", "windowed detach restores the original style, frame unchanged",
            signatures_equal(&expected_windowed, &window_signature(&d)) && state_name(&d) == "NoSession",
            json!({ "expected": expected_windowed, "after": window_signature(&d) }));
        self.attach("a").ok();
        self.set_enabled("a", true).ok();
        self.full_cycle("T8.reattach2", "a", &baseline_options, false);

        // ---- 11. Multiple windows, independent sessions ---------------------------------------
        self.create("c", true, true, (600.0, 400.0), (260.0, 220.0));
        let info = self.info();
        let c_attached = state_name(&self.diag("c")) == "Inactive";
        self.check("T11.two-sessions", "a second attached window has its own session",
            c_attached && info["liveSessions"] == 2, json!({ "info": info }));
        let a_before = window_signature(&self.diag("a"));
        self.focus("c");
        let (_, d, ms) = self.enter("c");
        self.check_fullpanel_fullscreen("T11.c", "c", &d, ms, true);
        let a_now = self.diag("a");
        self.check("T11.a-independent", "window A stays windowed and Inactive while C is Active",
            signatures_equal(&a_before, &window_signature(&a_now)) && state_name(&a_now) == "Inactive",
            json!({ "before": a_before, "after": window_signature(&a_now), "stateName": state_name(&a_now) }));
        self.set_enabled("a", false).ok();
        let d = self.diag("c");
        self.check("T11.c-independent", "disabling A does not affect C's active session",
            state_name(&d) == "Active" && native(&d)["frameCoversScreen"] == true,
            json!({ "stateName": state_name(&d) }));
        self.set_enabled("a", true).ok();
        let (_, _, _) = self.exit("c");
        self.close("c");
        sleep(Duration::from_millis(800));
        self.focus("a");

        // ---- 10. Cleanup when windows close ----------------------------------------------------
        let baseline_records = self.info()["records"].as_array().map(|r| r.len()).unwrap_or(0);
        for i in 0..3 {
            let label = format!("t{i}");
            let view = self.create(&label, true, true, (500.0, 360.0), (200.0 + 30.0 * i as f64, 200.0));
            let ok = state_name(&self.diag(&label)) == "Inactive";
            self.close(&label);
            sleep(Duration::from_millis(800));
            let gone = !self.exists(&label);
            let stale = self.stale_state(view);
            let info = self.info();
            let record = info["records"].as_array().and_then(|r| r.last()).cloned().unwrap_or(Value::Null);
            self.check(&format!("T10.close.{i}"), "dropping the winit Window detaches; session released; stale handle rejected",
                ok && gone && info["liveSessions"] == 1 && record["closedByWindow"] == true
                    && record["sessionAlive"] == false && record["windowAlive"] == false
                    && record["observing"] == false
                    && stale.as_ref().err().map(|e| e.code.as_str()) == Some("ERR_FULLPANEL_NO_WINDOW"),
                json!({ "record": record, "liveSessions": info["liveSessions"], "stale": err_string(&stale) }));
        }
        // Closing a window while it is in FullPanel fullscreen.
        self.create("d", true, true, (600.0, 400.0), (240.0, 240.0));
        self.focus("d");
        let (entered, d, _) = self.enter("d");
        let active = entered && state_name(&d) == "Active";
        self.close("d");
        sleep(Duration::from_millis(1500));
        let info = self.info();
        let a_now = self.diag("a");
        self.check("T10.close-fullscreen", "closing in FullPanel fullscreen restores presentation options",
            active && !self.exists("d") && info["liveSessions"] == 1
                && native(&a_now)["appPresentationOptionsRaw"] == baseline_options,
            json!({ "wasActive": active, "info": info,
                    "options": native(&a_now)["appPresentationOptionsRaw"], "baseline": baseline_options }));
        let records = info["records"].as_array().map(|r| r.len()).unwrap_or(0);
        self.check("T10.records", "bridge kept one weak record per attachment, none alive after close",
            records == baseline_records + 4
                && info["records"].as_array().unwrap()[baseline_records..].iter()
                    .all(|r| r["sessionAttached"] == false && r["observing"] == false),
            json!({ "records": info["records"] }));

        // ---- 12. Standard framed window (no full-size content view) -----------------------
        // AppKit keeps the content rect when a style change adds or removes
        // .fullSizeContentView, so enabling shortens the frame by the titlebar
        // and disabling lengthens it again. Characterized here, not corrected.
        self.create("f", false, false, (600.0, 400.0), (300.0, 260.0));
        let f0 = self.diag("f");
        let titlebar = native(&f0)["windowFrame"]["height"].as_f64().unwrap_or(0.0) - 400.0;
        self.attach("f").ok();
        self.set_enabled("f", true).ok();
        let f1 = self.diag("f");
        let h0 = native(&f0)["windowFrame"]["height"].as_f64().unwrap_or(0.0);
        let h1 = native(&f1)["windowFrame"]["height"].as_f64().unwrap_or(0.0);
        let content1 = native(&f1)["contentViewFrameInWindow"]["height"].as_f64().unwrap_or(0.0);
        self.check("T12.framed-enable", "framed window: enable keeps the content size, frame shrinks by the titlebar",
            titlebar > 0.0 && (h0 - h1 - titlebar).abs() <= 0.5 && (content1 - 400.0).abs() <= 0.5
                && native(&f1)["fullSizeContentView"] == true,
            json!({ "before": window_signature(&f0), "after": window_signature(&f1), "titlebar": titlebar }));
        self.focus("f");
        let (_, d, ms) = self.enter("f");
        self.check_fullpanel_fullscreen("T12.framed", "f", &d, ms, true);
        let (_, d, _) = self.exit("f");
        self.check("T12.framed-exit", "framed window: exit restores the enabled frame",
            rects_equal(&native(&d)["windowFrame"], &native(&f1)["windowFrame"]) && state_name(&d) == "Inactive",
            json!({ "enabled": native(&f1)["windowFrame"], "after": native(&d)["windowFrame"] }));
        self.set_enabled("f", false).ok();
        let f2 = self.diag("f");
        self.check("T12.framed-disable", "framed window: disable restores the original style and frame",
            signatures_equal(&window_signature(&f0), &window_signature(&f2)),
            json!({ "before": window_signature(&f0), "after": window_signature(&f2) }));
        self.close("f");
        sleep(Duration::from_millis(500));

        // ---- END: A attached, enabled, windowed; B never touched -------------------------------
        self.focus("a");
        let d = self.diag("a");
        let b_end = self.diag("b");
        self.check("END", "window A attached, enabled, windowed; B unattached, same class and style",
            state_name(&d) == "Inactive" && state_name(&b_end) == "NoSession"
                && window_signature(&b_end)["styleMaskRaw"] == b_base["styleMaskRaw"]
                && window_signature(&b_end)["collectionBehaviorRaw"] == b_base["collectionBehaviorRaw"]
                && window_signature(&b_end)["windowClass"] == b_base["windowClass"],
            json!({ "a": window_signature(&d), "b": window_signature(&b_end), "bBase": b_base }));
    }

    fn finish(&mut self) -> i32 {
        let failed: Vec<_> = self.checks.iter().filter(|c| c["pass"] == false).map(|c| c["id"].clone()).collect();
        let report = json!({
            "suite": "fullpanelkit-winit autotest",
            "winit": "0.30.13",
            "softbuffer": "0.4.8",
            "elapsedMs": self.started.elapsed().as_millis() as u64,
            "passed": self.checks.len() - failed.len(),
            "failed": failed,
            "checks": self.checks,
            "notRun": ["physical clicks in the notch-side regions (synthetic AppKit events only)",
                       "visible pixels on the panel (the app's buffer is checked, not the display)",
                       "Mission Control and Spaces navigation"],
        });
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("reports");
        std::fs::create_dir_all(&dir).ok();
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let path = dir.join(format!("autotest-{stamp}.json"));
        std::fs::write(&path, serde_json::to_string_pretty(&report).unwrap()).ok();
        println!("\n{} passed, {} failed  ({:.1} s)  report: {}", self.checks.len() - failed.len(),
                 failed.len(), self.started.elapsed().as_secs_f64(), path.display());
        if failed.is_empty() { 0 } else { 1 }
    }
}
