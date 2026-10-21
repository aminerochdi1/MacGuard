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
}

final class Monitor {
    struct Config {
        var tempSensors = true
        var alerts = true
        var notifyHeat = true
        var notifySuspect = true
        var saveLogs = true
        var logPath = NSHomeDirectory() + "/Library/Logs/MacGuard"
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
    private var heat: [String: Int] = [:]
    private var lastNet = Date.distantPast
    private var notifiedAt: [String: Date] = [:]

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
        if let last = notifiedAt[key], Date().timeIntervalSince(last) < interval { return }
        notifiedAt[key] = Date()
        Notifier.shared.post(id: key, title: title, body: body)
    }

    private func step() {
        let cfg = self.cfg
        let c = cpu.sample()
        let m = readMemory()
        let t = cfg.tempSensors ? temps.read() : nil
        let th = ProcessInfo.processInfo.thermalState

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

        let heatList = heat.sorted { $0.value > $1.value }.prefix(5).map { HeatEntry(name: $0.key, count: $0.value) }
        let storage = (tick % 15 == 1) ? Storage.read() : nil

        var status = "CPU --"
        if let c = c { status = String(format: "CPU %.0f%%", c.total) }
        if let mx = t?.cpuMax { status += String(format: " · %.0f°C", mx) }

        DispatchQueue.main.async {
            if let c = c { self.state.cpu = c }
            if let m = m { self.state.mem = m }
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

    func scanStartup() {
        DispatchQueue.main.async { self.state.startupBusy = true }
        work.async {
            let items = StartupScanner.scan(sig: self.detector.sig)
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
            let items = StartupScanner.scan(sig: self.detector.sig)
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
