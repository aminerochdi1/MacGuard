import SwiftUI
import AppKit

// Steep-styled, static UI: no animations, every status has a text label (color is never the only signal).

enum AppTab: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "History", processes = "Processes", startup = "Startup"
    case security = "Security", storage = "Storage", network = "Network", battery = "Battery", settings = "Settings"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var s: AppState
    @ObservedObject var settings: Settings
    let monitor: Monitor
    @State private var tab: AppTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if let n = s.notice { noticeBar(n) }
            content
        }
        .frame(minWidth: 1100, minHeight: 560)
        .background(Theme.canvas)
        .transaction { $0.animation = nil }
    }

    private var navBar: some View {
        HStack(spacing: 4) {
            Button(action: { AboutWindow.shared.show() }) {
                Text("MacGuard").font(.serif(24)).tracking(-0.3).foregroundColor(Theme.ink)
            }
            .buttonStyle(.plain)
            .help("About MacGuard")
            .padding(.trailing, 16)
            ForEach(AppTab.allCases) { t in
                NavItem(title: t.rawValue, selected: tab == t) { tab = t }
            }
            Spacer()
            Text(s.statusText).font(.sans(14)).foregroundColor(Theme.slate)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 12) {
            Text(text).font(.sans(14)).foregroundColor(Theme.ink).lineLimit(2)
            Spacer()
            ArrowLink(title: "Dismiss") { s.notice = nil }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.mist))
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewView(s: s)
        case .history: HistoryView(s: s)
        case .processes: ProcessesView(s: s)
        case .startup: StartupView(s: s, monitor: monitor, settings: settings)
        case .security: SecurityView(s: s, monitor: monitor, settings: settings)
        case .storage: StorageView(s: s, monitor: monitor)
        case .network: NetworkView(s: s, monitor: monitor)
        case .battery: BatteryView(s: s)
        case .settings: SettingsView(settings: settings, s: s)
        }
    }
}

struct NavItem: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sans(15, selected ? .medium : .regular))
                .foregroundColor(selected ? Theme.onInk : Theme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(selected ? Theme.ink : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct Page<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(28)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Overview

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var fraction: Double? = nil
    var tint: Color = Theme.ink
    var valueColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sans(14)).foregroundColor(Theme.slate)
            Text(value).font(.sans(26, .medium)).monospacedDigit().foregroundColor(valueColor ?? Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            if let f = fraction { Bar(fraction: f, tint: tint) }
            Text(detail).font(.sans(14)).foregroundColor(Theme.slate).lineLimit(2)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct OverviewView: View {
    @ObservedObject var s: AppState

    var body: some View {
        Page {
            PageHeader(title: "Overview", subtitle: "Live readings, refreshed every two seconds.")
            HStack(alignment: .top, spacing: 16) {
                cpuCard
                tempCard
                memCard
                diskCard
            }
            HStack(alignment: .top, spacing: 16) {
                topCPU
                topMemory
            }
            HStack(alignment: .top, spacing: 16) {
                heatCard
            }
            HStack(alignment: .top, spacing: 16) {
                batteryCard
                networkCard
            }
            sensors
        }
    }

    private var cpuCard: some View {
        let v = s.cpu?.total ?? 0
        let detail = s.cpu.map { String(format: "User %.0f%% · System %.0f%% · %d cores", $0.user, $0.system, $0.cores) } ?? "Measuring…"
        let c = Theme.usage(v)
        return StatCard(title: "CPU", value: s.cpu == nil ? "--" : String(format: "%.0f%%", v),
                        detail: s.cpu == nil ? detail : "\(Theme.usageLabel(v)) · " + detail,
                        fraction: v / 100, tint: c, valueColor: s.cpu == nil ? nil : c)
    }

    private var tempCard: some View {
        if !s.tempsEnabled {
            return StatCard(title: "CPU temperature", value: "Off", detail: "Turned off in Settings. Thermal state: \(s.thermal)")
        }
        if let t = s.temps, let avg = t.cpuAvg, let mx = t.cpuMax {
            return StatCard(title: "CPU temperature", value: String(format: "%.0f °C", avg),
                            detail: String(format: "Hottest sensor %.0f °C · Thermal state: %@", mx, s.thermal),
                            fraction: avg / 110, tint: mx >= 90 ? Theme.high : (mx >= 80 ? Theme.mid : Theme.ink))
        }
        return StatCard(title: "CPU temperature", value: "n/a", detail: "Sensor not available. Thermal state: \(s.thermal)")
    }

    private var memCard: some View {
        guard let m = s.mem else { return StatCard(title: "Memory", value: "--", detail: "Measuring…") }
        let frac = Double(m.used) / Double(max(m.total, 1))
        var pct = frac * 100
        if m.pressure == .critical { pct = max(pct, 85) } else if m.pressure == .warning { pct = max(pct, 60) }
        let tint = Theme.usage(pct)
        return StatCard(title: "Memory (RAM)", value: String(format: "%.0f%%", frac * 100),
                        detail: "\(Theme.usageLabel(pct)) · \(fmtBytes(m.used)) of \(fmtBytes(m.total)) · pressure \(m.pressure.rawValue) · swap \(fmtBytes(m.swapUsed))",
                        fraction: frac, tint: tint, valueColor: tint)
    }

    private var diskCard: some View {
        guard let d = s.storage else { return StatCard(title: "Disk free", value: "--", detail: "Measuring…") }
        let used = 1 - Double(d.available) / Double(max(d.total, 1))
        let tint: Color = used >= 0.9 ? Theme.high : (used >= 0.8 ? Theme.mid : Theme.ink)
        return StatCard(title: "Disk free", value: fmtBytesFile(d.available), detail: "of \(fmtBytesFile(d.total))",
                        fraction: used, tint: tint)
    }

    private var batteryCard: some View {
        guard let b = s.battery else {
            return StatCard(title: "Battery", value: "No battery", detail: "This Mac runs on power only")
        }
        let level = BatteryLevel(percent: b.percent)
        var detail = "\(level.label) · \(b.stateText)"
        if let w = b.watts, abs(w) >= 0.3 { detail += String(format: " · %.1f W", abs(w)) }
        if let h = b.healthPercent { detail += String(format: " · health %.0f%%", h) }
        return StatCard(title: "Battery", value: "\(b.percent)%", detail: detail, fraction: Double(b.percent) / 100,
                        tint: level.color, valueColor: level.color)
    }

    private var networkCard: some View {
        StatCard(title: "Network", value: "↓ \(fmtRate(s.netDown))",
                 detail: "↑ \(fmtRate(s.netUp)) · open the Network tab to see which apps")
    }

    private var topCPU: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top CPU users now").font(.sans(17, .medium)).foregroundColor(Theme.ink)
            ForEach(s.procs.prefix(5)) { p in
                HStack {
                    Text(p.name).font(.sans(15)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", p.cpu)).font(.sans(15)).monospacedDigit()
                        .foregroundColor(Theme.usage(p.cpu)).frame(width: 60, alignment: .trailing)
                    Text(fmtBytes(p.footprint)).font(.sans(14)).monospacedDigit()
                        .foregroundColor(Theme.slate).frame(width: 90, alignment: .trailing)
                }
                .foregroundColor(Theme.ink)
            }
            if s.procs.isEmpty { Text("Collecting data…").font(.sans(15)).foregroundColor(Theme.slate) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .artifact()
    }

    private var topMemory: some View {
        let total = Double(max(s.mem?.total ?? 1, 1))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Top memory users now").font(.sans(17, .medium)).foregroundColor(Theme.ink)
            ForEach(s.procs.sorted { $0.footprint > $1.footprint }.prefix(5)) { p in
                let pct = Double(p.footprint) / total * 100
                HStack {
                    Text(p.name).font(.sans(15)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", pct)).font(.sans(14)).monospacedDigit()
                        .foregroundColor(Theme.slate).frame(width: 60, alignment: .trailing)
                    Text(fmtBytes(p.footprint)).font(.sans(15)).monospacedDigit()
                        .foregroundColor(Theme.usage(pct * 4)).frame(width: 90, alignment: .trailing)
                }
                .foregroundColor(Theme.ink)
            }
            if s.procs.isEmpty { Text("Collecting data…").font(.sans(15)).foregroundColor(Theme.slate) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .artifact()
    }

    /// The one peach accent card on this page.
    private var heatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heat contributors").font(.sans(22, .medium)).tracking(-0.23)
            if s.heat.isEmpty {
                Text("None so far. When the CPU runs hot (80 °C or more, or macOS reports a raised thermal state), the busiest apps at that moment are counted here.")
                    .font(.sans(15))
            }
            ForEach(s.heat) { h in
                HStack {
                    Text(h.name).font(.sans(16))
                    Spacer()
                    Text("\(h.count) hot samples").font(.sans(14)).monospacedDigit()
                }
            }
        }
        .foregroundColor(Theme.sienna)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.peach)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder private var sensors: some View {
        if let t = s.temps {
            DisclosureGroup("All temperature sensors on this Mac (\(t.sensors.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(t.sensors) { x in
                        HStack {
                            Text(x.name).font(.sans(14))
                            Spacer()
                            Text(String(format: "%.1f °C", x.value)).font(.sans(14)).monospacedDigit()
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.sans(15))
            .foregroundColor(Theme.ink)
        }
    }
}

// MARK: - Processes

struct ProcessesView: View {
    @ObservedObject var s: AppState
    @State private var byMemory = false
    @State private var selected: Int32?

    private var rows: [ProcInfo] {
        let list = byMemory ? s.procs.sorted { $0.footprint > $1.footprint } : s.procs
        return Array(list.prefix(40))
    }

    private var selectedProc: ProcInfo? { s.procs.first { $0.id == selected } }

    var body: some View {
        Page {
            PageHeader(title: "Processes",
                       subtitle: "Right-click a row to quit an app. CPU is per core: 200% means two cores fully busy.")
            controls
            VStack(spacing: 0) {
                headerRow
                Divider()
                ForEach(rows) { p in row(p) }
            }
            .artifact()
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("By CPU") { byMemory = false }.buttonStyle(PillStyle(kind: byMemory ? .ghost : .filled))
            Button("By memory") { byMemory = true }.buttonStyle(PillStyle(kind: byMemory ? .filled : .ghost))
            Spacer()
            if let p = selectedProc {
                Text("\(p.name) selected").font(.sans(14)).foregroundColor(Theme.slate)
                Button(s.paused.contains(p.id) ? "Resume" : "Pause") { ProcessActions.togglePause(pid: p.id, name: p.name, state: s) }
                    .buttonStyle(PillStyle(kind: .ghost))
                Button("Quit") { quit(p, force: false) }.buttonStyle(PillStyle(kind: .ghost))
                Button("Force quit") { quit(p, force: true) }.buttonStyle(PillStyle(kind: .filled))
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("PID").frame(width: 70, alignment: .trailing)
            Text("CPU").frame(width: 80, alignment: .trailing)
            Text("Memory").frame(width: 100, alignment: .trailing)
            Text("Source").frame(width: 90, alignment: .trailing)
        }
        .font(.sans(13, .medium))
        .foregroundColor(Theme.slate)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func row(_ p: ProcInfo) -> some View {
        HStack {
            HStack(spacing: 8) {
                Text(p.name).lineLimit(1)
                if s.paused.contains(p.id) { Text("paused").font(.sans(12)).foregroundColor(Theme.mid) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.id)").monospacedDigit().frame(width: 70, alignment: .trailing).foregroundColor(Theme.slate)
            Text(String(format: "%.1f%%", p.cpu)).monospacedDigit().frame(width: 80, alignment: .trailing)
                .foregroundColor(Theme.load(p.cpu))
            Text(fmtBytes(p.footprint)).monospacedDigit().frame(width: 100, alignment: .trailing)
            Text(p.readable ? "Measured" : "Estimated").frame(width: 90, alignment: .trailing).foregroundColor(Theme.slate)
        }
        .font(.sans(14))
        .foregroundColor(Theme.ink)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(selected == p.id ? Theme.mist : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = p.id }
        .contextMenu {
            Button(s.paused.contains(p.id) ? "Resume “\(p.name)”" : "Pause “\(p.name)”") {
                ProcessActions.togglePause(pid: p.id, name: p.name, state: s)
            }
            Button("Quit “\(p.name)”") { quit(p, force: false) }
            Button("Force Quit “\(p.name)”") { quit(p, force: true) }
            Divider()
            if !p.path.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
            }
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(p.id)", forType: .string)
            }
        }
    }

    private func quit(_ p: ProcInfo, force: Bool) {
        ProcessActions.confirmAndTerminate(pid: p.id, name: p.name, force: force, state: s)
    }
}

// MARK: - Startup items

struct StartupView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor
    let settings: Settings
    @State private var section = 0

    private var sections: [(String, StartupCategory)] {
        [("Launch items", .launch), ("Shell & cron", .shell), ("Browser extensions", .browser)]
    }

    private var rows: [StartupItem] {
        s.startup.filter { $0.category == sections[section].1 }
    }

    private var fresh: [StartupItem] { s.startup.filter { $0.isNew } }

    var body: some View {
        Page {
            PageHeader(title: "Startup items",
                       subtitle: "Everything that can start by itself: LaunchAgents and Daemons, shell files, cron and browser extensions. Login Items are in System Settings > General > Login Items.")
            HStack(spacing: 12) {
                Button("Scan startup items") { monitor.scanStartup() }
                    .buttonStyle(PillStyle(kind: .ghost)).disabled(s.startupBusy)
                if s.startupBusy { Text("Scanning…").font(.sans(14)).foregroundColor(Theme.slate) }
            }
            if !fresh.isEmpty { newBanner }
            HStack(spacing: 8) {
                ForEach(0..<sections.count, id: \.self) { i in
                    let count = s.startup.filter { $0.category == sections[i].1 }.count
                    Button("\(sections[i].0) (\(count))") { section = i }
                        .buttonStyle(PillStyle(kind: section == i ? .filled : .ghost))
                }
                Button("Disabled by MacGuard (\(s.disabledItems.count))") { section = 3 }
                    .buttonStyle(PillStyle(kind: section == 3 ? .filled : .ghost))
            }
            if section == 3 { disabledList } else {
            VStack(spacing: 0) {
                ForEach(rows) { item in
                    StartupRow(item: item, onTrust: {
                        TrustActions.confirmAndTrust(path: item.program, name: item.label, settings: settings, state: s, monitor: monitor)
                    }, onDisable: StartupDisabler.canDisable(item) ? {
                        StartupDisabler.disable(item, state: s, monitor: monitor)
                    } : nil)
                    Divider()
                }
                if rows.isEmpty {
                    Text(s.startupScanned ? "Nothing found here." : "Press “Scan startup items”.")
                        .font(.sans(15)).foregroundColor(Theme.slate).padding(20)
                }
            }
            .artifact()
            }
            if section == 2 {
                Text("Covers Chrome, Brave, Edge, Vivaldi, Opera, Arc and Firefox. Safari extensions are not listed. Extensions that can read all websites are not unsafe by themselves; MacGuard only raises the risk for known miner names.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            }
        }
        .onAppear { if !s.startupScanned && !s.startupBusy { monitor.scanStartup() } }
    }

    private var disabledList: some View {
        VStack(spacing: 0) {
            ForEach(s.disabledItems) { d in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.label).font(.sans(16, .medium)).foregroundColor(Theme.ink).lineLimit(1)
                        Text("\(d.scope) · disabled \(d.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.sans(14)).foregroundColor(Theme.slate)
                        Text(d.original).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.slate)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Re-enable") { StartupDisabler.enable(d, state: s, monitor: monitor) }
                        .buttonStyle(PillStyle(kind: .ghost))
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
            }
            if s.disabledItems.isEmpty {
                Text("Nothing disabled. Use Disable on a launch item or browser extension; it can be switched back on here.")
                    .font(.sans(15)).foregroundColor(Theme.slate).padding(20)
            }
        }
        .artifact()
    }

    private var newBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(fresh.count) new since your last scans").font(.sans(17, .medium)).foregroundColor(Theme.sienna)
            ForEach(fresh.prefix(6)) { i in
                Text("• \(i.label) · \(i.scope) · first seen \(i.firstSeen.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "recently")")
                    .font(.sans(14)).foregroundColor(Theme.sienna)
            }
            Text("Items stay marked New for 7 days. If you added them yourself, nothing to do.")
                .font(.sans(14)).foregroundColor(Theme.sienna)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.peach)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct StartupRow: View {
    let item: StartupItem
    let onTrust: () -> Void
    var onDisable: (() -> Void)? = nil

    private var meta: String {
        var parts = [item.scope, item.signature.rawValue]
        if item.category == .launch {
            if item.runAtLoad { parts.append("runs at login") }
            if item.keepAlive { parts.append("kept alive") }
        }
        return parts.filter { $0 != "n/a" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RiskTag(risk: item.risk)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.label).font(.sans(16, .medium)).foregroundColor(Theme.ink).lineLimit(1)
                    if item.isNew {
                        Text("New").font(.sans(12, .medium)).foregroundColor(Theme.sienna)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.peach))
                    }
                }
                Text(meta).font(.sans(14)).foregroundColor(Theme.slate)
                Text(item.program.isEmpty ? "(no program)" : item.program)
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.slate)
                    .lineLimit(1).truncationMode(.middle)
                ForEach(item.reasons, id: \.self) { r in
                    Text("• " + r).font(.sans(14)).foregroundColor(Theme.ink)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if item.trusted {
                    Text("Trusted").font(.sans(14, .medium)).foregroundColor(Theme.low)
                } else if item.risk != .low, !item.program.isEmpty {
                    Button("Trust") { onTrust() }.buttonStyle(PillStyle(kind: .ghost))
                }
                if let d = onDisable {
                    Button("Disable") { d() }.buttonStyle(PillStyle(kind: .ghost))
                }
                if let p = item.revealPath {
                    ArrowLink(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Security

struct SecurityView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor
    let settings: Settings
    @State private var section = 0

    var body: some View {
        Page {
            PageHeader(title: "Security",
                       subtitle: "Signals, not verdicts: miner names and arguments, sustained high CPU, odd locations, unsigned binaries, mining-pool ports.")
            HStack(spacing: 8) {
                Button("Suspicious processes") { section = 0 }.buttonStyle(PillStyle(kind: section == 0 ? .filled : .ghost))
                Button("Crypto miner check") { section = 1 }.buttonStyle(PillStyle(kind: section == 1 ? .filled : .ghost))
            }
            if section == 0 {
                processesSection
            } else {
                MinerCheckView(s: s, monitor: monitor)
            }
        }
        .onAppear { if s.minerReport == nil, !s.minerBusy { monitor.runMinerCheck(auto: false) } }
    }

    @ViewBuilder private var processesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button("Deep scan now") { monitor.deepScan() }.buttonStyle(PillStyle(kind: .filled)).disabled(s.deepBusy)
                if s.deepBusy {
                    Text("Scanning…").font(.sans(14)).foregroundColor(Theme.slate)
                } else if let d = s.deepDone {
                    Text("Last deep scan \(d.formatted(date: .omitted, time: .standard))").font(.sans(14)).foregroundColor(Theme.slate)
                }
            }
            VStack(spacing: 0) {
                ForEach(s.suspects) { x in
                    SuspectRow(x: x, s: s, settings: settings, monitor: monitor)
                    Divider()
                }
                if s.suspects.isEmpty {
                    Text("No suspicious processes right now.").font(.sans(15)).foregroundColor(Theme.slate).padding(20)
                }
            }
            .artifact()

            if !s.net.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connections to common mining-pool ports").font(.sans(17, .medium)).foregroundColor(Theme.ink)
                    ForEach(s.net) { n in
                        Text("\(n.process) (PID \(n.pid)) → \(n.remote)")
                            .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.ink)
                    }
                }
                .card()
            }
            Text("The network check covers your own processes only. System-level processes would need a privileged helper, which this app does not install.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
    }
}

struct SuspectRow: View {
    let x: Suspect
    let s: AppState
    let settings: Settings
    let monitor: Monitor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RiskTag(risk: x.risk)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(x.name)  ·  PID \(x.id)  ·  \(String(format: "%.0f%%", x.cpu)) CPU")
                    .font(.sans(16, .medium)).foregroundColor(Theme.ink)
                Text(x.path.isEmpty ? "(path unavailable)" : x.path)
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.slate)
                    .lineLimit(1).truncationMode(.middle)
                ForEach(x.reasons, id: \.self) { r in
                    Text("• " + r).font(.sans(14)).foregroundColor(Theme.ink)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(s.paused.contains(x.id) ? "Resume" : "Pause") { ProcessActions.togglePause(pid: x.id, name: x.name, state: s) }
                    .buttonStyle(PillStyle(kind: .ghost))
                Button("Quit") { ProcessActions.confirmAndTerminate(pid: x.id, name: x.name, force: false, state: s) }
                    .buttonStyle(PillStyle(kind: .ghost))
                if !x.path.isEmpty {
                    Button("Trust") { TrustActions.confirmAndTrust(path: x.path, name: x.name, settings: settings, state: s, monitor: monitor) }
                        .buttonStyle(PillStyle(kind: .ghost))
                    ArrowLink(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: x.path)])
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contextMenu {
            Button(s.paused.contains(x.id) ? "Resume “\(x.name)”" : "Pause “\(x.name)”") {
                ProcessActions.togglePause(pid: x.id, name: x.name, state: s)
            }
            Button("Quit “\(x.name)”") { ProcessActions.confirmAndTerminate(pid: x.id, name: x.name, force: false, state: s) }
            Button("Force Quit “\(x.name)”") { ProcessActions.confirmAndTerminate(pid: x.id, name: x.name, force: true, state: s) }
            if !x.path.isEmpty {
                Button("Trust “\(x.name)”") { TrustActions.confirmAndTrust(path: x.path, name: x.name, settings: settings, state: s, monitor: monitor) }
            }
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor
    @State private var section = 0

    var body: some View {
        Page {
            PageHeader(title: "Storage",
                       subtitle: "Every check is saved to your log file. Emptying caches or the Trash deletes files for good.")
            HStack(spacing: 8) {
                Button("Cleanup") { section = 0 }.buttonStyle(PillStyle(kind: section == 0 ? .filled : .ghost))
                Button("Large files") { section = 1 }.buttonStyle(PillStyle(kind: section == 1 ? .filled : .ghost))
            }
            if section == 0 {
                cleanupSection
            } else {
                LargeFilesView(s: s, monitor: monitor)
            }
        }
        .onAppear {
            // Opening the tab counts as a check: scan (and log) unless one just ran.
            if !s.cleanupBusy, Date().timeIntervalSince(s.lastScanDate ?? .distantPast) > 60 { monitor.scanCleanup() }
        }
    }

    @ViewBuilder private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            diskCard
            actions
            logLine
            VStack(spacing: 0) {
                ForEach(s.cleanup) { c in
                    HStack {
                        Text(c.title).font(.sans(15)).foregroundColor(Theme.ink)
                        Spacer()
                        Text(fmtBytesFile(c.bytes)).font(.sans(15)).monospacedDigit().foregroundColor(Theme.ink)
                        ArrowLink(title: "Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.id)])
                        }
                        .padding(.leading, 16)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    Divider()
                }
                if s.cleanup.isEmpty {
                    Text(s.cleanupBusy ? "Scanning…" : "Press “Scan reclaimable space”.")
                        .font(.sans(15)).foregroundColor(Theme.slate).padding(20)
                }
            }
            .artifact()
        }
    }

    @ViewBuilder private var diskCard: some View {
        if let d = s.storage {
            let used = 1 - Double(d.available) / Double(max(d.total, 1))
            let tint: Color = used >= 0.9 ? Theme.high : (used >= 0.8 ? Theme.mid : Theme.ink)
            StatCard(title: "Startup disk", value: "\(fmtBytesFile(d.available)) free",
                     detail: "of \(fmtBytesFile(d.total)) · includes purgeable space, same as Finder",
                     fraction: used, tint: tint)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Scan reclaimable space") { monitor.scanCleanup() }
                .buttonStyle(PillStyle(kind: .ghost)).disabled(s.cleanupBusy)
            Button("Empty Caches") {
                if Dialogs.confirm(title: "Empty ~/Library/Caches?",
                                   message: "Deletes the contents of your user cache folder. Apps rebuild what they need, so some may start slower or ask you to sign in again. Closing big apps such as browsers first gives the best result.",
                                   button: "Empty Caches") { monitor.emptyCaches() }
            }
            .buttonStyle(PillStyle(kind: .filled)).disabled(s.cleanupBusy)
            Button("Empty Trash") {
                if Dialogs.confirm(title: "Empty the Trash?",
                                   message: "Everything in the Trash is deleted permanently and can’t be recovered. macOS may ask once for permission to let MacGuard control Finder.",
                                   button: "Empty Trash") { monitor.emptyTrash() }
            }
            .buttonStyle(PillStyle(kind: .filled)).disabled(s.cleanupBusy)
            if s.cleanupBusy { Text("Working…").font(.sans(14)).foregroundColor(Theme.slate) }
            Spacer()
        }
    }

    @ViewBuilder private var logLine: some View {
        if let p = s.lastLogPath {
            HStack(spacing: 8) {
                Text("Log: \(p)").font(.sans(14)).foregroundColor(Theme.slate).lineLimit(1).truncationMode(.middle)
                ArrowLink(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            }
        }
    }
}

// MARK: - Settings

struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sans(16, .medium)).foregroundColor(Theme.ink)
                Text(detail).font(.sans(14)).foregroundColor(Theme.slate)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.ink)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var s: AppState

    var body: some View {
        Page {
            PageHeader(title: "Settings", subtitle: "Changes apply immediately.")
            appearance
            sensors
            alerts
            trustedApps
            notch
            background
            logs
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            HStack(spacing: 8) {
                ForEach(Settings.ThemeChoice.allCases, id: \.self) { c in
                    Button(c.rawValue) { settings.theme = c }
                        .buttonStyle(PillStyle(kind: settings.theme == c ? .filled : .ghost))
                }
            }
            Text("Light is the default. Dark is a matching variant.").font(.sans(14)).foregroundColor(Theme.slate)
        }
        .card(padding: 24)
    }

    private var sensors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sensors").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            SettingRow(title: "Read temperature sensors",
                       detail: "Uses the private IOHID sensor API. Off shows only the macOS thermal state and skips sensor reads.",
                       isOn: $settings.tempSensors)
        }
        .card(padding: 24)
    }

    private var trustedApps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted apps").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            Text("Programs you trusted from Security or Startup. They are not flagged unless their name or command line matches a known crypto miner.")
                .font(.sans(14)).foregroundColor(Theme.slate)
            if settings.allowlist.isEmpty {
                Text("Nothing trusted yet. Use Trust on a flagged process or startup item.")
                    .font(.sans(15)).foregroundColor(Theme.slate)
            }
            ForEach(settings.allowlist, id: \.self) { path in
                HStack(spacing: 12) {
                    Text(path).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    ArrowLink(title: "Remove") { settings.untrust(path) }
                }
            }
        }
        .card(padding: 24)
    }

    private var notch: some View {
        let geo = NotchGeometry.firstNotched()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Notch popover").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            SettingRow(title: "Show the notch popover",
                       detail: "Rest the mouse next to the notch to open a small panel with CPU, temperature, memory, battery, network and the busiest apps. It moves away when the mouse leaves.",
                       isOn: $settings.notchPopover).disabled(geo == nil)
            Text(geo?.summary ?? "No notch found on this Mac, so the popover cannot open here.")
                .font(.sans(14)).foregroundColor(Theme.slate)
            if geo != nil {
                Text("Sizes follow the real notch and your display's \"Looks like\" resolution, so it fits 13, 14, 15 and 16 inch MacBooks. With Reduce Motion on, it fades instead of growing.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            }
        }
        .card(padding: 24)
    }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alerts").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            SettingRow(title: "Enable alerts", detail: "Master switch for notifications from MacGuard.", isOn: $settings.alerts)
            SettingRow(title: "Overheating contributors",
                       detail: "Notify when an app keeps using 15% CPU or more while the Mac runs hot.",
                       isOn: $settings.notifyHeat).disabled(!settings.alerts)
            SettingRow(title: "High-risk processes",
                       detail: "Notify when a process reaches High risk (for example miner indicators).",
                       isOn: $settings.notifySuspect).disabled(!settings.alerts)
            SettingRow(title: "New startup items",
                       detail: "Checks every 15 minutes and notifies you when something new is added to startup, shell files, cron or browser extensions.",
                       isOn: $settings.notifyNewStartup).disabled(!settings.alerts)
            SettingRow(title: "Automatic crypto miner check",
                       detail: "Runs the eight miner checks every 30 minutes and notifies you if something is found.",
                       isOn: $settings.minerAutoCheck)
            HStack(spacing: 12) {
                Button("Send test notification") {
                    Notifier.shared.requestAuthorization()
                    Notifier.shared.post(id: "test", title: "MacGuard", body: "Notifications are working.")
                }
                .buttonStyle(PillStyle(kind: .ghost))
                ArrowLink(title: "Open notification settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            Text("If nothing appears, allow MacGuard in System Settings > Notifications.").font(.sans(14)).foregroundColor(Theme.slate)
        }
        .card(padding: 24)
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            SettingRow(title: "Keep running in the background",
                       detail: "Closing the window keeps MacGuard in the menu bar so monitoring and alerts continue.",
                       isOn: $settings.keepInBackground)
            SettingRow(title: "Start at login",
                       detail: "Opens MacGuard automatically when you sign in. Works best from /Applications.",
                       isOn: $settings.launchAtLogin)
            if let e = settings.loginError { Text(e).font(.sans(14)).foregroundColor(Theme.high) }
        }
        .card(padding: 24)
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Storage logs").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            SettingRow(title: "Save a log on every storage check",
                       detail: "Appends to MacGuard-storage.log: disk free, largest folders, and what was emptied.",
                       isOn: $settings.saveLogs)
            Text(settings.logPath).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.slate)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                Button("Choose folder…") { chooseFolder() }.buttonStyle(PillStyle(kind: .ghost))
                ArrowLink(title: "Show in Finder") {
                    let url = URL(fileURLWithPath: (settings.logPath as NSString).expandingTildeInPath)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .card(padding: 24)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose where MacGuard saves its storage logs."
        p.directoryURL = URL(fileURLWithPath: (settings.logPath as NSString).expandingTildeInPath)
        if p.runModal() == .OK, let u = p.url { settings.logPath = u.path }
    }
}
