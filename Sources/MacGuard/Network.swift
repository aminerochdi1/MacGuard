import Foundation
import Darwin
import SwiftUI
import AppKit

// MARK: - Model

struct NetApp: Identifiable {
    var id: Int32 { pid }
    let name: String
    let pid: Int32
    var down: Double          // bytes per second right now
    var up: Double
    var totalDown: Double     // bytes since the Network tab was opened
    var totalUp: Double
    var idle: Bool            // not using the network at the moment (kept in the list for a while)
    var total: Double { down + up }
    var sessionTotal: Double { totalDown + totalUp }
}

/// Raw per-process reading from one nettop sample.
struct NetReading {
    let name: String
    let pid: Int32
    let down: Double
    let up: Double
}

/// Path of a running process (nil if it has exited).
func pidPath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}

func fmtRate(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond < 1 { return "0 KB/s" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
}

// MARK: - Whole-Mac totals from interface counters (cheap, runs on every sample)

final class NetTotalsSampler {
    private var prev: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastTime: Date?

    /// Returns (download, upload) in bytes per second since the previous call, or nil on the first call.
    func sample() -> (down: Double, up: Double)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {                       // Wi-Fi and Ethernet; skips loopback, VPN tunnels, AirDrop
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    current[name] = (d.ifi_ibytes, d.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }

        let now = Date()
        defer { prev = current; lastTime = now }
        guard let last = lastTime else { return nil }
        let dt = now.timeIntervalSince(last)
        guard dt > 0.2 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, c) in current {
            guard let p = prev[name] else { continue }
            rx += UInt64(c.rx &- p.rx)                          // wrapping subtraction: counters are 32-bit
            tx += UInt64(c.tx &- p.tx)
        }
        return (Double(rx) / dt, Double(tx) / dt)
    }
}

// MARK: - Per-app rates via `nettop` (ships with macOS, no root needed). Runs only while a view needs it.

final class NetAppSampler {
    /// Takes about 1-2 seconds: nettop is asked for two one-second samples and the second (delta) one is used.
    func sample() -> [NetReading] {
        guard let out = runTool("/usr/bin/nettop",
                                ["-P", "-d", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"],
                                timeout: 8) else { return [] }
        return NetAppSampler.parse(out)
    }

    static func parse(_ text: String) -> [NetReading] {
        var samples: [[Int32: NetReading]] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.contains("bytes_in") { samples.append([:]); continue }
            if samples.isEmpty { continue }

            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // Find the "name.pid" field (skip a leading time stamp such as 12:34:56.123456)
            guard let i = f.firstIndex(where: { isProcessField($0) }) else { continue }
            let nums = f[(i + 1)...].compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count >= 2 else { continue }
            let field = f[i]
            guard let dot = field.lastIndex(of: "."), let pid = Int32(field[field.index(after: dot)...]) else { continue }
            let name = String(field[..<dot]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            samples[samples.count - 1][pid] = NetReading(name: name, pid: pid, down: nums[0], up: nums[1])
        }
        // The last sample is a one-second delta; with only one sample the numbers are totals, so show nothing
        guard samples.count >= 2, let last = samples.last else { return [] }
        return last.values.filter { $0.down + $0.up > 0 }.sorted { $0.down + $0.up > $1.down + $1.up }
    }

    private static func isProcessField(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: "."), Int32(s[s.index(after: dot)...]) != nil else { return false }
        // time stamps look like 12:34:56.123456
        if s.count >= 8, s.dropFirst(2).first == ":" { return false }
        return !s[..<dot].isEmpty
    }
}

// MARK: - View

struct NetworkView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor
    @State private var bySession = false
    @State private var selected: Int32?

    private var rows: [NetApp] {
        let list = s.netApps.sorted {
            if bySession { return $0.sessionTotal > $1.sessionTotal }
            return $0.total != $1.total ? $0.total > $1.total : $0.sessionTotal > $1.sessionTotal
        }
        return Array(list.prefix(40))
    }

    private var selectedApp: NetApp? { s.netApps.first { $0.pid == selected } }

    var body: some View {
        Page {
            PageHeader(title: "Network",
                       subtitle: "Apps that use the network, updated live. Right-click a row to quit an app. Apps stay listed for two minutes after they go quiet.")
            HStack(alignment: .top, spacing: 16) {
                StatCard(title: "Download", value: fmtRate(s.netDown), detail: "Whole Mac, Wi-Fi and Ethernet")
                StatCard(title: "Upload", value: fmtRate(s.netUp), detail: "Whole Mac, Wi-Fi and Ethernet")
            }
            controls
            appsTable
            Text("Per-app numbers come from macOS nettop and refresh every couple of seconds while this tab is open. Totals come from the network interface counters, so the two can differ slightly. “This session” counts since you opened this tab.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
        .onAppear { monitor.netWatch(true) }
        .onDisappear { monitor.netWatch(false) }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Busiest now") { bySession = false }.buttonStyle(PillStyle(kind: bySession ? .ghost : .filled))
            Button("Most this session") { bySession = true }.buttonStyle(PillStyle(kind: bySession ? .filled : .ghost))
            Spacer()
            if let a = selectedApp {
                Text("\(a.name) selected").font(.sans(14)).foregroundColor(Theme.slate)
                Button("Quit") { quit(a, force: false) }.buttonStyle(PillStyle(kind: .ghost))
                Button("Force quit") { quit(a, force: true) }.buttonStyle(PillStyle(kind: .filled))
            }
        }
    }

    private var appsTable: some View {
        let list = rows
        let mx = max(list.map { $0.total }.max() ?? 1, 1)
        return VStack(spacing: 0) {
            HStack {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("Activity").frame(width: 140, alignment: .leading)
                Text("Download").frame(width: 100, alignment: .trailing)
                Text("Upload").frame(width: 100, alignment: .trailing)
                Text("This session").frame(width: 110, alignment: .trailing)
            }
            .font(.sans(13, .medium)).foregroundColor(Theme.slate)
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if list.isEmpty {
                Text(s.netAppsReady ? "No app is using the network at the moment." : "Measuring… the first result takes about two seconds.")
                    .font(.sans(15)).foregroundColor(Theme.slate).padding(20)
            }
            ForEach(list) { a in
                row(a, maxRate: mx)
                Divider()
            }
        }
        .artifact()
    }

    private func row(_ a: NetApp, maxRate: Double) -> some View {
        HStack {
            HStack(spacing: 8) {
                Text(a.name).lineLimit(1)
                Text("PID \(a.pid)").font(.sans(12)).foregroundColor(Theme.slate)
                if a.idle { Text("idle").font(.sans(12)).foregroundColor(Theme.slate) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Bar(fraction: a.total / maxRate, tint: Theme.ink).frame(width: 140)
            Text(fmtRate(a.down)).monospacedDigit().frame(width: 100, alignment: .trailing)
            Text(fmtRate(a.up)).monospacedDigit().frame(width: 100, alignment: .trailing)
            Text(ByteCountFormatter.string(fromByteCount: Int64(a.sessionTotal), countStyle: .decimal))
                .monospacedDigit().foregroundColor(Theme.slate).frame(width: 110, alignment: .trailing)
        }
        .font(.sans(14)).foregroundColor(a.idle ? Theme.slate : Theme.ink)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(selected == a.pid ? Theme.mist : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = a.pid }
        .contextMenu {
            Button("Quit “\(a.name)”") { quit(a, force: false) }
            Button("Force Quit “\(a.name)”") { quit(a, force: true) }
            Divider()
            if let p = pidPath(a.pid) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(a.pid), forType: .string)
            }
        }
    }

    private func quit(_ a: NetApp, force: Bool) {
        ProcessActions.confirmAndTerminate(pid: a.pid, name: a.name, force: force, state: s)
    }
}
