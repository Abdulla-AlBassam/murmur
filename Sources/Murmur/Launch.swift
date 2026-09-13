import Darwin
import Foundation

/// Launch and readiness timing. Every milestone is logged as milliseconds
/// since the process was exec'd, so `log show` gives real numbers instead
/// of impressions of how long startup takes.
enum Launch {
    /// Kernel-recorded process start time.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(getpid())]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    static func millisecondsSinceStart() -> Int {
        Int(Date().timeIntervalSince(processStart) * 1000)
    }

    static func milestone(_ name: String) {
        Log.info("Murmur: launch milestone '\(name)' at \(millisecondsSinceStart()) ms")
    }

    struct Stopwatch {
        private let start = DispatchTime.now()
        var ms: Int { Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6) }
    }
}
