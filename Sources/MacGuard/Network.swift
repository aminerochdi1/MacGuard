import Foundation
import Darwin
import SwiftUI

// MARK: - Model

struct NetApp: Identifiable {
    var id: String { name }
    let name: String
    let pid: Int32
    let down: Double   // bytes per second
    let up: Double
    var total: Double { down + up }
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
    func sample() -> [NetApp] {
        guard let out = runTool("/usr/bin/nettop",
                                ["-P", "-d", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"],
                                timeout: 8) else { return [] }
        return NetAppSampler.parse(out)
    }

    static func parse(_ text: String) -> [NetApp] {
        var samples: [[String: (pid: Int32, down: Double, up: Double)]] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.contains("bytes_in") { samples.append([:]); continue }
            if samples.isEmpty { continue }

            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // Find the "name.pid" field (skip a leading time stamp such as 12:34:56.123456)
            guard let i = f.firstIndex(where: { isProcessField($0) }) else { continue }
            let nums = f[(i + 1)...].compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count >= 2 else { continue }
            let down = nums[0], up = nums[1]
            let field = f[i]
            guard let dot = field.lastIndex(of: "."), let pid = Int32(field[field.index(after: dot)...]) else { continue }
            let name = String(field[..<dot]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }

            var cur = samples[samples.count - 1]
            let old = cur[name]
            cur[name] = (old?.pid ?? pid, (old?.down ?? 0) + down, (old?.up ?? 0) + up)
            samples[samples.count - 1] = cur
        }
        // Prefer the last sample (a delta); with only one sample the numbers are totals, so show nothing
        guard samples.count >= 2, let last = samples.last else { return [] }
        return last.map { NetApp(name: $0.key, pid: $0.value.pid, down: $0.value.down, up: $0.value.up) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
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

    var body: some View {
        Page {
            PageHeader(title: "Network",
                       subtitle: "Which apps are using the network right now. Updates every few seconds while this tab is open.")
            HStack(alignment: .top, spacing: 16) {
                StatCard(title: "Download", value: fmtRate(s.netDown), detail: "Whole Mac, Wi-Fi and Ethernet")
                StatCard(title: "Upload", value: fmtRate(s.netUp), detail: "Whole Mac, Wi-Fi and Ethernet")
            }
            appsTable
            Text("Per-app numbers come from macOS nettop, so they include every process you are allowed to see. Totals come from the network interface counters, so the two can differ slightly.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
        .onAppear { monitor.netWatch(true) }
        .onDisappear { monitor.netWatch(false) }
    }

    private var appsTable: some View {
        let rows = Array(s.netApps.prefix(25))
        let mx = max(rows.first?.total ?? 1, 1)
        return VStack(spacing: 0) {
            HStack {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("Activity").frame(width: 160, alignment: .leading)
                Text("Download").frame(width: 110, alignment: .trailing)
                Text("Upload").frame(width: 110, alignment: .trailing)
            }
            .font(.sans(13, .medium)).foregroundColor(Theme.slate)
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if rows.isEmpty {
                Text(s.netAppsReady ? "No app is using the network at the moment." : "Measuring… the first result takes about two seconds.")
                    .font(.sans(15)).foregroundColor(Theme.slate).padding(20)
            }
            ForEach(rows) { a in
                HStack {
                    Text(a.name).font(.sans(15)).foregroundColor(Theme.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Bar(fraction: a.total / mx, tint: Theme.ink).frame(width: 160)
                    Text(fmtRate(a.down)).monospacedDigit().frame(width: 110, alignment: .trailing)
                    Text(fmtRate(a.up)).monospacedDigit().frame(width: 110, alignment: .trailing)
                }
                .font(.sans(14)).foregroundColor(Theme.ink)
                .padding(.horizontal, 20).padding(.vertical, 9)
                Divider()
            }
        }
        .artifact()
    }
}
