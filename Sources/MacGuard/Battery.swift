import Foundation
import IOKit
import SwiftUI

// MARK: - Model

struct BatteryInfo {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var fullyCharged: Bool
    var cycles: Int?
    var healthPercent: Double?     // maximum capacity / design capacity (what System Settings calls "Maximum Capacity")
    var designMAh: Int?
    var maxMAh: Int?
    var temperatureC: Double?
    var watts: Double?             // battery side: positive = charging, negative = discharging
    var adapterWatts: Int?
    var minutes: Int?              // to empty when discharging, to full when charging

    var stateText: String {
        if fullyCharged { return "Fully charged" }
        if isCharging { return "Charging" }
        if onAC { return "Plugged in, not charging" }
        return "On battery"
    }
}

// MARK: - Reader (AppleSmartBattery in the IO registry: public IOKit calls, read-only)

enum BatteryReader {
    static func read() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func num(_ k: String) -> Int64? {
            guard let n = dict[k] as? NSNumber else { return nil }
            return Int64(truncatingIfNeeded: n.uint64Value)   // keeps negative values stored as unsigned 64-bit
        }
        func flag(_ k: String) -> Bool { (dict[k] as? NSNumber)?.boolValue ?? false }

        // Present flag: false when the battery slot is empty
        if let present = dict["BatteryInstalled"] as? NSNumber, !present.boolValue { return nil }

        let cur = num("CurrentCapacity") ?? 0
        let mx = num("MaxCapacity") ?? 100
        var percent = mx > 100 ? Int(cur * 100 / max(mx, 1)) : Int(cur)   // Apple Silicon reports a percentage already
        percent = min(max(percent, 0), 100)

        let design = num("DesignCapacity").map { Int($0) }
        let nominal = num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity")
        let maxMAh = nominal.map { Int($0) }
        var health: Double? = nil
        if let d = design, d > 0, let m = maxMAh, m > 0 { health = min(Double(m) / Double(d) * 100, 100) }

        var temp: Double? = nil
        if let t = num("Temperature"), t > 0 { temp = Double(t) / 100 }

        var watts: Double? = nil
        if let v = num("Voltage"), let a = num("Amperage") { watts = Double(v) * Double(a) / 1_000_000 }

        var adapter: Int? = nil
        if let ad = dict["AdapterDetails"] as? [String: Any], let w = (ad["Watts"] as? NSNumber)?.intValue, w > 0 { adapter = w }

        let charging = flag("IsCharging")
        let ext = flag("ExternalConnected")
        var minutes: Int? = nil
        let key = charging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        if let m = num(key), m > 0, m < 65535 { minutes = Int(m) }

        return BatteryInfo(percent: percent, isCharging: charging, onAC: ext, fullyCharged: flag("FullyCharged"),
                           cycles: num("CycleCount").map { Int($0) }, healthPercent: health,
                           designMAh: design, maxMAh: maxMAh, temperatureC: temp, watts: watts,
                           adapterWatts: adapter, minutes: minutes)
    }
}

func fmtMinutes(_ m: Int) -> String {
    m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

// MARK: - View

struct BatteryView: View {
    @ObservedObject var s: AppState

    var body: some View {
        Page {
            PageHeader(title: "Battery",
                       subtitle: "Charge, health and power draw, read from the battery controller (AppleSmartBattery).")
            if let b = s.battery {
                HStack(alignment: .top, spacing: 16) {
                    chargeCard(b)
                    powerCard(b)
                    healthCard(b)
                    tempCard(b)
                }
                appsCard
                Text("Per-app battery use is estimated from CPU use, the main driver of drain. macOS does not expose exact per-app watts to normal apps.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            } else {
                Text("No battery found. This Mac has no battery, or it is not reporting.")
                    .font(.sans(16)).foregroundColor(Theme.slate).card()
            }
        }
    }

    private func chargeCard(_ b: BatteryInfo) -> some View {
        let tint: Color = (!b.onAC && b.percent <= 20) ? Theme.high : ((!b.onAC && b.percent <= 40) ? Theme.mid : Theme.ink)
        var detail = b.stateText
        if let m = b.minutes { detail += b.isCharging ? " · \(fmtMinutes(m)) to full" : " · \(fmtMinutes(m)) left" }
        return StatCard(title: "Charge", value: "\(b.percent)%", detail: detail, fraction: Double(b.percent) / 100, tint: tint)
    }

    private func powerCard(_ b: BatteryInfo) -> some View {
        guard let w = b.watts else { return StatCard(title: "Power", value: "n/a", detail: "Not reported") }
        let mag = abs(w)
        let label: String
        if mag < 0.3 { label = "Idle" } else { label = w > 0 ? "Charging" : "Discharging" }
        var detail = label
        if let a = b.adapterWatts { detail += " · \(a) W adapter" }
        return StatCard(title: "Battery power", value: String(format: "%.1f W", mag), detail: detail)
    }

    private func healthCard(_ b: BatteryInfo) -> some View {
        guard let h = b.healthPercent else {
            return StatCard(title: "Health", value: "n/a", detail: b.cycles.map { "\($0) cycles" } ?? "Not reported")
        }
        let tint: Color = h < 80 ? Theme.high : (h < 90 ? Theme.mid : Theme.ink)
        var detail = ""
        if let c = b.cycles { detail += "\(c) cycles" }
        if let d = b.designMAh, let m = b.maxMAh { detail += (detail.isEmpty ? "" : " · ") + "\(m) of \(d) mAh" }
        return StatCard(title: "Maximum capacity", value: String(format: "%.0f%%", h), detail: detail, fraction: h / 100, tint: tint)
    }

    private func tempCard(_ b: BatteryInfo) -> some View {
        guard let t = b.temperatureC else { return StatCard(title: "Battery temperature", value: "n/a", detail: "Not reported") }
        let tint: Color = t >= 45 ? Theme.high : (t >= 38 ? Theme.mid : Theme.ink)
        return StatCard(title: "Battery temperature", value: String(format: "%.0f °C", t),
                        detail: t >= 45 ? "High: charge in a cooler place" : "Normal range", fraction: t / 60, tint: tint)
    }

    private var appsCard: some View {
        let top = s.procs.sorted { $0.cpu > $1.cpu }.prefix(8)
        let mx = max(top.first?.cpu ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Apps likely draining the battery").font(.sans(22, .medium)).tracking(-0.23).foregroundColor(Theme.ink)
            ForEach(Array(top)) { p in
                HStack(spacing: 12) {
                    Text(p.name).font(.sans(15)).foregroundColor(Theme.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Bar(fraction: p.cpu / mx, tint: Theme.load(p.cpu)).frame(width: 160)
                    Text(String(format: "%.0f%% CPU", p.cpu)).font(.sans(14)).monospacedDigit()
                        .foregroundColor(Theme.slate).frame(width: 90, alignment: .trailing)
                }
            }
        }
        .card(padding: 24)
    }
}
