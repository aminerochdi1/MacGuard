import SwiftUI

// MARK: - Model (one point every ~10 s, last hour kept in memory)

struct HistoryPoint {
    let t: Date
    let cpu: Double        // % busy, 0-100
    let temp: Double?      // hottest CPU die sensor, °C
    let mem: Double        // % of RAM used (App + Wired + Compressed)
}

// MARK: - Minimal line chart (no animation, no dependencies)

struct LineChart: View {
    let values: [Double?]
    let minY: Double
    let maxY: Double
    var tint: Color = Theme.ink
    var unit: String = ""

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // horizontal guides at top / middle / bottom
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(f)))
                        p.addLine(to: CGPoint(x: w, y: h * CGFloat(f)))
                    }
                    .stroke(Theme.hairline, lineWidth: 1)
                }
                line(width: w, height: h).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                Text("\(Int(maxY))\(unit)").font(.sans(11)).foregroundColor(Theme.slate).offset(x: 2, y: 2)
                Text("\(Int(minY))\(unit)").font(.sans(11)).foregroundColor(Theme.slate).offset(x: 2, y: h - 16)
            }
        }
    }

    private func line(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard values.count > 1, maxY > minY else { return path }
        var penDown = false
        for (i, v) in values.enumerated() {
            guard let v = v else { penDown = false; continue }
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let frac = min(max((v - minY) / (maxY - minY), 0), 1)
            let y = height * CGFloat(1 - frac)
            if penDown { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); penDown = true }
        }
        return path
    }
}

// MARK: - History tab

struct HistoryView: View {
    @ObservedObject var s: AppState
    @State private var minutes = 60

    private var points: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return s.history.filter { $0.t >= cutoff }
    }

    var body: some View {
        Page {
            PageHeader(title: "History",
                       subtitle: "One reading every 10 seconds while MacGuard is running. Kept in memory, cleared when you quit.")
            HStack(spacing: 8) {
                Button("15 minutes") { minutes = 15 }.buttonStyle(PillStyle(kind: minutes == 15 ? .filled : .ghost))
                Button("1 hour") { minutes = 60 }.buttonStyle(PillStyle(kind: minutes == 60 ? .filled : .ghost))
                Spacer()
                Text("\(points.count) readings").font(.sans(14)).foregroundColor(Theme.slate)
            }
            let pts = points
            if pts.count < 2 {
                Text("Collecting data… the first graph appears after about 20 seconds.")
                    .font(.sans(15)).foregroundColor(Theme.slate)
            } else {
                chart(title: "CPU", unit: "%", values: pts.map { $0.cpu }, minY: 0, maxY: 100, warn: 60, hot: 85, pts: pts)
                if s.tempsEnabled, pts.contains(where: { $0.temp != nil }) {
                    let temps = pts.compactMap { $0.temp }
                    let lo = max(0, (temps.min() ?? 30) - 5).rounded(.down)
                    let hi = max(lo + 30, ((temps.max() ?? 60) + 5).rounded(.up))
                    chart(title: "CPU temperature", unit: " °C", values: pts.map { $0.temp }, minY: lo, maxY: hi, warn: 80, hot: 90, pts: pts)
                }
                chart(title: "Memory used", unit: "%", values: pts.map { $0.mem }, minY: 0, maxY: 100, warn: 75, hot: 90, pts: pts)
            }
        }
    }

    private func chart(title: String, unit: String, values: [Double?], minY: Double, maxY: Double,
                       warn: Double, hot: Double, pts: [HistoryPoint]) -> some View {
        let real = values.compactMap { $0 }
        let current = real.last ?? 0
        let peak = real.max() ?? 0
        let avg = real.isEmpty ? 0 : real.reduce(0, +) / Double(real.count)
        let tint: Color = current >= hot ? Theme.high : (current >= warn ? Theme.mid : Theme.ink)
        let span = pts.first.map { Int(Date().timeIntervalSince($0.t) / 60) } ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.sans(17, .medium)).foregroundColor(Theme.ink)
                Spacer()
                Text(String(format: "now %.0f%@ · peak %.0f%@ · avg %.0f%@", current, unit, peak, unit, avg, unit))
                    .font(.sans(14)).monospacedDigit().foregroundColor(Theme.slate)
            }
            LineChart(values: values, minY: minY, maxY: maxY, tint: tint, unit: unit.trimmingCharacters(in: .whitespaces) == "%" ? "%" : "°")
                .frame(height: 120)
            HStack {
                Text("\(span) min ago").font(.sans(12)).foregroundColor(Theme.slate)
                Spacer()
                Text("now").font(.sans(12)).foregroundColor(Theme.slate)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .artifact()
        .accessibilityElement(children: .combine)
    }
}
