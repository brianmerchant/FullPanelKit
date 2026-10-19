// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// Automated suite for the Tauri integration. Runs on its own thread; every
// FullPanelKit call goes through the public fullpanelkit_tauri API (which
// marshals to the main thread) and fullscreen through WebviewWindow::set_fullscreen
// (Tao's native fullscreen path). It never simulates clicks or Mission Control.

use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use fullpanelkit_tauri as fullpanel;
use serde_json::{json, Value};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager, WebviewWindow};

use crate::Probes;

const POLL: Duration = Duration::from_millis(100);
const TRANSITION_TIMEOUT: Duration = Duration::from_secs(12);

pub fn spawn(app: AppHandle) {
    std::thread::spawn(move || {
        let mut suite = Suite { app: app.clone(), checks: Vec::new(), started: Instant::now() };
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| suite.run()));
        if let Err(panic) = outcome {
            let message = panic
                .downcast_ref::<String>().cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default();
            suite.check("PANIC", "suite aborted", false, json!({ "panic": message }));
        }
        let code = suite.finish();
        app.exit(code);
    });
}

struct Suite {
    app: AppHandle,
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

impl Suite {
    fn check(&mut self, id: &str, name: &str, pass: bool, details: Value) -> bool {
        println!("{} {id} {name}", if pass { "PASS" } else { "FAIL" });
        if !pass {
            println!("     {}", details);
        }
        self.checks.push(json!({ "id": id, "name": name, "pass": pass, "details": details }));
        pass
    }

    fn window(&self, label: &str) -> WebviewWindow {
        self.app.get_webview_window(label).unwrap_or_else(|| panic!("window {label} missing"))
    }

    fn diag(&self, w: &WebviewWindow) -> Value {
        fullpanel::diagnostics(w).unwrap_or_else(|e| json!({ "error": e.to_string(), "details": e.details }))
    }

    fn info(&self) -> Value {
        fullpanel::bridge_info(&self.app).unwrap_or_else(|e| json!({ "error": e.to_string() }))
    }

    /// Waits until fullscreen is `target` and the frame has been stable for
    /// 600 ms, then lets Tao's asynchronous style restore run.
    fn wait_fullscreen(&self, w: &WebviewWindow, target: bool) -> (bool, Value, u128) {
        let start = Instant::now();
        let mut last = Value::Null;
        let mut stable_since = Instant::now();
        loop {
            sleep(POLL);
            let d = self.diag(w);
            let frame = native(&d)["windowFrame"].clone();
            if !rects_equal(&frame, &last) {
                last = frame;
                stable_since = Instant::now();
            }
            let reached = native(&d)["fullScreen"].as_bool() == Some(target)
                && w.is_fullscreen().ok() == Some(target);
            if reached && stable_since.elapsed() >= Duration::from_millis(600) {
                sleep(Duration::from_millis(300));
                return (true, self.diag(w), start.elapsed().as_millis());
            }
            if start.elapsed() > TRANSITION_TIMEOUT {
                return (false, d, start.elapsed().as_millis());
            }
        }
    }

    fn enter(&self, w: &WebviewWindow) -> (bool, Value, u128) {
        w.set_fullscreen(true).expect("set_fullscreen(true)");
        self.wait_fullscreen(w, true)
    }

    fn exit(&self, w: &WebviewWindow) -> (bool, Value, u128) {
        w.set_fullscreen(false).expect("set_fullscreen(false)");
        self.wait_fullscreen(w, false)
    }

    fn probe(&self, w: &WebviewWindow) -> Value {
        let probes = self.app.state::<Probes>();
        probes.results.lock().unwrap().remove(w.label());
        let token = self.started.elapsed().as_millis();
        w.eval(format!("window.__fpProbe && window.__fpProbe({token})")).ok();
        let guard = probes.results.lock().unwrap();
        let (mut guard, _) = probes
            .arrived
            .wait_timeout_while(guard, Duration::from_secs(5), |r| !r.contains_key(w.label()))
            .unwrap();
        guard.remove(w.label()).unwrap_or(Value::Null)
    }

    /// Fullscreen checks for an attached, enabled window (steps 3–5).
    fn check_fullpanel_fullscreen(&mut self, prefix: &str, w: &WebviewWindow, d: &Value, ms: u128) -> bool {
        let n = native(d);
        let screen = &n["screenFrame"];
        let mut ok = self.check(&format!("{prefix}.active"), "native fullscreen entered, FullPanel Active",
            n["fullScreen"] == true && state_name(d) == "Active",
            json!({ "stateName": state_name(d), "fullScreen": n["fullScreen"], "ms": ms, "session": d["session"] }));
        ok &= self.check(&format!("{prefix}.frame"), "frame equals the full screen frame",
            n["frameCoversScreen"] == true,
            json!({ "windowFrame": n["windowFrame"], "screenFrame": screen }));
        ok &= self.check(&format!("{prefix}.windowserver"), "WindowServer bounds cover the display",
            n["windowServerCoversDisplay"] == true,
            json!({ "windowServerBounds": n["windowServerBounds"], "displayQuartzBounds": n["displayQuartzBounds"] }));
        let web = &n["webViewFrameInWindow"];
        let full = json!({ "x": 0.0, "y": 0.0, "width": screen["width"], "height": screen["height"] });
        ok &= self.check(&format!("{prefix}.webview"), "WKWebView frame covers the whole window",
            rects_equal(web, &full),
            json!({ "webViewClass": n["webViewClass"], "webViewFrameInWindow": web }));
        let p = self.probe(w);
        let viewport_ok = p["innerWidth"].as_f64() == screen["width"].as_f64()
            && p["innerHeight"].as_f64() == screen["height"].as_f64();
        ok &= self.check(&format!("{prefix}.viewport"), "web viewport equals the screen size", viewport_ok,
            json!({ "probe": p }));
        ok &= self.check(&format!("{prefix}.regions"), "page content at both notch-side regions",
            p["leftCentreHit"] == "notch-left" && p["rightCentreHit"] == "notch-right",
            json!({ "leftCentreHit": p["leftCentreHit"], "rightCentreHit": p["rightCentreHit"],
                    "topLeftCornerHit": p["topLeftCornerHit"], "topRightCornerHit": p["topRightCornerHit"],
                    "leftInWindow": d["geometry"]["leftInWindow"], "rightInWindow": d["geometry"]["rightInWindow"] }));
        ok
    }

    /// Exit checks (step 7): window back to `before` (signature taken windowed,
    /// just before entry).
    fn check_restored(&mut self, prefix: &str, before: &Value, d: &Value, ms: u128, baseline_options: &Value) -> bool {
        let after = window_signature(d);
        let mut ok = self.check(&format!("{prefix}.restored"), "exit restores frame, style and class",
            signatures_equal(before, &after), json!({ "before": before, "after": after, "ms": ms }));
        ok &= self.check(&format!("{prefix}.ws"), "WindowServer bounds match the restored frame",
            native(d)["windowServerMatchesFrame"] == true,
            json!({ "windowServerBounds": native(d)["windowServerBounds"], "frame": native(d)["windowFrame"] }));
        ok &= self.check(&format!("{prefix}.options"), "application presentation options restored",
            &native(d)["appPresentationOptionsRaw"] == baseline_options,
            json!({ "now": native(d)["appPresentationOptionsRaw"], "baseline": baseline_options }));
        ok
    }

    fn full_cycle(&mut self, prefix: &str, w: &WebviewWindow, baseline_options: &Value) {
        let before = window_signature(&self.diag(w));
        let (entered, d, ms) = self.enter(w);
        if !entered {
            self.check(&format!("{prefix}.enter"), "fullscreen entry completed", false, json!({ "diag": d }));
        }
        self.check_fullpanel_fullscreen(prefix, w, &d, ms);
        let (exited, d, ms) = self.exit(w);
        if !exited {
            self.check(&format!("{prefix}.exit"), "fullscreen exit completed", false, json!({ "diag": d }));
        }
        self.check_restored(prefix, &before, &d, ms, baseline_options);
        let stateful = state_name(&d);
        self.check(&format!("{prefix}.inactive"), "session Inactive (enabled, windowed) after exit",
            stateful == "Inactive", json!({ "stateName": stateful }));
    }

    fn run(&mut self) {
        sleep(Duration::from_millis(1500)); // windows shown and pages loaded
        let a = self.window("a");
        let b = self.window("b");
        a.set_focus().ok();
        sleep(Duration::from_millis(300));

        // ---- ENV --------------------------------------------------------------------
        let info = self.info();
        let a0 = self.diag(&a);
        let b0 = self.diag(&b);
        let baseline_options = native(&a0)["appPresentationOptionsRaw"].clone();
        let env_ok = self.check("ENV", "built-in display with camera housing; system support available",
            a0["geometry"]["hasCameraHousing"] == true && info["systemSupportAvailable"] == true
                && native(&a0)["fullScreen"] == false && native(&b0)["fullScreen"] == false,
            json!({ "geometry": a0["geometry"], "info": info, "screenName": native(&a0)["screenName"],
                    "aFullScreen": native(&a0)["fullScreen"], "bFullScreen": native(&b0)["fullScreen"],
                    "aError": a0["error"], "bError": b0["error"] }));
        if !env_ok {
            return;
        }

        // ---- 1. Class identification ---------------------------------------------------
        let n = native(&a0);
        self.check("T1.class", "Tauri window is TaoWindow : NSWindow, registered at run time",
            n["windowClass"] == "TaoWindow" && n["isTaoWindow"] == true
                && n["superclassChain"][1] == "NSWindow" && n["windowClassRegisteredAtRuntime"] == true
                && native(&b0)["windowClass"] == "TaoWindow",
            json!({ "windowClass": n["windowClass"], "runtimeClass": n["windowRuntimeClass"],
                    "image": n["windowClassImage"], "chain": n["superclassChain"],
                    "windowB": native(&b0)["windowClass"] }));
        self.check("T1.eligible", "eligible for FullPanelSession (not an AppKit-owned class)",
            n["eligibleForAttachment"] == true, json!({ "reason": n["ineligibleReason"] }));
        self.check("T1.parts", "delegate TaoWindowDelegate, WKWebView present",
            n["delegateClass"] == "TaoWindowDelegate" && n["webViewClass"].as_str().unwrap_or("") != "",
            json!({ "delegate": n["delegateClass"], "contentView": n["contentViewClass"],
                    "webView": n["webViewClass"], "webViewFrame": n["webViewFrameInWindow"],
                    "frameConversionGrowth": n["frameConversionGrowth"] }));

        // ---- 2. Attachment and ownership ----------------------------------------------
        let a_base = window_signature(&a0);
        let b_base = window_signature(&b0);
        let attached = fullpanel::attach(&a);
        let d = self.diag(&a);
        self.check("T2.attach", "attach succeeds; session starts Disabled; window untouched",
            attached.is_ok() && state_name(&d) == "Disabled" && signatures_equal(&a_base, &window_signature(&d)),
            json!({ "result": attached.as_ref().map_err(|e| e.to_string()), "after": window_signature(&d) }));
        let again = fullpanel::attach(&a);
        self.check("T2.idempotent", "second attach returns the existing session",
            again.as_ref().map(|v| v["alreadyAttached"] == true).unwrap_or(false),
            json!({ "result": again.as_ref().map_err(|e| e.to_string()) }));
        let info = self.info();
        self.check("T2.owned", "one live session, weakly tracked by the bridge",
            info["liveSessions"] == 1, json!({ "info": info }));
        let b_now = self.diag(&b);
        self.check("T2.b", "window B unaffected by A's attachment (same class, pass-through hooks)",
            signatures_equal(&b_base, &window_signature(&b_now)) && state_name(&b_now) == "NoSession",
            json!({ "before": b_base, "after": window_signature(&b_now) }));

        // ---- Windowed enable / disable ----------------------------------------------------
        let enabled = fullpanel::set_enabled(&a, true);
        let d = self.diag(&a);
        let sig = window_signature(&d);
        self.check("T8.enable-windowed", "enable keeps frame and WindowServer bounds; adds fullScreenPrimary",
            enabled.is_ok() && rects_equal(&sig["frame"], &a_base["frame"])
                && native(&d)["windowServerMatchesFrame"] == true && native(&d)["fullScreenPrimary"] == true
                && state_name(&d) == "Inactive",
            json!({ "before": a_base, "after": sig, "stateName": state_name(&d) }));
        fullpanel::set_enabled(&a, false).ok();
        sleep(Duration::from_millis(200));
        let d = self.diag(&a);
        self.check("T8.disable-windowed", "disable restores the original window exactly",
            signatures_equal(&a_base, &window_signature(&d)) && state_name(&d) == "Disabled",
            json!({ "before": a_base, "after": window_signature(&d) }));
        fullpanel::set_enabled(&a, true).ok();

        // ---- 3–5, 7. Fullscreen entry and exit ------------------------------------------------
        self.full_cycle("T3", &a, &baseline_options);

        // ---- 9. Repeated cycles, with a move and resize in between ------------------------
        self.full_cycle("T9.c1", &a, &baseline_options);
        a.set_size(LogicalSize::new(820.0, 560.0)).ok();
        a.set_position(LogicalPosition::new(140.0, 120.0)).ok();
        sleep(Duration::from_millis(400));
        self.full_cycle("T9.c2", &a, &baseline_options);
        self.full_cycle("T9.c3", &a, &baseline_options);

        // ---- 6. Window B: ordinary fullscreen, A unaffected -----------------------------------
        let a_before = window_signature(&self.diag(&a));
        let b_before = window_signature(&self.diag(&b));
        let (entered, d, ms) = self.enter(&b);
        let n = native(&d);
        let screen_h = n["screenFrame"]["height"].as_f64().unwrap_or(0.0);
        let frame_h = n["windowFrame"]["height"].as_f64().unwrap_or(0.0);
        self.check("T6.b-fullscreen", "window B gets ordinary fullscreen (camera-housing band excluded)",
            entered && state_name(&d) == "NoSession" && frame_h > 0.0 && frame_h < screen_h,
            json!({ "windowFrame": n["windowFrame"], "screenFrame": n["screenFrame"], "ms": ms,
                    "windowServerBounds": n["windowServerBounds"] }));
        let (exited, d, _) = self.exit(&b);
        self.check("T6.b-restored", "window B restored after its fullscreen",
            exited && signatures_equal(&b_before, &window_signature(&d)),
            json!({ "before": b_before, "after": window_signature(&d) }));
        let d = self.diag(&a);
        self.check("T6.a-untouched", "window A unaffected by B's fullscreen",
            signatures_equal(&a_before, &window_signature(&d)) && state_name(&d) == "Inactive",
            json!({ "before": a_before, "after": window_signature(&d) }));
        a.set_focus().ok();
        sleep(Duration::from_millis(300));

        // ---- 8. Disable / detach inside fullscreen, reattach -------------------------------
        let before = window_signature(&self.diag(&a));
        let (_, d, ms) = self.enter(&a);
        self.check_fullpanel_fullscreen("T8.disable-fs", &a, &d, ms);
        fullpanel::set_enabled(&a, false).ok();
        sleep(Duration::from_millis(300));
        let d = self.diag(&a);
        self.check("T8.disable-fs.menubar", "disable inside fullscreen restores presentation options at once",
            native(&d)["fullScreen"] == true && state_name(&d) == "Disabled",
            json!({ "stateName": state_name(&d), "options": native(&d)["appPresentationOptionsRaw"] }));
        let (_, d, ms) = self.exit(&a);
        // Disabling restores the pre-enable style, which is the pre-attach baseline.
        let mut expected = before.clone();
        expected["collectionBehaviorRaw"] = a_base["collectionBehaviorRaw"].clone();
        expected["styleMaskRaw"] = a_base["styleMaskRaw"].clone();
        expected["titlebarAppearsTransparent"] = a_base["titlebarAppearsTransparent"].clone();
        self.check_restored("T8.disable-fs", &expected, &d, ms, &baseline_options);

        fullpanel::set_enabled(&a, true).ok();
        let (_, d, ms) = self.enter(&a);
        self.check_fullpanel_fullscreen("T8.detach-fs", &a, &d, ms);
        let detached = fullpanel::detach(&a);
        let (_, d, ms) = self.exit(&a);
        self.check_restored("T8.detach-fs", &expected, &d, ms, &baseline_options);
        let info = self.info();
        self.check("T8.detach-fs.session", "detached: no session, nothing live in the bridge",
            detached.is_ok() && state_name(&d) == "NoSession" && info["liveSessions"] == 0,
            json!({ "stateName": state_name(&d), "info": info }));

        let reattached = fullpanel::attach(&a);
        fullpanel::set_enabled(&a, true).ok();
        self.check("T8.reattach", "reattach creates a new session (not already attached)",
            reattached.as_ref().map(|v| v["alreadyAttached"] == false).unwrap_or(false),
            json!({ "result": reattached.as_ref().map_err(|e| e.to_string()) }));
        self.full_cycle("T8.reattach", &a, &baseline_options);

        let before_detach = self.diag(&a);
        fullpanel::detach(&a).ok();
        let d = self.diag(&a);
        let mut expected_windowed = window_signature(&before_detach);
        expected_windowed["collectionBehaviorRaw"] = a_base["collectionBehaviorRaw"].clone();
        expected_windowed["styleMaskRaw"] = a_base["styleMaskRaw"].clone();
        expected_windowed["titlebarAppearsTransparent"] = a_base["titlebarAppearsTransparent"].clone();
        self.check("T8.detach-windowed", "windowed detach restores the original style, frame unchanged",
            signatures_equal(&expected_windowed, &window_signature(&d)) && state_name(&d) == "NoSession",
            json!({ "expected": expected_windowed, "after": window_signature(&d) }));
        fullpanel::attach(&a).ok();
        fullpanel::set_enabled(&a, true).ok();
        self.full_cycle("T8.reattach2", &a, &baseline_options);

        // ---- 10. Cleanup when windows close ----------------------------------------------------
        let baseline_records = self.info()["records"].as_array().map(|r| r.len()).unwrap_or(0);
        for i in 0..3 {
            let label = format!("c{i}");
            let c = crate::page_window(&self.app, &label, "Transient")
                .inner_size(500.0, 360.0)
                .position(200.0 + 30.0 * i as f64, 200.0)
                .build()
                .expect("build transient window");
            sleep(Duration::from_millis(600));
            let ok = fullpanel::attach(&c).is_ok() && fullpanel::set_enabled(&c, true).is_ok();
            c.close().ok();
            sleep(Duration::from_millis(800));
            let gone = self.app.get_webview_window(&label).is_none();
            let stale = fullpanel::state(&c);
            let info = self.info();
            let record = info["records"].as_array().and_then(|r| r.last()).cloned().unwrap_or(Value::Null);
            self.check(&format!("T10.close.{i}"), "close detaches; session released; stale handle rejected",
                ok && gone && info["liveSessions"] == 1 && record["closedByWindow"] == true
                    && record["sessionAttached"] == false && record["observing"] == false
                    && stale.as_ref().err().map(|e| e.code.as_str()) == Some("ERR_FULLPANEL_NO_WINDOW"),
                json!({ "record": record, "liveSessions": info["liveSessions"],
                        "stale": stale.as_ref().map_err(|e| e.to_string()) }));
        }
        // Closing a window while it is in FullPanel fullscreen.
        let d_win = crate::page_window(&self.app, "d", "Transient (fullscreen close)")
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
            .inner_size(600.0, 400.0)
            .position(240.0, 240.0)
            .build()
            .expect("build window d");
        sleep(Duration::from_millis(800));
        fullpanel::attach(&d_win).ok();
        fullpanel::set_enabled(&d_win, true).ok();
        let (entered, d, _) = self.enter(&d_win);
        let active = entered && state_name(&d) == "Active";
        d_win.close().ok();
        sleep(Duration::from_millis(1500));
        let info = self.info();
        let a_now = self.diag(&a);
        self.check("T10.close-fullscreen", "closing in FullPanel fullscreen restores presentation options",
            active && self.app.get_webview_window("d").is_none() && info["liveSessions"] == 1
                && native(&a_now)["appPresentationOptionsRaw"] == baseline_options,
            json!({ "wasActive": active, "info": info,
                    "options": native(&a_now)["appPresentationOptionsRaw"], "baseline": baseline_options }));
        let records = info["records"].as_array().map(|r| r.len()).unwrap_or(0);
        self.check("T10.records", "bridge kept one weak record per attachment, none alive after close",
            records == baseline_records + 4
                && info["records"].as_array().unwrap()[baseline_records..].iter()
                    .all(|r| r["sessionAttached"] == false && r["observing"] == false),
            json!({ "records": info["records"] }));

        // Window A is left attached and enabled, windowed, as in interactive mode.
        a.set_focus().ok();
        sleep(Duration::from_millis(300));
        let d = self.diag(&a);
        self.check("END", "window A attached, enabled, windowed; B untouched",
            state_name(&d) == "Inactive" && state_name(&self.diag(&b)) == "NoSession",
            json!({ "a": window_signature(&d) }));
    }

    fn finish(&mut self) -> i32 {
        let failed: Vec<_> = self.checks.iter().filter(|c| c["pass"] == false).map(|c| c["id"].clone()).collect();
        let report = json!({
            "suite": "fullpanelkit-tauri autotest",
            "tauri": tauri::VERSION,
            "elapsedMs": self.started.elapsed().as_millis() as u64,
            "passed": self.checks.len() - failed.len(),
            "failed": failed,
            "checks": self.checks,
            "notRun": ["physical clicks in the notch-side regions", "visible pixels",
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
