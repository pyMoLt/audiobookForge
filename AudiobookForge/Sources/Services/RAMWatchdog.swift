import Foundation
import Darwin

/// Monitors memory usage (RSS) of AudiobookForge and all its spawned child processes
/// (Python TTS bridges, Piper, FFmpeg) to protect macOS unified memory from exhaustion.
public final class RAMWatchdog: @unchecked Sendable {
    public static let shared = RAMWatchdog()

    /// Current resident memory of the host application in bytes.
    public static func hostResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    /// Resident memory of all direct child processes of this app in bytes.
    public static func childProcessesResidentBytes() -> UInt64 {
        let ppid = getpid()
        var pids = [pid_t](repeating: 0, count: 128)
        let bytesReturned = proc_listchildpids(ppid, &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytesReturned > 0 else { return 0 }
        let count = Int(bytesReturned) / MemoryLayout<pid_t>.size
        var totalBytes: UInt64 = 0
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var taskInfo = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            if size == MemoryLayout<proc_taskinfo>.size {
                totalBytes += taskInfo.pti_resident_size
            }
        }
        return totalBytes
    }

    /// Total memory of app + all child worker processes in megabytes.
    public static func totalResidentMB() -> Double {
        let total = hostResidentBytes() + childProcessesResidentBytes()
        return Double(total) / (1024.0 * 1024.0)
    }

    /// Starts a monitoring loop for the duration of a task.
    /// Returns a cancellable Task.
    public static func startMonitoring(
        limitMB: Int,
        checkIntervalMs: UInt64 = 1500,
        onExceeded: @escaping @Sendable (_ currentMB: Double, _ limitMB: Int) -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                let currentMB = totalResidentMB()
                if currentMB > Double(limitMB) {
                    onExceeded(currentMB, limitMB)
                    break
                }
                try? await Task.sleep(nanoseconds: checkIntervalMs * 1_000_000)
            }
        }
    }
}
