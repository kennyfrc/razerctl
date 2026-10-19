import Foundation
import ApplicationServices

/// Swallows the mouse's side buttons at the system level. Razer's HID protocol has no button
/// remap command, so this is where "the side buttons do nothing" has to happen on macOS.
///
/// Side buttons arrive as "other" mouse buttons 3 (back) and 4 (forward). A session event tap
/// that returns nil for their down/up events stops them reaching any app, including the
/// browser, so Back does not fire in Safari or Chrome either.
///
/// An event tap needs the Accessibility grant. Input Monitoring is not enough.
final class ButtonFilter {
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var swallowSide = false

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Asks the system to list this binary under Accessibility so the user can turn it on.
    /// The prompt only appears once per binary identity.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Starts or stops the tap to match the spec. Returns what is now true, not what was asked.
    @discardableResult
    func sync(swallow: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if swallow == isRunning, swallow == swallowSide { return swallow }
        if !swallow {
            stopLocked()
            return false
        }
        guard ButtonFilter.hasAccessibility else {
            // Prompt once; the user still has to flip the switch in System Settings.
            ButtonFilter.requestAccessibility()
            stopLocked()
            return false
        }
        return startLocked()
    }

    var isRunning: Bool { thread != nil }

    private func startLocked() -> Bool {
        guard thread == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        var started = false

        let worker = Thread { [weak self] in
            let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue)
                | (1 << CGEventType.otherMouseUp.rawValue)
                | (1 << CGEventType.otherMouseDragged.rawValue)
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, _, event, _ in
                    let button = event.getIntegerValueField(.mouseEventButtonNumber)
                    // 3 is back, 4 is forward. Returning nil swallows the event.
                    if button == 3 || button == 4 { return nil }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            )

            guard let tap else {
                ready.signal()
                return
            }
            started = true
            self?.runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        worker.stackSize = 512 * 1024
        worker.start()
        ready.wait()

        if started {
            thread = worker
            swallowSide = true
        }
        return started
    }

    private func stopLocked() {
        if let runLoop {
            CFRunLoopStop(runLoop)
            self.runLoop = nil
        }
        thread = nil
        swallowSide = false
    }
}
