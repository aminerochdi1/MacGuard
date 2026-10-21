import Foundation

/// `MacGuard --selftest` prints raw readings so you can compare them with Activity Monitor
/// before trusting the app. No UI is started.
func runSelfTest() {
    print("MacGuard self-test")
    print("Chip: \(Sys.string("machdep.cpu.brand_string") ?? "unknown")")

    let cpu = CPUSampler()
    let procs = ProcessSampler()
    _ = procs.sample()
    Thread.sleep(forTimeInterval: 2.0)

    if let c = cpu.sample() {
        print(String(format: "CPU: %.1f%% busy (user %.1f, system %.1f, idle %.1f) on %d cores", c.total, c.user, c.system, c.idle, c.cores))
    } else { print("CPU: unavailable") }

    if let m = readMemory() {
        print("Memory used: \(fmtBytes(m.used)) of \(fmtBytes(m.total))  [app \(fmtBytes(m.app)), wired \(fmtBytes(m.wired)), compressed \(fmtBytes(m.compressed))]")
        print("Cached files: \(fmtBytes(m.cached)), swap used: \(fmtBytes(m.swapUsed)), pressure: \(m.pressure.rawValue)")
    } else { print("Memory: unavailable") }

    print("Thermal state: \(thermalStateName(ProcessInfo.processInfo.thermalState))")
    let tr = TempReader()
    if let t = tr.read() {
        print("Temperature sensors: \(t.sensors.count)")
        if let a = t.cpuAvg, let x = t.cpuMax { print(String(format: "CPU die avg %.1f °C, max %.1f °C", a, x)) }
        else { print("No sensor named 'tdie' found; names seen:") }
        for s in t.sensors { print(String(format: "  %@ = %.1f °C", s.name, s.value)) }
    } else { print("Temperature: HID sensors not available (thermal state only)") }

    let list = procs.sample()
    let unreadable = list.filter { !$0.readable }.count
    print("Processes: \(list.count) (\(unreadable) estimated via ps)")
    print("Top 8 by CPU (compare with Activity Monitor):")
    for p in list.sorted(by: { $0.cpu > $1.cpu }).prefix(8) {
        print(String(format: "  %6d  %6.1f%%  %@  %@", p.id, p.cpu, fmtBytes(p.footprint), p.name))
    }

    let items = StartupScanner.scan(sig: SignatureChecker())
    print("Startup items: \(items.count), flagged Medium/High: \(items.filter { $0.risk != .low }.count)")
    for i in items.prefix(5) where i.risk != .low { print("  [\(i.risk.rawValue)] \(i.label): \(i.reasons.joined(separator: "; "))") }

    if let d = Storage.read() { print("Disk free: \(fmtBytesFile(d.available)) of \(fmtBytesFile(d.total))") }

    if let b = BatteryReader.read() {
        print(String(format: "Battery: %d%% (%@), health %@, cycles %@, power %@ W, temp %@ °C", b.percent, b.stateText,
                     b.healthPercent.map { String(format: "%.0f%%", $0) } ?? "n/a", b.cycles.map { String($0) } ?? "n/a",
                     b.watts.map { String(format: "%.1f", $0) } ?? "n/a", b.temperatureC.map { String(format: "%.0f", $0) } ?? "n/a"))
    } else { print("Battery: none") }

    let apps = NetAppSampler().sample()
    print("Network (nettop, top 5 by traffic): \(apps.count) active apps")
    for a in apps.prefix(5) { print("  \(a.name): down \(fmtRate(a.down)), up \(fmtRate(a.up))") }
}
