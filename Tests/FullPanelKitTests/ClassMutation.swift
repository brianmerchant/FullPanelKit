// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// What a window class looks like to the Objective-C runtime, for the tests
// that attaching, enabling and entering never modify a window class.

import AppKit
import ObjectiveC

/// Selector -> implementation for the methods `cls` itself implements
/// (class_copyMethodList: inherited methods are not listed, added ones are).
func ownMethods(_ cls: AnyClass) -> [String: IMP] {
    var count: UInt32 = 0
    guard let list = class_copyMethodList(cls, &count) else { return [:] }
    defer { free(list) }
    var table: [String: IMP] = [:]
    for i in 0..<Int(count) {
        table[NSStringFromSelector(method_getName(list[i]))] = method_getImplementation(list[i])
    }
    return table
}

/// The classes from `cls` up to and including `root`.
func classChain(_ cls: AnyClass, to root: AnyClass = NSWindow.self) -> [AnyClass] {
    var chain: [AnyClass] = []
    var c: AnyClass? = cls
    while let current = c {
        chain.append(current)
        if current === root { break }
        c = class_getSuperclass(current)
    }
    return chain
}

/// Own method tables of every class in the chain, by class name.
func methodSnapshot(_ cls: AnyClass, to root: AnyClass = NSWindow.self) -> [String: [String: IMP]] {
    var snapshot: [String: [String: IMP]] = [:]
    for c in classChain(cls, to: root) { snapshot[NSStringFromClass(c)] = ownMethods(c) }
    return snapshot
}

/// Selectors of the classes from `cls` up to, but not including, `root` whose
/// implementation is a block trampoline (imp_implementationWithBlock), the way
/// runtime hooks are installed. The application's and the tests' own window
/// classes have none. AppKit's NSWindow does implement a few properties with
/// blocks (macOS 27: -_focusController and others), so it is excluded; its
/// method table is compared with methodSnapshot instead.
func blockImplementations(_ cls: AnyClass, to root: AnyClass = NSWindow.self) -> [String] {
    classChain(cls, to: root).filter { $0 !== root }.flatMap { c in
        ownMethods(c).compactMap { name, imp in
            imp_getBlock(imp) != nil ? "\(NSStringFromClass(c)) -\(name)" : nil
        }
    }.sorted()
}
