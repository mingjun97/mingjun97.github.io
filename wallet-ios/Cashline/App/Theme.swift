import SwiftUI
import UIKit

/// The web app's palette, as dynamic light/dark colors.
enum Theme {
    static let bg = Color.dynamic(0xF2F5F5, 0x0E1518)
    static let surface = Color.dynamic(0xFFFFFF, 0x162227)
    static let surface2 = Color.dynamic(0xEAEFEF, 0x1C2B31)
    static let ink = Color.dynamic(0x16232A, 0xE6EEF0)
    static let muted = Color.dynamic(0x5D6E75, 0x92A5AC)
    static let faint = Color.dynamic(0x8AA0A7, 0x5F757D)
    static let line = Color.dynamic(0xDFE7E8, 0x26343B)
    static let accent = Color.dynamic(0x1E6E62, 0x53C6B1)
    static let accentInk = Color.dynamic(0xFFFFFF, 0x0E1518)
    static let accentTint = Color.dynamic(0xE3F0ED, 0x1B3A35)
    static let good = accent
    static let goodTint = accentTint
    static let warn = Color.dynamic(0xA05E00, 0xE5A83F)
    static let warnTint = Color.dynamic(0xF4E7CE, 0x3A2E14)
    static let danger = Color.dynamic(0xB0392E, 0xE2685B)
    static let dangerTint = Color.dynamic(0xF5E0DD, 0x3E211E)

    static let radius: CGFloat = 14
    static let mono = Font.system(.body, design: .monospaced)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension Double {
    /// "$1,234.56"
    var usd: String { formatted(.currency(code: "USD")) }
}

/// Parses what someone typed into an amount field ("1,234.50", "$20", "-15").
func parseMoney(_ s: String) -> Double? {
    let cleaned = s.replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "$", with: "")
        .trimmingCharacters(in: .whitespaces)
    return Double(cleaned)
}

/// "1234.5" → "1234.50" for pre-filling a text field.
func moneyText(_ x: Double) -> String { x == 0 ? "" : String(format: "%.2f", x) }

/// Card background used across the app.
struct CardBackground: ViewModifier {
    var accentEdge: Color?
    var dashed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if let accentEdge {
                    UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius, style: .continuous)
                        .fill(accentEdge)
                        .frame(width: 3)
                        .opacity(dashed ? 0.6 : 1)
                }
            }
            .shadow(color: .black.opacity(0.05), radius: 7, y: 3)
    }
}

extension View {
    func card(edge: Color? = nil, dashed: Bool = false) -> some View { modifier(CardBackground(accentEdge: edge, dashed: dashed)) }

    /// Small uppercase section label, like the web app's.
    func sectionLabelStyle() -> some View {
        font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.8).foregroundStyle(Theme.muted)
    }
}
