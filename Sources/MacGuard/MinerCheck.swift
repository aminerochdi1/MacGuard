import SwiftUI
import AppKit

// MARK: - Model

enum CheckStatus { case clear, warning, found }

struct MinerCheckItem: Identifiable {
    let id: String
    let title: String
    let summary: String          // what this check looks at
    let status: CheckStatus
    let details: [String]
}

enum MinerVerdict {
    case clear, possible, likely

    var title: String {
        switch self {
        case .clear: return "No signs of crypto mining"
        case .possible: return "Possible mining activity"
        case .likely: return "Likely crypto miner found"
        }
    }
    var risk: Risk {
        switch self {
        case .clear: return .low
        case .possible: return .medium
        case .likely: return .high
        }
    }
}

struct MinerReport {
    let items: [MinerCheckItem]
    let date: Date
    let duration: TimeInterval

    var verdict: MinerVerdict {
        if items.contains(where: { $0.status == .found }) { return .likely }
        if items.contains(where: { $0.status == .warning }) { return .possible }
        return .clear
    }
}

// MARK: - Checks (all read-only; nothing is changed or removed)

enum MinerCheck {
    /// File names typical of miner binaries (kept to distinctive names to avoid false positives).
    static let fileNameTerms = ["xmrig", "xmr-stak", "minerd", "cpuminer", "ethminer", "nbminer", "lolminer",
                                "phoenixminer", "cgminer", "bfgminer", "nicehash", "minergate", "moneroocean", "c3pool"]

    /// Browser helper processes: an in-browser miner (cryptojacking) shows up as one of these running hot.
    static let browserNames = ["helper (renderer)", "chrome helper", "browser helper", "edge helper",
                               "webcontent", "web content", "firefox", "plugin-container"]

    static func run(procs: [ProcInfo], sustained: [Int32: Double], gui: Set<Int32>,
                    suspects: [Suspect], sig: SignatureChecker) -> MinerReport {
        let start = Date()
        let items: [MinerCheckItem] = [
            processCheck(suspects),
            cpuCheck(procs, sustained, gui, sig),
            networkCheck(sustained),
            persistenceCheck(sig),
            scheduledCheck(),
            fileCheck(),
            browserCheck(procs, sustained),
            extensionCheck()
        ]
        return MinerReport(items: items, date: Date(), duration: Date().timeIntervalSince(start))
    }

    private static func short(_ s: String, _ n: Int = 110) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    // 1. Running processes: miner names or miner command-line arguments
    private static func processCheck(_ suspects: [Suspect]) -> MinerCheckItem {
        let hits = suspects.filter { s in
            s.reasons.contains { $0.hasPrefix("Name or path matches known miner") || $0.hasPrefix("Command line contains") }
        }
        let details = hits.map { "\($0.name) (PID \($0.id)): \($0.reasons.first ?? "miner indicator")" }
        return MinerCheckItem(id: "proc", title: "Running processes",
                              summary: "Known miner names and command-line arguments (stratum, --donate-level, pool names).",
                              status: hits.isEmpty ? .clear : .found, details: details)
    }

    // 2. Background processes pinning the CPU
    private static func cpuCheck(_ procs: [ProcInfo], _ sustained: [Int32: Double], _ gui: Set<Int32>,
                                 _ sig: SignatureChecker) -> MinerCheckItem {
        var details: [String] = []
        for p in procs where p.id != getpid() && !p.path.isEmpty && !gui.contains(p.id) {
            guard let avg = sustained[p.id], avg >= 70 else { continue }
            let s = sig.check(p.path)
            if s == .apple { continue }
            details.append(String(format: "%@ (PID %d): %.0f%% CPU for the last readings · %@", p.name, p.id, avg, s.rawValue))
        }
        return MinerCheckItem(id: "cpu", title: "Sustained CPU use",
                              summary: "Non-Apple background processes using 70% of a core or more, without any window.",
                              status: details.isEmpty ? .clear : .warning, details: details)
    }

    // 3. Mining-pool connections
    private static func networkCheck(_ sustained: [Int32: Double]) -> MinerCheckItem {
        let conns = NetScanner.scan()
        let details = conns.map { "\($0.process) (PID \($0.pid)) → \($0.remote)" }
        let busy = conns.contains { (sustained[$0.pid] ?? 0) >= 50 }
        return MinerCheckItem(id: "net", title: "Mining-pool connections",
                              summary: "Open connections to ports commonly used by mining pools (your own processes only).",
                              status: conns.isEmpty ? .clear : (busy ? .found : .warning), details: details)
    }

    // 4. LaunchAgents / LaunchDaemons
    private static func persistenceCheck(_ sig: SignatureChecker) -> MinerCheckItem {
        let items = StartupScanner.scan(sig: sig) + PersistenceScanner.appInjection(sig: sig)
        var found: [String] = []
        var warn: [String] = []
        for i in items {
            if i.reasons.contains(where: { $0.hasPrefix("Matches known miner indicator") }) {
                found.append("\(i.label): \(i.reasons.first(where: { $0.hasPrefix("Matches known miner indicator") }) ?? "")")
            } else if i.risk != .low {
                warn.append("\(i.label) [\(i.risk.rawValue)]: \(i.reasons.first ?? "")")
            }
        }
        return MinerCheckItem(id: "persist", title: "Startup persistence",
                              summary: "LaunchAgents, LaunchDaemons and library injection that start miners or look suspicious.",
                              status: found.isEmpty ? (warn.isEmpty ? .clear : .warning) : .found,
                              details: found + warn)
    }

    // 5. Cron and shell startup files
    private static func scheduledCheck() -> MinerCheckItem {
        var found: [String] = []
        var warn: [String] = []

        func inspect(_ text: String, source: String) {
            for raw in text.split(whereSeparator: { $0.isNewline }) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let low = line.lowercased()
                if let t = Heuristics.minerTerm(in: line) {
                    found.append("\(source): \(short(line)) [\(t)]")
                } else if (low.contains("curl ") || low.contains("wget ")) &&
                            (low.contains("| sh") || low.contains("|sh") || low.contains("| bash") || low.contains("|bash")
                             || low.contains("base64 -d") || low.contains("base64 --decode")) {
                    warn.append("\(source): downloads and runs code: \(short(line))")
                }
            }
        }

        if let cron = runTool("/usr/bin/crontab", ["-l"], timeout: 5) { inspect(cron, source: "crontab") }

        let home = NSHomeDirectory()
        let fm = FileManager.default
        for f in [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile"] {
            let path = home + "/" + f
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue < 512_000,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            inspect(text, source: "~/" + f)
        }
        return MinerCheckItem(id: "sched", title: "Scheduled jobs and shell startup",
                              summary: "crontab and shell startup files (~/.zshrc and similar) for miner commands or download-and-run lines.",
                              status: found.isEmpty ? (warn.isEmpty ? .clear : .warning) : .found,
                              details: found + warn)
    }

    // 6. Miner files lying around in temp and user folders
    private static func fileCheck() -> MinerCheckItem {
        let home = NSHomeDirectory()
        let roots: [(String, Int)] = [
            ("/tmp", 3), ("/private/var/tmp", 3), ("/Users/Shared", 3),
            (home + "/Library/Application Support", 3), (home + "/.config", 3),
            (home + "/.local", 3), (home + "/Library/LaunchAgents", 1)
        ]
        var hits: [String] = []
        var visited = 0
        let fm = FileManager.default

        outer: for (root, depth) in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in en {
                visited += 1
                if visited > 40_000 { break outer }
                if en.level > depth { en.skipDescendants(); continue }
                let name = u.lastPathComponent.lowercased()
                if fileNameTerms.contains(where: { name.contains($0) }) {
                    hits.append("Miner-like file name: \(u.path)")
                    continue
                }
                if name == "config.json" || name == "pools.json" {
                    let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
                    if size <= 65_536, let text = try? String(contentsOf: u, encoding: .utf8) {
                        let low = text.lowercased()
                        let hasPool = low.contains("stratum+") || (low.contains("\"pools\"") &&
                            (low.contains("randomx") || low.contains("rx/0") || low.contains("cryptonight") || low.contains("\"algo\"")))
                        if hasPool { hits.append("Mining pool configuration: \(u.path)") }
                    }
                }
            }
        }
        return MinerCheckItem(id: "files", title: "Miner files on disk",
                              summary: "Miner-like file names and pool configuration files in temp, shared and app-support folders.",
                              status: hits.isEmpty ? .clear : .found, details: hits)
    }

    // 7. Browser tabs that may be mining
    // 8. Browser extensions: a mining extension is the other common way browsers get used for mining
    private static func extensionCheck() -> MinerCheckItem {
        let exts = PersistenceScanner.browserExtensions()
        var found: [String] = []
        for e in exts where e.reasons.contains(where: { $0.hasPrefix("Matches known miner indicator") }) {
            found.append("\(e.label) (\(e.scope)): \(e.reasons.first ?? "")")
        }
        return MinerCheckItem(id: "ext", title: "Browser extensions",
                              summary: "Chrome, Brave, Edge, Vivaldi, Opera, Arc and Firefox extensions that match known miner names. Safari extensions are not covered.",
                              status: found.isEmpty ? .clear : .found,
                              details: found.isEmpty ? ["\(exts.count) extensions checked."] : found)
    }

    private static func browserCheck(_ procs: [ProcInfo], _ sustained: [Int32: Double]) -> MinerCheckItem {
        var details: [String] = []
        for p in procs {
            let n = p.name.lowercased()
            guard browserNames.contains(where: { n.contains($0) }), let avg = sustained[p.id], avg >= 60 else { continue }
            details.append(String(format: "%@ (PID %d): %.0f%% CPU continuously. A tab may be mining or just heavy; open the browser's task manager (Chrome: Shift+Esc) and close the busiest tab.", p.name, p.id, avg))
        }
        return MinerCheckItem(id: "browser", title: "Browser tabs (cryptojacking)",
                              summary: "Browser helper processes running hot for a long time, the usual sign of an in-page miner.",
                              status: details.isEmpty ? .clear : .warning, details: details)
    }
}

// MARK: - View

struct StatusTag: View {
    let status: CheckStatus

    private var label: String {
        switch status { case .clear: return "Clear"; case .warning: return "Check"; case .found: return "Found" }
    }
    private var color: Color {
        switch status { case .clear: return Theme.low; case .warning: return Theme.mid; case .found: return Theme.high }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.sans(13, .medium))
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
            Spacer(minLength: 0)
        }
        .frame(width: 68)
        .accessibilityLabel("Status \(label)")
    }
}

struct MinerCheckView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            verdictCard
            HStack(spacing: 12) {
                Button("Run miner check") { monitor.runMinerCheck(auto: false) }
                    .buttonStyle(PillStyle(kind: .filled)).disabled(s.minerBusy)
                if s.minerBusy { Text("Checking…").font(.sans(14)).foregroundColor(Theme.slate) }
            }
            if let r = s.minerReport {
                VStack(spacing: 0) {
                    ForEach(r.items) { item in
                        MinerCheckRow(item: item)
                        Divider()
                    }
                }
                .artifact()
            }
            Text("MacGuard can’t see miners that use only the GPU, hide inside a signed app, or run as root beyond a CPU estimate. “Found” means strong evidence, “Check” means worth a look. If something is found: quit the process, remove its startup item, then run a full scan with Malwarebytes or KnockKnock. Nothing is removed automatically.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crypto miner check").font(.sans(14)).foregroundColor(Theme.slate)
            if let r = s.minerReport {
                HStack(spacing: 12) {
                    Text(r.verdict.title).font(.serif(30)).tracking(-0.4).foregroundColor(Theme.ink)
                    RiskTag(risk: r.verdict.risk)
                }
                Text("Last run \(r.date.formatted(date: .omitted, time: .standard)) in \(String(format: "%.1f", r.duration)) s · runs automatically every 30 minutes when enabled in Settings")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            } else {
                Text(s.minerBusy ? "Checking…" : "Not run yet").font(.serif(30)).tracking(-0.4).foregroundColor(Theme.ink)
                Text("Eight read-only checks: processes, CPU, network, startup items, scheduled jobs, files, browser tabs and browser extensions.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            }
        }
        .card(padding: 24)
    }
}

struct MinerCheckRow: View {
    let item: MinerCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusTag(status: item.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.sans(16, .medium)).foregroundColor(Theme.ink)
                Text(item.summary).font(.sans(14)).foregroundColor(Theme.slate)
                ForEach(item.details.prefix(8), id: \.self) { d in
                    Text("• " + d).font(.sans(14)).foregroundColor(Theme.ink)
                }
                if item.details.count > 8 {
                    Text("… and \(item.details.count - 8) more").font(.sans(14)).foregroundColor(Theme.slate)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
