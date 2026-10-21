import SwiftUI
import AppKit

// Steep design tokens (warm paper, ink black, one peach accent, serif headlines, pill controls, 24px cards).
// Signifier/Söhne are commercial fonts, so the substitutes are the system serif (New York) and SF.
// Dark mode is a derived variant: Steep itself is a light theme.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }))
    }

    // Surfaces
    static let canvas = dyn(0xffffff, 0x131416)      // Paper White
    static let mist = dyn(0xf2f2f3, 0x1f2124)        // Mist Gray cards
    static let elevated = dyn(0xffffff, 0x26282c)    // floating artifacts
    static let hairline = dyn(0xececec, 0x2d2f33)

    // Text / ink
    static let ink = dyn(0x17191c, 0xf2f2f3)         // Ink Black
    static let onInk = dyn(0xffffff, 0x17191c)       // text on filled pills
    static let slate = dyn(0x6a6e79, 0xa3a6af)       // muted text (slightly darker than #777b86 for 4.5:1 contrast)

    // Accent card (use once per page)
    static let peach = dyn(0xfbe1d1, 0x3a2a22)       // Blush Peach
    static let sienna = dyn(0x5d2a1a, 0xfbe1d1)      // Sienna Brown

    // Risk colors (added on request; always paired with a text label)
    static let high = dyn(0xb3261e, 0xff8f86)
    static let mid = dyn(0x9a5b00, 0xffc266)
    static let low = dyn(0x2b7a4b, 0x7fdba0)

    static func color(_ r: Risk) -> Color {
        switch r { case .high: return high; case .medium: return mid; case .low: return low }
    }

    /// Load level colors for bars and numbers
    static func load(_ pct: Double) -> Color { pct >= 85 ? high : (pct >= 60 ? mid : ink) }
}

extension Font {
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension View {
    /// Neutral Card: Mist Gray, 24px radius, no shadow, no border.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.mist)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Floating Product Artifact: the only element that earns a (soft) shadow.
    func artifact() -> some View {
        self.background(Theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Controls

struct PillStyle: ButtonStyle {
    enum Kind { case filled, ghost }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(15))
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .foregroundColor(kind == .filled ? Theme.onInk : Theme.ink)
            .background(Capsule().fill(kind == .filled ? Theme.ink : Color.clear))
            .overlay(Capsule().stroke(Theme.ink, lineWidth: kind == .ghost ? 1 : 0))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

struct ArrowLink: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title + " →").font(.sans(15)).underline(hover)
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.ink)
        .onHover { hover = $0 }
    }
}

struct RiskTag: View {
    let risk: Risk
    var body: some View {
        HStack(spacing: 0) {
            Text(risk.rawValue)
                .font(.sans(13, .medium))
                .foregroundColor(Theme.color(risk))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.color(risk).opacity(0.14)))
            Spacer(minLength: 0)
        }
        .frame(width: 68)
        .accessibilityLabel("Risk \(risk.rawValue)")
    }
}

struct Bar: View {
    let fraction: Double
    var tint: Color = Theme.ink

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: max(6, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 6)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.serif(40)).tracking(-0.66).foregroundColor(Theme.ink)
            Text(subtitle).font(.sans(15)).foregroundColor(Theme.slate)
        }
    }
}
