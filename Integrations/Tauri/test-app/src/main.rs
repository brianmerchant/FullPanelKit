// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE at the repository root).
// FullPanelKit for Tauri: development test app.
//
//   Window A ("a"): FullPanelKit attached and enabled (interactive mode).
//   Window B ("b"): ordinary Tauri window, never attached.
//
//   cargo run -p fullpanel-tauri-test               interactive hardware test
//   cargo run -p fullpanel-tauri-test -- --autotest  automated suite (report in test-app/reports/)

mod autotest;

use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use fullpanelkit_tauri as fullpanel;
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, Runtime, TitleBarStyle, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// Results of the page's __fpProbe(), by window label (autotest).
#[derive(Default)]
pub struct Probes {
    results: Mutex<HashMap<String, Value>>,
    arrived: Condvar,
}

/// Window A: transparent titlebar over full-size content (`titleBarStyle:
/// "Overlay"`), the Tauri counterpart of Electron's `titleBarStyle: 'hidden'`.
pub fn build_window_a<R: Runtime, M: Manager<R>>(manager: &M) -> tauri::Result<WebviewWindow<R>> {
    page_window(manager, "a", "Window A — FullPanelKit")
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .inner_size(960.0, 640.0)
        .position(80.0, 80.0)
        .build()
}

pub fn build_window_b<R: Runtime, M: Manager<R>>(manager: &M) -> tauri::Result<WebviewWindow<R>> {
    page_window(manager, "b", "Window B — ordinary")
        .inner_size(720.0, 520.0)
        .position(1080.0, 160.0)
        .build()
}

pub fn page_window<'a, R: Runtime, M: Manager<R>>(
    manager: &'a M,
    label: &str,
    title: &str,
) -> WebviewWindowBuilder<'a, R, M> {
    WebviewWindowBuilder::new(manager, label, WebviewUrl::App("index.html".into()))
        .title(title)
        .initialization_script(format!("window.FP_LABEL = {};", json!(label)))
}

fn window(app: &AppHandle, label: &str) -> Result<WebviewWindow, String> {
    app.get_webview_window(label).ok_or_else(|| format!("no window {label:?}"))
}

fn result(value: fullpanel::Result<Value>) -> Result<Value, String> {
    value.map_err(|e| e.to_string())
}

#[tauri::command]
fn fp_call(app: AppHandle, label: String, action: String) -> Result<Value, String> {
    let w = window(&app, &label)?;
    match action.as_str() {
        "attach" => result(fullpanel::attach(&w)),
        "enable" => result(fullpanel::set_enabled(&w, true)),
        "disable" => result(fullpanel::set_enabled(&w, false)),
        "detach" => result(fullpanel::detach(&w)),
        "state" => result(fullpanel::state(&w)),
        "diagnostics" => result(fullpanel::diagnostics(&w)),
        "enter" | "exit" => {
            w.set_fullscreen(action == "enter").map_err(|e| e.to_string())?;
            Ok(json!({ "ok": true }))
        }
        other => Err(format!("unknown action {other:?}")),
    }
}

#[tauri::command]
fn log_event(label: String, line: String) {
    println!("[pointer {label}] {line}");
}

#[tauri::command]
fn report_probe(probes: tauri::State<'_, Probes>, label: String, data: Value) {
    probes.results.lock().unwrap().insert(label, data);
    probes.arrived.notify_all();
}

fn main() {
    let autotest = std::env::args().any(|arg| arg == "--autotest");
    tauri::Builder::default()
        .manage(Probes::default())
        .invoke_handler(tauri::generate_handler![fp_call, log_event, report_probe])
        .setup(move |app| {
            let a = build_window_a(app)?;
            build_window_b(app)?;
            if autotest {
                // The suite records window A before attaching.
                autotest::spawn(app.handle().clone());
            } else {
                fullpanel::attach(&a)?;
                fullpanel::set_enabled(&a, true)?;
                println!("Window A: {}", fullpanel::state(&a)?["state"]);
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running the FullPanel Tauri test app");
}
