// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).

// Development app for fullpanelkit-winit. Window A is attached to FullPanelKit
// and enabled; window B is an ordinary winit window (control). Both draw with
// softbuffer (CPU pixels, no GPU or browser renderer) and log every mouse
// button event with the region it landed in.
//
//   cargo run -p fullpanel-winit-test                # interactive hardware test
//   cargo run -p fullpanel-winit-test -- --autotest  # automated suite
//
// Keys (in the focused window): F fullscreen, E enable/disable, A attach,
// D detach, S state, I diagnostics, N new attached window, W close window,
// Q quit.

mod autotest;

use std::collections::HashMap;
use std::num::NonZeroU32;
use std::sync::Arc;
use std::time::{Duration, Instant};

use fullpanelkit_winit as fullpanel;
use fullpanelkit_winit::{NotchRegions, Rect};
use serde_json::{json, Value};
use softbuffer::{Context, Surface};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalPosition, LogicalSize};
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::keyboard::Key;
use winit::platform::macos::WindowAttributesExtMacOS;
use winit::window::{Fullscreen, Window, WindowId};

const BACKGROUND: u32 = 0x1c1c22;
const BACKGROUND_FALLBACK: u32 = 0x3a1a1a;
const CONTROL_BACKGROUND: u32 = 0x24324a;
const CONTROL_TOP_EDGE: u32 = 0xb455e0;
pub const LEFT_COLOR: u32 = 0xff8c1a;
pub const RIGHT_COLOR: u32 = 0x14b8a6;
const HOUSING_COLOR: u32 = 0x000000;
const FLASH_COLOR: u32 = 0xffffff;
const MARKER_COLOR: u32 = 0xfafafa;
const FLASH: Duration = Duration::from_millis(250);

/// Work for the main thread, sent by the automated suite.
pub type MainJob = Box<dyn FnOnce(&mut App, &ActiveEventLoop) + Send>;

pub enum UserEvent {
    Run(MainJob),
    Exit(i32),
}

#[derive(Clone)]
pub struct Click {
    pub button: String,
    pub x: f64,
    pub y: f64,
    pub region: &'static str,
    pub state: String,
    pub at: Instant,
}

pub struct Win {
    pub label: String,
    pub window: Arc<Window>,
    surface: Surface<Arc<Window>, Arc<Window>>,
    /// Created as a FullPanel window (attached at creation in interactive mode).
    pub fullpanel: bool,
    cursor: Option<(f64, f64)>,
    pub clicks: Vec<Click>,
    /// What the last frame drew (physical pixels), for the suite.
    pub last_render: Value,
    title_state: String,
}

pub struct App {
    pub autotest: bool,
    pub windows: HashMap<WindowId, Win>,
    proxy: EventLoopProxy<UserEvent>,
    started: bool,
    next_label: u8,
    pub exit_code: i32,
}

fn log(label: &str, message: impl AsRef<str>) {
    println!("[{label}] {}", message.as_ref());
}

fn state_name(window: &Window) -> String {
    match fullpanel::state(window) {
        Ok(v) => v["state"]["stateName"].as_str().unwrap_or("?").to_string(),
        Err(e) => format!("error {}", e.code),
    }
}

fn region_at(regions: Option<&NotchRegions>, x: f64, y: f64) -> &'static str {
    match regions {
        Some(r) if r.left.contains(x, y) => "notch-left",
        Some(r) if r.right.contains(x, y) => "notch-right",
        Some(r) if r.housing.contains(x, y) => "housing",
        _ => "content",
    }
}

fn fill(buffer: &mut [u32], width: u32, height: u32, rect: Rect, color: u32) {
    let x0 = rect.x.max(0.0).round() as i64;
    let y0 = rect.y.max(0.0).round() as i64;
    let x1 = (rect.x + rect.width).min(width as f64).round() as i64;
    let y1 = (rect.y + rect.height).min(height as f64).round() as i64;
    for y in y0..y1 {
        let row = (y as usize) * width as usize;
        buffer[row + x0 as usize..row + x1.max(x0) as usize].fill(color);
    }
}

impl Win {
    fn redraw(&mut self) {
        let size = self.window.inner_size();
        let (Some(width), Some(height)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else {
            return;
        };
        if self.surface.resize(width, height).is_err() {
            return;
        }
        let scale = self.window.scale_factor();
        let state = fullpanel::state(&*self.window).ok();
        let state_name = state
            .as_ref()
            .and_then(|v| v["state"]["stateName"].as_str())
            .unwrap_or("?")
            .to_string();
        let regions = fullpanel::notch_regions(&*self.window).ok().flatten();
        let Ok(mut buffer) = self.surface.buffer_mut() else { return };
        let (w, h) = (width.get(), height.get());
        let background = match (self.fullpanel, state_name.as_str()) {
            (false, _) => CONTROL_BACKGROUND,
            (true, "Fallback") => BACKGROUND_FALLBACK,
            _ => BACKGROUND,
        };
        buffer.fill(background);
        let mut drawn = json!({});
        if !self.fullpanel {
            // Control window: a 4-point band marks the top edge of its content.
            let edge = Rect { x: 0.0, y: 0.0, width: w as f64, height: 4.0 * scale };
            fill(&mut buffer, w, h, edge, CONTROL_TOP_EDGE);
        } else if let Some(r) = regions.filter(|r| r.active) {
            let flash = self.clicks.last().filter(|c| c.at.elapsed() < FLASH).map(|c| c.region);
            let left = r.left.to_physical(scale);
            let right = r.right.to_physical(scale);
            let housing = r.housing.to_physical(scale);
            fill(&mut buffer, w, h, left, if flash == Some("notch-left") { FLASH_COLOR } else { LEFT_COLOR });
            fill(&mut buffer, w, h, right, if flash == Some("notch-right") { FLASH_COLOR } else { RIGHT_COLOR });
            fill(&mut buffer, w, h, housing, HOUSING_COLOR);
            let pixel = |rect: Rect| {
                let x = (rect.x + rect.width / 2.0) as usize;
                let y = (rect.y + rect.height / 2.0) as usize;
                if x < w as usize && y < h as usize { json!(buffer[y * w as usize + x]) } else { Value::Null }
            };
            drawn = json!({
                "left": { "x": left.x, "y": left.y, "width": left.width, "height": left.height },
                "right": { "x": right.x, "y": right.y, "width": right.width, "height": right.height },
                "leftCentrePixel": pixel(left),
                "rightCentrePixel": pixel(right),
            });
            if flash.is_some() {
                self.window.request_redraw();
            }
        }
        // Markers for the last few clicks.
        for click in self.clicks.iter().rev().take(8) {
            let marker = Rect { x: (click.x - 4.0) * scale, y: (click.y - 4.0) * scale, width: 9.0 * scale, height: 9.0 * scale };
            fill(&mut buffer, w, h, marker, MARKER_COLOR);
        }
        self.last_render = json!({
            "width": w, "height": h, "scaleFactor": scale, "stateName": state_name,
            "background": background, "regions": drawn,
        });
        let _ = buffer.present();

        if state_name != self.title_state {
            let kind = if self.fullpanel { "FullPanel" } else { "control" };
            self.window.set_title(&format!("FullPanelKit winit · {} ({kind}) · {state_name}", self.label));
            if !self.title_state.is_empty() {
                log(&self.label, format!("state {state_name}"));
            }
            self.title_state = state_name;
        }
    }

    fn mouse_input(&mut self, state: ElementState, button: MouseButton) {
        let Some((x, y)) = self.cursor else { return };
        let regions = fullpanel::notch_regions(&*self.window).ok().flatten();
        let region = region_at(regions.as_ref(), x, y);
        let session = state_name(&self.window);
        let phase = if state == ElementState::Pressed { "down" } else { "up" };
        log(&format!("pointer {}", self.label),
            format!("{phase} {button:?} at ({x:.1}, {y:.1}) region={region} state={session}"));
        if state == ElementState::Pressed {
            self.clicks.push(Click { button: format!("{button:?}"), x, y, region, state: session, at: Instant::now() });
            self.window.request_redraw();
        }
    }

    fn toggle_fullscreen(&self) {
        let target = if self.window.fullscreen().is_some() { None } else { Some(Fullscreen::Borderless(None)) };
        self.window.set_fullscreen(target);
    }
}

fn print_result(label: &str, what: &str, result: fullpanel::Result<Value>) {
    match result {
        Ok(v) => log(label, format!("{what}: {}", serde_json::to_string_pretty(&v).unwrap_or_default())),
        Err(e) => log(label, format!("{what} failed: {e}")),
    }
}

impl App {
    pub fn win(&self, label: &str) -> Option<&Win> {
        self.windows.values().find(|w| w.label == label)
    }

    pub fn win_mut(&mut self, label: &str) -> Option<&mut Win> {
        self.windows.values_mut().find(|w| w.label == label)
    }

    /// Creates a window; `fullpanel` windows are attached and enabled unless
    /// `attach` is false (the suite attaches them itself). `overlay` windows
    /// have a full-size content view under a transparent titlebar, the
    /// configuration FullPanel windows should use: enabling then leaves the
    /// frame alone (see README, "Frame and titlebar").
    pub fn create_window(
        &mut self,
        event_loop: &ActiveEventLoop,
        label: &str,
        fullpanel: bool,
        attach: bool,
        overlay: bool,
        size: LogicalSize<f64>,
        position: LogicalPosition<f64>,
    ) -> Arc<Window> {
        let kind = if fullpanel { "FullPanel" } else { "control" };
        let attributes = Window::default_attributes()
            .with_title(format!("FullPanelKit winit · {label} ({kind})"))
            .with_inner_size(size)
            .with_position(position)
            .with_fullsize_content_view(overlay)
            .with_titlebar_transparent(overlay)
            .with_title_hidden(overlay);
        let window = Arc::new(event_loop.create_window(attributes).expect("create window"));
        let context = Context::new(window.clone()).expect("softbuffer context");
        let surface = Surface::new(&context, window.clone()).expect("softbuffer surface");
        if fullpanel && attach {
            match fullpanel::attach(&*window).and_then(|_| fullpanel::set_enabled(&*window, true)) {
                Ok(v) => log(label, format!("attached and enabled: {}", v["state"]["stateName"])),
                Err(e) => log(label, format!("attach failed: {e}")),
            }
        }
        let win = Win {
            label: label.to_string(),
            window: window.clone(),
            surface,
            fullpanel,
            cursor: None,
            clicks: Vec::new(),
            last_render: Value::Null,
            title_state: String::new(),
        };
        self.windows.insert(window.id(), win);
        window.request_redraw();
        window
    }

    fn key(&mut self, event_loop: &ActiveEventLoop, id: WindowId, key: &str) {
        let Some(win) = self.windows.get(&id) else { return };
        let label = win.label.clone();
        let window = win.window.clone();
        match key {
            "f" => win.toggle_fullscreen(),
            "e" => {
                let enabled = fullpanel::state(&*window).map(|v| v["state"]["enabled"] == true).unwrap_or(false);
                print_result(&label, if enabled { "disable" } else { "enable" }, fullpanel::set_enabled(&*window, !enabled));
            }
            "a" => print_result(&label, "attach", fullpanel::attach(&*window)),
            "d" => print_result(&label, "detach", fullpanel::detach(&*window)),
            "s" => print_result(&label, "state", fullpanel::state(&*window)),
            "i" => {
                print_result(&label, "diagnostics", fullpanel::diagnostics(&*window));
                print_result(&label, "bridge", fullpanel::bridge_info());
            }
            "n" => {
                let label = format!("{}", (b'c' + self.next_label) as char);
                self.next_label = (self.next_label + 1) % 24;
                let offset = 40.0 * self.next_label as f64;
                self.create_window(event_loop, &label, true, true, true, LogicalSize::new(640.0, 420.0),
                                   LogicalPosition::new(220.0 + offset, 160.0 + offset));
            }
            "w" => self.close(event_loop, id),
            "q" => event_loop.exit(),
            _ => return,
        }
        window.request_redraw();
    }

    pub fn close(&mut self, event_loop: &ActiveEventLoop, id: WindowId) {
        if let Some(win) = self.windows.remove(&id) {
            log(&win.label, "closed");
        }
        if self.windows.is_empty() && !self.autotest {
            event_loop.exit();
        }
    }
}

impl ApplicationHandler<UserEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.started {
            return;
        }
        self.started = true;
        let attach = !self.autotest;
        self.create_window(event_loop, "a", true, attach, true, LogicalSize::new(900.0, 600.0), LogicalPosition::new(80.0, 80.0));
        self.create_window(event_loop, "b", false, false, false, LogicalSize::new(700.0, 450.0), LogicalPosition::new(1020.0, 160.0));
        if self.autotest {
            autotest::spawn(self.proxy.clone());
        } else {
            println!("Window A: FullPanel (attached, enabled). Window B: control.");
            println!("Keys: F fullscreen, E enable/disable, A attach, D detach, S state, I diagnostics,");
            println!("      N new attached window, W close window, Q quit. The green button also works.");
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::Run(job) => job(self, event_loop),
            UserEvent::Exit(code) => {
                self.exit_code = code;
                event_loop.exit();
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => self.close(event_loop, id),
            WindowEvent::RedrawRequested => {
                if let Some(win) = self.windows.get_mut(&id) {
                    win.redraw();
                }
            }
            WindowEvent::Resized(_) | WindowEvent::Moved(_) | WindowEvent::Focused(_)
            | WindowEvent::ScaleFactorChanged { .. } | WindowEvent::Occluded(_) => {
                if let Some(win) = self.windows.get(&id) {
                    win.window.request_redraw();
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                if let Some(win) = self.windows.get_mut(&id) {
                    let logical = position.to_logical::<f64>(win.window.scale_factor());
                    win.cursor = Some((logical.x, logical.y));
                }
            }
            WindowEvent::CursorLeft { .. } => {
                if let Some(win) = self.windows.get_mut(&id) {
                    win.cursor = None;
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                if let Some(win) = self.windows.get_mut(&id) {
                    win.mouse_input(state, button);
                }
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed && !event.repeat => {
                if let Key::Character(text) = &event.logical_key {
                    let key = text.to_lowercase();
                    self.key(event_loop, id, &key);
                }
            }
            _ => {}
        }
    }
}

fn main() {
    let autotest = std::env::args().any(|a| a == "--autotest");
    let event_loop = EventLoop::<UserEvent>::with_user_event().build().expect("event loop");
    event_loop.set_control_flow(ControlFlow::Wait);
    let mut app = App {
        autotest,
        windows: HashMap::new(),
        proxy: event_loop.create_proxy(),
        started: false,
        next_label: 0,
        exit_code: 0,
    };
    event_loop.run_app(&mut app).expect("run event loop");
    let code = app.exit_code;
    drop(app);
    std::process::exit(code);
}
