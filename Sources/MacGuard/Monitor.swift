import Foundation
import AppKit

struct HeatEntry: Identifiable {
    var id: String { name }
    let name: String
    let count: Int
}

final class AppState: ObservableObject {
    @Published var cpu: CPUReading?
    @Published var mem: MemInfo?
    @Published var temps: TempReading?
    @Published var tempsEnabled = true
    @Published var thermal = "Nominal"
    @Published var procs: [ProcInfo] = []
    @Published var suspects: [Suspect] = []
    @Published var heat: [HeatEntry] = []
    @Published var storage: StorageInfo?
    @Published var statusText = "MacGuard"
    @Published var notice: String?

    @Published var startup: [StartupItem] = []
    @Published var startupScanned = false
    @Published var startupBusy = false

    @Published var net: [NetFinding] = []
    @Published var deepBusy = false
    @Published var deepDone: Date?

    @Published var cleanup: [CleanupItem] = []
    @Published var cleanupBusy = false
    @Published var cleanupScanned = false
    @Published var lastScanDate: Date?
    @Published var lastLogPath: String?

    @Published var history: [HistoryPoint] = []

    @Published var battery: BatteryInfo?
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    @Published var netApps: [NetApp] = []
    @Published var netAppsReady = false

    @Published var minerReport: MinerReport?
    @Published var minerBusy = false

    @Published var bigFiles: [BigFile] = []
    @Published var bigFolders: [FolderSize] = []
    @Published var bigScanning = false
    @Published var bigScannedCount = 0
    @Published var bigRoot = ""
    @Published var bigDone: Date?
}

final class Monitor {
    struct Config {
        var tempSensors = true
        var alerts = true
        var notifyHeat = true
        var notifySuspect = true
        var saveLogs = true
        var logPath = NSHomeDirectory() + "/Library/Logs/MacGuard"
        var minerAutoCheck = true
        var notifyNewStartup = true
    }

    private let state: AppState
    private let queue = DispatchQueue(label: "macguard.monitor", qos: .utility)
    private let work = DispatchQueue(label: "macguard.work", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var visible = true

    private let cpu = CPUSampler()
    private let procs = ProcessSampler()
    private let temps = TempReader()
    private let detector = Detector()
    private let netTotals = NetTotalsSampler()
    private let netAppSampler = NetAppSampler()
    private let netQueue = DispatchQueue(label: "macguard.net", qos: .utility)
    private var netWatchers = 0
    private var netLoopOn = false
    private var heat: [String: Int] = [:]
    private var lastNet = Date.distantPast
    private var notifiedAt: [String: Date] = [:]
    private let notifyLock = NSLock()
    private var minerRunning = false
    private var lastMinerCheck = Date()
    private var lastStartupCheck = Date().addingTimeInterval(-900 + 20)   // first automatic scan ~20 s after launch
    private var historyBuf: [HistoryPoint] = []
    private var lastHistory = Date.distantPast
    private var scanner: LargeFileScanner?
    private let largeQueue = DispatchQueue(label: "macguard.large", qos: .utility)

    private let cfgLock = NSLock()
    private var _cfg = Config()
    private var cfg: Config {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _cfg }
        set { cfgLock.lock(); _cfg = newValue; cfgLock.unlock() }
    }

    init(state: AppState) { self.state = state }

    func updateConfig(_ c: Config) { cfg = c }

    func start() { queue.async { self.schedule() } }

    /// Sample slower when the window is hidden to keep the app light.
    func setVisible(_ v: Bool) {
        queue.async {
            guard self.visible != v else { return }
            self.visible = v
            self.schedule()
        }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: visible ? 2.0 : 5.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    private func foregroundPids() -> Set<Int32> {
        var gui = Set<Int32>()
        DispatchQueue.main.sync {
            gui = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier })
        }
        return gui
    }

    /// At most one notification per key per `interval` seconds.
    private func notify(key: String, interval: TimeInterval, title: String, body: String) {
        notifyLock.lock()
        if let last = notifiedAt[key], Date().timeIntervalSince(last) < interval { notifyLock.unlock(); return }
        notifiedAt[key] = Date()
        notifyLock.unlock()
        Notifier.shared.post(id: key, title: title, body: body)
    }

    // MARK: - Crypto miner check (manual, and automatic every 30 minutes)

    func runMinerCheck(auto: Bool) {
        if !auto { DispatchQueue.main.async { self.state.minerBusy = true } }
        work.async {
            if self.minerRunning { return }
            self.minerRunning = true
            defer { self.minerRunning = false }

            let gui = self.foregroundPids()
            var list: [ProcInfo] = []
            var sust: [Int32: Double] = [:]
            var suspects: [Suspect] = []
            self.queue.sync {
                list = self.procs.sample()
                for p in list { if let a = self.procs.sustained(p.id, samples: 4) { sust[p.id] = a } }
                suspects = self.detector.evaluate(procs: list, sustained: { sust[$0] }, gui: gui, deep: true)
            }
            let report = MinerCheck.run(procs: list, sustained: sust, gui: gui, suspects: suspects, sig: self.detector.sig)
            let c = self.cfg
            if report.verdict != .clear, c.alerts, c.notifySuspect {
                let names = report.items.filter { $0.status != .clear }.map { $0.title }.joined(separator: ", ")
                self.notify(key: "miner-verdict", interval: 6 * 3600,
                            title: report.verdict == .likely ? "Crypto miner indicators found" : "Possible crypto mining activity",
                            body: "Flagged by: \(names). Open MacGuard > Security > Crypto miner check.")
            }
            DispatchQueue.main.async {
                self.state.minerReport = report
                self.state.minerBusy = false
            }
        }
    }

    // MARK: - Per-app network usage (nettop runs only while the Network tab is open)

    func netWatch(_ on: Bool) {
        netQueue.async {
            self.netWatchers = max(0, self.netWatchers + (on ? 1 : -1))
            if self.netWatchers > 0, !self.netLoopOn {
                self.netLoopOn = true
                self.netLoop()
            }
        }
    }

    private func netLoop() {   // runs on netQueue
        guard netWatchers > 0 else { netLoopOn = false; return }
        let apps = netAppSampler.sample()
        DispatchQueue.main.async {
            self.state.netApps = apps
            self.state.netAppsReady = true
        }
        netQueue.asyncAfter(deadline: .now() + 1.0) { self.netLoop() }
    }

    private func step() {
        let cfg = self.cfg
        let c = cpu.sample()
        let m = readMemory()
        let t = cfg.tempSensors ? temps.read() : nil
        let th = ProcessInfo.processInfo.thermalState
        let bat = BatteryReader.read()
        let nt = netTotals.sample()

        var newProcs: [ProcInfo]? = nil
        var suspects: [Suspect]? = nil
        if !visible || tick % 2 == 0 {
            let list = procs.sample()
            newProcs = list

            // Mining-port check only when something is working hard (lsof is the heaviest call here).
            let busy = list.contains { (procs.sustained($0.id) ?? 0) >= 50 }
            if busy, Date().timeIntervalSince(lastNet) > 60 {
                lastNet = Date()
                detector.netPids = Set(NetScanner.scan().map { $0.pid })
            } else if !busy {
                detector.netPids = []
            }
            let found = detector.evaluate(procs: list, sustained: { self.procs.sustained($0) },
                                          gui: foregroundPids(), deep: false)
            suspects = found

            if cfg.alerts, cfg.notifySuspect {
                for s in found where s.risk == .high {
                    notify(key: "suspect-\(s.name)", interval: 3600, title: "MacGuard: suspicious process",
                           body: "\(s.name) (PID \(s.id)): \(s.reasons.first ?? "multiple warning signs").")
                }
            }

            // Heat blame: who was using the CPU while the machine was hot
            let hot: Bool
            if let mx = t?.cpuMax { hot = mx >= 80 } else { hot = th.rawValue >= ProcessInfo.ThermalState.fair.rawValue }
            if hot {
                for p in list.sorted(by: { $0.cpu > $1.cpu }).prefix(3) where p.cpu >= 15 {
                    let n = (heat[p.name] ?? 0) + 1
                    heat[p.name] = n
                    if cfg.alerts, cfg.notifyHeat, n >= 3 {
                        let temp = t?.cpuMax.map { String(format: " (%.0f °C)", $0) } ?? ""
                        notify(key: "heat-\(p.name)", interval: 900, title: "Overheating contributor",
                               body: String(format: "%@ is using %.0f%% CPU while your Mac is running hot%@.", p.name, p.cpu, temp))
                    }
                }
            }
        }
        tick += 1

        // Automatic miner check every 30 minutes (first one 30 minutes after launch)
        if cfg.minerAutoCheck, Date().timeIntervalSince(lastMinerCheck) >= 1800 {
            lastMinerCheck = Date()
            runMinerCheck(auto: true)
        }

        // Automatic check for new startup items every 15 minutes
        if cfg.alerts, cfg.notifyNewStartup, Date().timeIntervalSince(lastStartupCheck) >= 900 {
            lastStartupCheck = Date()
            work.async {
                let items = self.runStartupScan()
                DispatchQueue.main.async { if self.state.startupScanned { self.state.startup = items } }
            }
        }

        let heatList = heat.sorted { $0.value > $1.value }.prefix(5).map { HeatEntry(name: $0.key, count: $0.value) }
        let storage = (tick % 15 == 1) ? Storage.read() : nil

        var status = "CPU --"
        if let c = c { status = String(format: "CPU %.0f%%", c.total) }
        if let mx = t?.cpuMax { status += String(format: " · %.0f°C", mx) }

        // History: one point every 10 s, last hour kept (360 points)
        var historyOut: [HistoryPoint]? = nil
        if let c = c, let m = m, Date().timeIntervalSince(lastHistory) >= 10 {
            lastHistory = Date()
            historyBuf.append(HistoryPoint(t: Date(), cpu: c.total, temp: t?.cpuMax,
                                           mem: Double(m.used) / Double(max(m.total, 1)) * 100,
                                           pressure: m.pressure))
            if historyBuf.count > 360 { historyBuf.removeFirst(historyBuf.count - 360) }
            historyOut = historyBuf
        }

        DispatchQueue.main.async {
            if let h = historyOut { self.state.history = h }
            if let c = c { self.state.cpu = c }
            if let m = m { self.state.mem = m }
            self.state.battery = bat
            if let n = nt { self.state.netDown = n.down; self.state.netUp = n.up }
            self.state.temps = t
            self.state.tempsEnabled = cfg.tempSensors
            self.state.thermal = thermalStateName(th)
            if let p = newProcs {
                self.state.procs = Array(p.sorted { $0.cpu > $1.cpu }.prefix(80))
            }
            if let s = suspects { self.state.suspects = s }
            self.state.heat = heatList
            if let s = storage { self.state.storage = s }
            self.state.statusText = status
        }
    }

    // MARK: - On-demand scans

    /// Full startup scan (runs on `work`): marks items that are new since the last scan and notifies about them.
    private func runStartupScan() -> [StartupItem] {
        let r = StartupFullScan.run(sig: detector.sig)
        let c = cfg
        if c.alerts, c.notifyNewStartup, !r.fresh.isEmpty {
            if r.fresh.count > 3 {
                notify(key: "startup-new-batch", interval: 3600, title: "New startup items",
                       body: "\(r.fresh.count) new items were added (for example \(r.fresh[0].label)). Open MacGuard > Startup.")
            } else {
                for i in r.fresh {
                    notify(key: "startup-new-\(i.id)", interval: 24 * 3600, title: "New startup item",
                           body: "\(i.label) (\(i.scope)) was added. Risk: \(i.risk.rawValue). Open MacGuard > Startup.")
                }
            }
        }
        return r.items
    }

    func scanStartup() {
        DispatchQueue.main.async { self.state.startupBusy = true }
        work.async {
            let items = self.runStartupScan()
            DispatchQueue.main.async {
                self.state.startup = items
                self.state.startupScanned = true
                self.state.startupBusy = false
            }
        }
    }

    /// Deep scan: command lines of every process, network pool-port check, startup items.
    func deepScan() {
        DispatchQueue.main.async { self.state.deepBusy = true }
        work.async {
            let net = NetScanner.scan()
            let items = self.runStartupScan()
            let gui = self.foregroundPids()
            self.queue.sync {
                self.detector.netPids = Set(net.map { $0.pid })
                let list = self.procs.sample()
                let s = self.detector.evaluate(procs: list, sustained: { self.procs.sustained($0) }, gui: gui, deep: true)
                DispatchQueue.main.async {
                    self.state.suspects = s
                    self.state.net = net
                    self.state.startup = items
                    self.state.startupScanned = true
                    self.state.deepBusy = false
                    self.state.deepDone = Date()
                }
            }
        }
    }

    // MARK: - Storage: scan, empty caches, empty Trash (each one is logged)

    private func scanLines(_ items: [CleanupItem], _ st: StorageInfo?) -> [String] {
        var lines: [String] = []
        if let st = st {
            let used = Double(st.total - st.available) / Double(max(st.total, 1)) * 100
            lines.append("Disk: \(fmtBytesFile(st.total)) total, \(fmtBytesFile(st.available)) free (\(String(format: "%.1f", used))% used)")
        }
        for i in items { lines.append("\(i.title): \(fmtBytesFile(i.bytes))") }
        return lines
    }

    /// Runs on the work queue: scans, writes the log entry, publishes results.
    private func runScan(title: String, extra: [String]) {
        let items = Storage.scanCleanup()
        let st = Storage.read()
        let c = cfg
        let res: (path: String?, error: String?)? = c.saveLogs
            ? LogWriter.append(title: title, lines: extra + scanLines(items, st), dir: c.logPath)
            : nil
        DispatchQueue.main.async {
            self.state.cleanup = items
            self.state.cleanupScanned = true
            self.state.cleanupBusy = false
            self.state.lastScanDate = Date()
            if let st = st { self.state.storage = st }
            if let p = res?.path { self.state.lastLogPath = p }
            if let e = res?.error { self.state.notice = "Couldn’t save the log: \(e)." }
        }
    }

    /// Appends one event to the storage log (if logging is on).
    func logEvent(title: String, lines: [String]) {
        let c = cfg
        guard c.saveLogs else { return }
        work.async {
            let res = LogWriter.append(title: title, lines: lines, dir: c.logPath)
            DispatchQueue.main.async {
                if let p = res.path { self.state.lastLogPath = p }
                if let e = res.error { self.state.notice = "Couldn’t save the log: \(e)." }
            }
        }
    }

    // MARK: - Large files

    func scanLarge(root: String) {
        let sc = LargeFileScanner()
        scanner = sc
        DispatchQueue.main.async {
            self.state.bigScanning = true
            self.state.bigScannedCount = 0
            self.state.bigRoot = root
            self.state.bigFiles = []
            self.state.bigFolders = []
        }
        largeQueue.async {
            let started = Date()
            let r = sc.scan(root: URL(fileURLWithPath: root), minBytes: 50_000_000) { n in
                DispatchQueue.main.async { self.state.bigScannedCount = n }
            }
            DispatchQueue.main.async {
                self.state.bigFiles = r.files
                self.state.bigFolders = r.folders
                self.state.bigScannedCount = r.scanned
                self.state.bigScanning = false
                self.state.bigDone = Date()
                if r.wasCancelled { self.state.notice = "Scan stopped. Showing what was found so far." }
            }
            var lines = ["Scanned \(r.scanned) files in \(root) (\(Int(Date().timeIntervalSince(started))) s)\(r.wasCancelled ? ", stopped early" : "")"]
            for f in r.folders.prefix(5) { lines.append("Folder \(f.path): \(fmtBytesFile(f.size))") }
            for f in r.files.prefix(10) { lines.append("File \(f.path): \(fmtBytesFile(f.size))") }
            self.logEvent(title: "Large files scan", lines: lines)
        }
    }

    func cancelLarge() { scanner?.cancel() }

    func scanCleanup() {
        DispatchQueue.main.async { self.state.cleanupBusy = true }
        work.async { self.runScan(title: "Storage check", extra: []) }
    }

    func emptyCaches() {
        DispatchQueue.main.async {
            self.state.cleanupBusy = true
            self.state.notice = "Emptying caches…"
        }
        work.async {
            let r = Cleaner.emptyCaches()
            let summary = "Freed \(fmtBytesFile(r.freed)); \(r.failed) item(s) skipped (in use or protected)"
            self.runScan(title: "Empty caches", extra: [summary])
            DispatchQueue.main.async { self.state.notice = "Caches emptied. " + summary + "." }
        }
    }

    func emptyTrash() {
        DispatchQueue.main.async {
            self.state.cleanupBusy = true
            self.state.notice = "Emptying Trash…"
        }
        work.async {
            let before = Storage.read()?.available
            let r = Cleaner.emptyTrash()
            var extra = [r.message]
            if r.ok, let b = before, let a = Storage.read()?.available {
                extra.append("Free space: \(fmtBytesFile(b)) → \(fmtBytesFile(a))")
            }
            self.runScan(title: "Empty Trash", extra: extra)
            DispatchQueue.main.async { self.state.notice = r.message }
        }
    }
}
