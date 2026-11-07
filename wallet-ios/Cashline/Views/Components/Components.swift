import SwiftUI
import CashlineCore

/// Colored tile with an SF Symbol or a monogram.
struct BillIconView: View {
    let id: String
    var size: CGFloat = 32

    var body: some View {
        let icon = BillIcon.icon(id)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hex: icon.background))
            .overlay {
                switch icon.glyph {
                case let .symbol(name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                case let .monogram(text, fg):
                    Text(text)
                        .font(.system(size: size * (text.count > 2 ? 0.32 : 0.4), weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: fg))
                        .minimumScaleFactor(0.5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Deposit arrow tile.
struct DepositIconView: View {
    var size: CGFloat = 32
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hex: 0x10B981))
            .overlay(Image(systemName: "arrow.down.to.line").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct Chip: View {
    enum Style { case autopay, manual, account, overdue, payroll, oneTime, awaiting, scheduled, pending, linked }
    let text: String
    let style: Style

    init(_ text: String, _ style: Style) { self.text = text; self.style = style }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .overlay {
                if let border {
                    Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1.5, dash: style == .pending ? [3, 2] : []))
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .autopay, .scheduled, .payroll, .oneTime, .linked: return Theme.accent
        case .manual, .awaiting: return Theme.warn
        case .overdue: return .white
        case .account, .pending: return Theme.muted
        }
    }

    private var fill: Color {
        switch style {
        case .autopay, .scheduled, .payroll, .linked: return Theme.accentTint
        case .overdue: return Theme.danger
        case .account: return Theme.surface2
        case .manual, .oneTime, .awaiting, .pending: return .clear
        }
    }

    private var border: Color? {
        switch style {
        case .manual, .awaiting: return Theme.warn
        case .oneTime: return Theme.good
        case .pending: return Theme.faint
        default: return nil
        }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Amount entry backed by text, so a half-typed value is never lost.
struct MoneyField: View {
    let title: String
    @Binding var text: String
    var allowNegative = false
    var prompt = "0.00"

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .keyboardType(allowNegative ? .numbersAndPunctuation : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
        }
    }
}

/// Small pill buttons (e.g. "Today", "On due date").
struct PillButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(selected ? Theme.accentInk : Theme.ink)
                .background(selected ? Theme.accent : Theme.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyCard<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            HStack { actions }.padding(.top, 10)
        }
        .padding(.vertical, 32).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// Filled / tinted action buttons used on cards.
struct CardButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, subtle }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, kind == .subtle ? 6 : 14).padding(.vertical, 8)
            .foregroundStyle(kind == .primary ? Theme.accentInk : kind == .ghost ? Theme.ink : Theme.muted)
            .background(kind == .primary ? Theme.accent : kind == .ghost ? Theme.surface2 : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var cardPrimary: CardButtonStyle { CardButtonStyle(kind: .primary) }
    static var cardGhost: CardButtonStyle { CardButtonStyle(kind: .ghost) }
    static var cardSubtle: CardButtonStyle { CardButtonStyle(kind: .subtle) }
}
