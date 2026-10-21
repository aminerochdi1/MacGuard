import Foundation
import Darwin

// MARK: - sysctl + subprocess helpers

enum Sys {
    static func u64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    static func i32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Runs a tool with a timeout and a fixed C locale (so numbers use "." even on a French system).
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return String(data: data, encoding: .utf8)
}

/// Like runTool but also returns the exit status and merges stderr into the output (for error messages).
func runToolFull(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> (output: String, status: Int32)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

// MARK: - CPU (Mach host_processor_info tick deltas, same source Activity Monitor uses)

struct CPUReading {
    var total: Double   // % busy across all cores (0-100)
    var user: Double
    var system: Double
    var idle: Double
    var cores: Int
}

final class CPUSampler {
    private var prev: [[UInt32]] = []

    init() { _ = sample() }  // prime so the first real reading has a baseline

    func sample() -> CPUReading? {
        var count: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info = info else { return nil }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let n = Int(count)
        let stride = Int(CPU_STATE_MAX)
        var cur: [[UInt32]] = []
        cur.reserveCapacity(n)
        for i in 0..<n {
            let b = i * stride
            cur.append([
                UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])
            ])
        }
        guard prev.count == n else { prev = cur; return nil }

        var u: UInt64 = 0, s: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<n {
            u &+= UInt64(cur[i][0] &- prev[i][0])
            s &+= UInt64(cur[i][1] &- prev[i][1])
            idle &+= UInt64(cur[i][2] &- prev[i][2])
            nice &+= UInt64(cur[i][3] &- prev[i][3])
        }
        prev = cur
        let total = u + s + idle + nice
        guard total > 0 else { return nil }
        let t = Double(total)
        return CPUReading(total: Double(u + s + nice) / t * 100,
                          user: Double(u + nice) / t * 100,
                          system: Double(s) / t * 100,
                          idle: Double(idle) / t * 100,
                          cores: n)
    }
}

// MARK: - Memory (Activity Monitor definitions)

enum MemPressure: String { case normal = "Normal", warning = "Warning", critical = "Critical" }

struct MemInfo {
    var total: UInt64
    var used: UInt64        // App + Wired + Compressed (Activity Monitor "Memory Used")
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64      // file cache + purgeable, reclaimable
    var swapUsed: UInt64
    var pressure: MemPressure
}

func readMemory() -> MemInfo? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS, let total = Sys.u64("hw.memsize") else { return nil }
    let page = Sys.u64("hw.pagesize") ?? 16384

    let internalPages = UInt64(stats.internal_page_count)
    let purgeable = UInt64(stats.purgeable_count)
    let appPages = internalPages > purgeable ? internalPages - purgeable : 0
    let wired = UInt64(stats.wire_count) * page
    let compressed = UInt64(stats.compressor_page_count) * page
    let app = appPages * page
    let cached = (UInt64(stats.external_page_count) + purgeable) * page

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    let swapUsed: UInt64 = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? UInt64(swap.xsu_used) : 0

    let level = Sys.i32("kern.memorystatus_vm_pressure_level") ?? 1
    let pressure: MemPressure = level >= 4 ? .critical : (level == 2 ? .warning : .normal)

    return MemInfo(total: total, used: app + wired + compressed, app: app, wired: wired,
                   compressed: compressed, cached: cached, swapUsed: swapUsed, pressure: pressure)
}

// MARK: - Formatting

func fmtBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
}

func fmtBytesFile(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
