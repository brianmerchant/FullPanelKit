// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).

import AppKit
import Combine
import FullPanelKit
import SwiftUI

/// Per-window demo state. Owns nothing of the window: the window owns its
/// FullPanelSession, and the model only follows it.
@MainActor
final class WindowModel: NSObject, ObservableObject {
    /// `.appkit` / `.appkitControl` are ordinary NSWindows created in code
    /// (see AppKitWindows.swift); only `.appkit` is offered to FullPanelSession.
    /// `.appkitSubclass` is an application-defined NSWindow subclass, attached.
    enum Role: String { case attached, ordinary, appkit, appkitControl, appkitSubclass }

    let role: Role
    /// Weak: the window owns its session.
    private(set) weak var session: FullPanelSession? {
        willSet { objectWillChange.send() }
    }
    @Published private(set) var layout = FullPanelLayout()
    @Published private(set) var diagnostics: [String: Any] = [:]
    @Published private(set) var lastError: String?
    private(set) var lastErrorCode: Int?
    private(set) var kvoProbe: KVOProbe?
    @Published var leftClicks = 0
    @Published var rightClicks = 0
    private(set) weak var window: NSWindow?
    private var status: FullPanelStatus?
    private var layoutSink: AnyCancellable?
    private var timer: Timer?
    private var willEnterAttachToken: NSObjectProtocol?

    init(role: Role) {
        self.role = role
        super.init()
    }

    deinit { timer?.invalidate(); kvoProbe?.stop(reason: "model deinit") }

    /// Called by WindowAttacher whenever SwiftUI (re)places the view.
    func windowDidChange(_ newWindow: NSWindow?) {
        guard let newWindow, newWindow !== window else { return }
        window = newWindow
        DemoRegistry.shared.add(self)
        ScenarioTest.shared?.event("windowDidChange(\(role.rawValue))", newWindow)
        if role == .attached || role == .appkit || role == .appkitSubclass,
           !UserDefaults.standard.bool(forKey: "FullPanelAttachManual") {
            // -FullPanelAttachDelayMs simulates a host that attaches late;
            // -FullPanelAttachOnWillEnter YES, one that attaches from its own
            // willEnterFullScreen observer (inside the entry's notification).
            let delay = UserDefaults.standard.integer(forKey: "FullPanelAttachDelayMs")
            if UserDefaults.standard.bool(forKey: "FullPanelAttachOnWillEnter") {
                willEnterAttachToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.willEnterFullScreenNotification, object: newWindow, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let token = self.willEnterAttachToken {
                            NotificationCenter.default.removeObserver(token)
                            self.willEnterAttachToken = nil
                        }
                        self.attach()
                    }
                }
            } else if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    MainActor.assumeIsolated { self?.attach() }
                }
            } else {
                attach()
            }
        }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func attach() {
        guard let window, session == nil else { return }
        do {
            let session = try FullPanelSession.attach(to: window)
            session.isEnabled = true
            bind(session)
            ScenarioTest.shared?.event("attached+enabled", window)
            lastError = nil
            lastErrorCode = nil
        } catch {
            lastError = error.localizedDescription
            lastErrorCode = (error as NSError).code
        }
        refresh()
    }

    func detach() {
        session?.detach()
        session = nil
        status = nil
        layoutSink = nil
        layout = FullPanelLayout()
        refresh()
    }

    var isEnabled: Bool {
        get { session?.isEnabled ?? false }
        set {
            session?.isEnabled = newValue
            objectWillChange.send()
            refresh()
        }
    }

    var isKVOEnabled: Bool { kvoProbe?.isObserving ?? false }

    func setKVO(_ on: Bool) {
        objectWillChange.send()
        if on {
            guard let window else { return }
            let probe = kvoProbe?.window === window ? kvoProbe! : KVOProbe(window: window)
            kvoProbe = probe
            probe.start()
        } else {
            kvoProbe?.stop(reason: "requested")
        }
        refresh()
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    private func bind(_ session: FullPanelSession) {
        self.session = session
        let status = FullPanelStatus(session: session)
        self.status = status
        layoutSink = status.$layout.sink { [weak self] layout in self?.layout = layout }
    }

    func refresh() {
        var d: [String: Any] = session?.diagnostics() ?? [:]
        if let window {
            d["windowFrame"] = NSStringFromRect(window.frame)
            d["windowPointer"] = String(format: "%p", unsafeBitCast(window, to: Int.self))
            d["windowClass"] = NSStringFromClass(type(of: window).classForCoder())
            d["windowRuntimeClass"] = NSStringFromClass(object_getClass(window)!)
            d["delegateClass"] = window.delegate.map { NSStringFromClass(type(of: $0 as AnyObject)) } ?? "nil"
            d["windowControllerClass"] = window.windowController.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            d["inFullScreen"] = window.styleMask.contains(.fullScreen)
            d["screenFrame"] = window.screen.map { NSStringFromRect($0.frame) } ?? "none"
            d["contentViewBounds"] = window.contentView.map { NSStringFromRect($0.bounds) } ?? "none"
        }
        d["attached"] = session?.isAttached ?? false
        d["role"] = role.rawValue
        if let kvoProbe { d["kvo"] = kvoProbe.summary }
        if let window, let summary = AppKitWindows.delegateSummary(for: window) { d["delegateEvents"] = summary }
        diagnostics = d
    }
}

/// Weakly tracks the demo's window models (for the autotest and menus).
@MainActor
final class DemoRegistry {
    static let shared = DemoRegistry()
    private let table = NSHashTable<WindowModel>.weakObjects()
    var openWindow: ((String) -> Void)?

    func add(_ model: WindowModel) { table.add(model) }
    var models: [WindowModel] { table.allObjects.filter { $0.window != nil } }
}
