import Foundation
import Darwin

struct ProcInfo: Identifiable {
    let id: Int32            // pid
    let name: String
    let path: String
    var cpu: Double          // % of ONE core (can exceed 100 on multi-core)
    var footprint: UInt64    // physical footprint, bytes
    var readable: Bool       // false = estimated via ps (other user's / root process)
}

/// Per-process CPU and memory via libproc `proc_pid_rusage`.
/// CPU time from rusage is in mach absolute time units, so it MUST be converted with
/// mach_timebase_info (125/3 on Apple Silicon, 1/1 on Intel) or values are wrong by ~40x.
final class ProcessSampler {
    private struct Prev { var cpuNs: UInt64; var start: UInt64 }
    private var prev: [Int32: Prev] = [:]
    private var lastWall: UInt64 = 0
    private var history: [Int32: [Double]] = [:]
    private var numer: UInt64 = 1
    private var denom: UInt64 = 1

    init() {
        var t = mach_timebase_info_data_t()
        if mach_timebase_info(&t) == KERN_SUCCESS, t.denom != 0 {
            numer = UInt64(t.numer)
            denom = UInt64(t.denom)
        }
    }

    private func toNs(_ t: UInt64) -> UInt64 { t &* numer / denom }

    /// Average CPU over the last `samples` readings, or nil if there is not enough history yet.
    func sustained(_ pid: Int32, samples: Int = 6) -> Double? {
        guard let h = history[pid], h.count >= samples else { return nil }
        let recent = h.suffix(samples)
        return recent.reduce(0, +) / Double(recent.count)
    }

    func sample() -> [ProcInfo] {
        let wallNow = toNs(mach_absolute_time())
        let dtWall: UInt64 = lastWall == 0 ? 0 : wallNow &- lastWall
        lastWall = wallNow

        var out: [ProcInfo] = []
        var seen = Set<Int32>()
        var unreadable = Set<Int32>()

        for pid in listPids() where pid > 0 {
            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { unreadable.insert(pid); continue }
            seen.insert(pid)

            let cpuNs = toNs(ri.ri_user_time &+ ri.ri_system_time)
            var cpu = 0.0
            if let p = prev[pid], p.start == ri.ri_proc_start_abstime, dtWall > 0, cpuNs >= p.cpuNs {
                cpu = Double(cpuNs - p.cpuNs) / Double(dtWall) * 100
            }
            prev[pid] = Prev(cpuNs: cpuNs, start: ri.ri_proc_start_abstime)

            var h = history[pid] ?? []
            h.append(cpu)
            if h.count > 12 { h.removeFirst(h.count - 12) }
            history[pid] = h

            let path = Self.path(pid)
            let name = path.isEmpty ? Self.shortName(pid) : (path as NSString).lastPathComponent
            out.append(ProcInfo(id: pid, name: name, path: path, cpu: cpu,
                                footprint: ri.ri_phys_footprint, readable: true))
        }

        // Prune state of processes that exited
        prev = prev.filter { seen.contains($0.key) }
        history = history.filter { seen.contains($0.key) }

        // Root/other-user processes cannot be read with libproc: estimate from `ps` so they are not invisible.
        if !unreadable.isEmpty {
            out.append(contentsOf: psFallback(unreadable))
        }
        return out
    }

    private func psFallback(_ wanted: Set<Int32>) -> [ProcInfo] {
        guard let text = runTool("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="], timeout: 5) else { return [] }
        var res: [ProcInfo] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), wanted.contains(pid),
                  let cpu = Double(f[1]), let rss = UInt64(f[2]) else { continue }
            let path = String(f[3])
            res.append(ProcInfo(id: pid, name: (path as NSString).lastPathComponent, path: path,
                                cpu: cpu, footprint: rss * 1024, readable: false))
        }
        return res
    }

    private func listPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got)))
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func shortName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "pid \(pid)"
    }

    /// Command-line arguments via sysctl KERN_PROCARGS2 (own processes only).
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }      // skip exec path
        while i < size, buf[i] == 0 { i += 1 }      // skip NUL padding
        var args: [String] = []
        while i < size, args.count < min(argc, 64) {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}
