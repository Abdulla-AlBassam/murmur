import AppKit

/// Watches for the fn (🌐) key globally using a listen-only CGEventTap.
/// Creating the tap fails until the app has been granted Accessibility
/// permission, so `startWithRetry` polls until it succeeds.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var fnIsDown = false

    private static let fnKeyCode: Int64 = 63  // kVK_Function

    func startWithRetry() {
        if start() {
            Log.info("Murmur: event tap started immediately")
            return
        }
        Log.info("Murmur: event tap unavailable, retrying… \(Self.permissionSummary())")
        var attempts = 0
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            attempts += 1
            if self.start() {
                timer.invalidate()
                self.retryTimer = nil
                Log.info("Murmur: event tap started after \(attempts) retries")
            } else if attempts >= 3 && AXIsProcessTrusted() {
                // The grant exists but this process predates it; macOS only
                // honours it for taps created by a fresh process. Relaunch
                // once (the marker argument prevents a relaunch loop).
                timer.invalidate()
                self.retryTimer = nil
                Self.relaunchAfterGrant()
            } else if attempts % 5 == 0 {
                Log.info("Murmur: event tap still unavailable. \(Self.permissionSummary())")
            }
        }
    }

    private static let relaunchMarker = "--post-grant-relaunch"

    private static func relaunchAfterGrant() {
        guard !CommandLine.arguments.contains(relaunchMarker) else {
            Log.info("Murmur: tap still failing after post-grant relaunch; giving up")
            return
        }
        Log.info("Murmur: Accessibility granted after launch; relaunching to pick it up")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [relaunchMarker]
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func permissionSummary() -> String {
        "accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess())"
    }

    @discardableResult
    private func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps it considers slow; re-enable and carry on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else { return }

        let fnNow = event.flags.contains(.maskSecondaryFn)
        guard fnNow != fnIsDown else { return }
        fnIsDown = fnNow
        Log.info("Murmur: fn \(fnNow ? "down" : "up")")
        DispatchQueue.main.async {
            fnNow ? self.onFnDown?() : self.onFnUp?()
        }
    }
}
