import AppKit
import SwiftUI

// A small black panel that grows out of the notch when the mouse rests next to it,
// like a menu bar popover that lives in the notch. Off by default on Macs without a notch.
// Sizes come from the real notch (safeAreaInsets + auxiliary areas, in points), so they are
// correct for every MacBook model and every "Looks like" display resolution.

// MARK: - Geometry

struct NotchGeometry {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let scale: CGFloat                 // 1.0 at the default 14-inch layout (1512 pt wide)

    static func detect(on screen: NSScreen) -> NotchGeometry? {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return nil }                       // no notch on this display
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        var w = screen.frame.width - left - right
        if left <= 0 || right <= 0 || w < 100 || w > 400 { w = 190 }   // safe fallback if macOS reports nothing
        let scale = min(max(screen.frame.width / 1512, 0.85), 1.35)
        return NotchGeometry(screen: screen, notchWidth: w, notchHeight: top, scale: scale)
    }

    /// First display that has a notch (normally the built-in one).
    static func firstNotched() -> NotchGeometry? {
        for s in NSScreen.screens { if let g = detect(on: s) { return g } }
        return nil
    }

    var panelSize: NSSize { NSSize(width: 392 * scale, height: (notchHeight + 150) * scale.squareRootBlend) }

    var panelRect: NSRect {
        let f = screen.frame
        let sz = panelSize
        return NSRect(x: f.midX - sz.width / 2, y: f.maxY - sz.height, width: sz.width, height: sz.height)
    }

    /// Where the mouse has to be (screen coordinates) to open the popover: the notch plus a small margin.
    var triggerRect: NSRect {
        let f = screen.frame
        let margin: CGFloat = 14
        return NSRect(x: f.midX - notchWidth / 2 - margin, y: f.maxY - notchHeight - 2,
                      width: notchWidth + margin * 2, height: notchHeight + 8)
    }

    var summary: String {
        String(format: "Notch detected: %.0f × %.0f pt on a display of %.0f × %.0f pt.",
               notchWidth, notchHeight, screen.frame.width, screen.frame.height)
    }
}

private extension CGFloat {
    /// Grows the height more gently than the width on large displays.
    var squareRootBlend: CGFloat { 1 + (self - 1) * 0.6 }
}

// MARK: - State shared with the SwiftUI view

final class NotchModel: ObservableObject {
    @Published var expanded = false
    var geo: NotchGeometry?
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Allow the window to sit over the menu bar / notch area instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Controller

final class NotchController {
    private let state: AppState
    private let model = NotchModel()
    private var panel: NotchPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var showWork: DispatchWorkItem?
    private var outsideTicks = 0
    private var generation = 0
    private var screenObserver: NSObjectProtocol?

    init(state: AppState) { self.state = state }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.mouseMoved() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.mouseMoved(); return e
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide(immediately: true)
        }
    }

    private func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        globalMonitor = nil; localMonitor = nil; screenObserver = nil
        hide(immediately: true)
    }

    // Cheap check on every mouse move; does nothing unless the pointer is next to the notch.
    private func mouseMoved() {
        guard !model.expanded else { return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) || $0.frame.maxY == p.y }),
              let g = NotchGeometry.detect(on: screen), g.triggerRect.contains(p) else {
            showWork?.cancel(); showWork = nil
            return
        }
        guard showWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.showWork = nil
            // still near the notch after the short dwell time?
            let now = NSEvent.mouseLocation
            if g.triggerRect.contains(now) { self?.show(g) }
        }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)   // dwell: ignores quick fly-bys
    }

    private func show(_ g: NotchGeometry) {
        generation += 1
        model.geo = g
        if panel == nil {
            let p = NotchPanel(contentRect: g.panelRect, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: NotchPopoverView(model: model, s: state))
            host.sizingOptions = []          // the controller sets the panel size, not SwiftUI
            p.contentView = host
            panel = p
        }
        panel?.setFrame(g.panelRect, display: false)
        model.expanded = false
        panel?.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.model.expanded = true }

        outsideTicks = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.poll() }
    }

    // While open: close when the pointer has been away from both the notch and the panel for ~0.35 s.
    private func poll() {
        guard let g = model.geo else { hide(immediately: true); return }
        let p = NSEvent.mouseLocation
        let keep = g.panelRect.insetBy(dx: -8, dy: -8).contains(p) || g.triggerRect.insetBy(dx: -6, dy: -6).contains(p)
            || p.y >= g.screen.frame.maxY - 1 && abs(p.x - g.screen.frame.midX) < g.panelSize.width / 2
        if keep { outsideTicks = 0 } else { outsideTicks += 1 }
        if outsideTicks >= 3 { hide(immediately: false) }
    }

    private func hide(immediately: Bool) {
        showWork?.cancel(); showWork = nil
        pollTimer?.invalidate(); pollTimer = nil
        guard let panel = panel, panel.isVisible else { model.expanded = false; return }
        generation += 1
        let gen = generation
        model.expanded = false
        let delay: TimeInterval = immediately ? 0 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.generation == gen, !self.model.expanded else { return }
            self.panel?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI content

/// Rectangle with square top corners (they sit under the screen edge, like the notch) and rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, rect.width / 2, rect.height)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct NotchPopoverView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var s: AppState

    // Fixed palette: the popover is always black so it blends into the notch, in light and dark mode.
    private let text = Color.white
    private let muted = Color(white: 0.66)
    private let warn = Color(red: 1.0, green: 0.76, blue: 0.40)
    private let bad = Color(red: 1.0, green: 0.56, blue: 0.53)
    private let good = Color(red: 0.50, green: 0.86, blue: 0.63)

    var body: some View {
        let g = model.geo
        let k = g?.scale ?? 1
        let size = g?.panelSize ?? NSSize(width: 392, height: 190)
        let notchW = g?.notchWidth ?? 190
        let notchH = g?.notchHeight ?? 32
        let open = model.expanded
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Closed = exactly the notch. Open = full panel. With Reduce Motion the size does not move, only opacity changes.
        let w = open || reduce ? size.width : notchW
        let h = open || reduce ? size.height : notchH
        let enter = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.3)
        let exit = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)

        return ZStack(alignment: .top) {
            NotchShape(radius: 24 * k)
                .fill(Color.black)
                .frame(width: w, height: h)
            content(k: k, notchH: notchH)
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(open ? 1 : 0)
                .offset(y: open || reduce ? 0 : -6)
                .animation(open ? enter.delay(0.08) : exit, value: open)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(reduce ? (open ? 1 : 0) : 1)
        .animation(open ? enter : exit, value: open)
    }

    private func content(k: CGFloat, notchH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * k) {
            Spacer().frame(height: notchH + 2 * k)
            HStack(alignment: .top, spacing: 8 * k) {
                stat("CPU", s.cpu.map { String(format: "%.0f%%", $0.total) } ?? "--", sub: "load", tint: loadTint(s.cpu?.total ?? 0), k: k)
                stat("TEMP", s.temps?.cpuMax.map { String(format: "%.0f°", $0) } ?? "--", sub: s.thermal, tint: tempTint(s.temps?.cpuMax), k: k)
                stat("MEMORY", s.mem.map { String(format: "%.0f%%", Double($0.used) / Double(max($0.total, 1)) * 100) } ?? "--",
                     sub: s.mem.map { "\($0.pressure.rawValue)" } ?? "", tint: memTint(), k: k)
                batteryStat(k: k)
            }
            HStack(spacing: 14 * k) {
                Label(fmtRate(s.netDown), systemImage: "arrow.down")
                Label(fmtRate(s.netUp), systemImage: "arrow.up")
                Spacer()
            }
            .font(.system(size: 12 * k, weight: .medium)).monospacedDigit().foregroundColor(text)
            Divider().background(Color(white: 0.25))
            VStack(spacing: 3 * k) {
                ForEach(Array(s.procs.sorted { $0.cpu > $1.cpu }.prefix(3))) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu)).monospacedDigit().foregroundColor(muted)
                    }
                    .font(.system(size: 12 * k)).foregroundColor(text)
                }
            }
        }
        .padding(.horizontal, 20 * k)
        .padding(.bottom, 14 * k)
    }

    private func stat(_ title: String, _ value: String, sub: String, tint: Color, k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            Text(title).font(.system(size: 10 * k, weight: .medium)).foregroundColor(muted)
            Text(value).font(.system(size: 20 * k, weight: .medium)).monospacedDigit().foregroundColor(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10 * k)).foregroundColor(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func batteryStat(k: CGFloat) -> some View {
        if let b = s.battery {
            let tint: Color = (!b.onAC && b.percent <= 20) ? bad : ((!b.onAC && b.percent <= 40) ? warn : text)
            stat("BATTERY", "\(b.percent)%", sub: b.isCharging ? "Charging" : (b.onAC ? "Plugged in" : "On battery"), tint: tint, k: k)
        } else {
            stat("POWER", "AC", sub: "No battery", tint: text, k: k)
        }
    }

    private func loadTint(_ v: Double) -> Color { v >= 85 ? bad : (v >= 60 ? warn : text) }
    private func tempTint(_ t: Double?) -> Color { guard let t = t else { return text }; return t >= 90 ? bad : (t >= 80 ? warn : text) }
    private func memTint() -> Color {
        switch s.mem?.pressure ?? .normal { case .critical: return bad; case .warning: return warn; default: return good }
    }
}
