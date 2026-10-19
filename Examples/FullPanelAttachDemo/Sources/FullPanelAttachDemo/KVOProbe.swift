// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see ../../../../LICENSE).
//
// Optional, observe-only KVO probe for one NSWindow. It records what a window
// actually does for frame, styleMask, collectionBehavior and contentView; it
// asserts nothing about which of them notify. Main thread only.
//
// Observers are removed on stop(), when the window posts willClose, and in
// deinit (while the window is still alive), so a window never deallocates with
// this probe still registered.

import AppKit

final class KVOProbe: NSObject {
    static let keyPaths = ["frame", "styleMask", "collectionBehavior", "contentView"]
    private static let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    private(set) weak var window: NSWindow?
    private(set) var isObserving = false
    private(set) var counts: [String: Int] = [:]
    private(set) var events: [String] = []
    private(set) var registrations = 0
    private(set) var removals = 0
    /// Public class identity (-class) and the runtime class (object_getClass)
    /// when observation started. They may or may not differ; neither is a contract.
    let publicClass: String
    private(set) var runtimeClassAtStart = "-"
    private var closeToken: NSObjectProtocol?

    init(window: NSWindow) {
        self.window = window
        publicClass = NSStringFromClass(type(of: window).classForCoder())
        super.init()
    }

    deinit { stop(reason: "deinit") }

    var runtimeClassNow: String {
        window.flatMap { object_getClass($0) }.map { NSStringFromClass($0) } ?? "-"
    }

    var total: Int { counts.values.reduce(0, +) }

    func start() {
        guard !isObserving, let window else { return }
        isObserving = true
        runtimeClassAtStart = runtimeClassNow
        for key in Self.keyPaths {
            window.addObserver(self, forKeyPath: key, options: [.new], context: Self.context)
            registrations += 1
        }
        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in self?.stop(reason: "willClose") }
        log("start runtime=\(runtimeClassAtStart) public=\(publicClass)")
    }

    func stop(reason: String) {
        guard isObserving else { return }
        isObserving = false
        if let token = closeToken { NotificationCenter.default.removeObserver(token) }
        closeToken = nil
        if let window {
            for key in Self.keyPaths {
                window.removeObserver(self, forKeyPath: key, context: Self.context)
                removals += 1
            }
        }
        log("stop (\(reason))")
    }

    func resetCounts() { counts = [:] }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == Self.context, let keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        counts[keyPath, default: 0] += 1
    }

    var summary: String {
        let per = Self.keyPaths.map { "\($0.prefix(5))=\(counts[$0] ?? 0)" }.joined(separator: " ")
        return "\(isObserving ? "on" : "off") \(per) reg/rem \(registrations)/\(removals) runtime \(runtimeClassNow)"
    }

    private func log(_ event: String) {
        events.append(event)
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }
}
