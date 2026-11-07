import SwiftUI
import CashlineCore

/// One date on the 30-day timeline.
struct TimelineGroup: Identifiable {
    enum Item: Identifiable {
        case bill(UpcomingBill)
        case deposit(UpcomingDeposit)
        case scheduled(UpcomingScheduled)

        var id: String {
            switch self {
            case let .bill(x): return "bill-" + x.id
            case let .deposit(x): return "dep-" + x.id
            case let .scheduled(x): return "sched-" + x.id
            }
        }
    }

    let date: Day
    let days: Int
    var hasOverdueBill = false
    var items: [Item] = []
    var id: String { date.iso }

    /// Groups the next 30 days of bills, deposits and held payments by date.
    static func build(_ e: Engine, window: Int = 30) -> [TimelineGroup] {
        var groups: [Day: TimelineGroup] = [:]
        func add(_ d: Day, _ item: Item, overdue: Bool = false) {
            var g = groups[d] ?? TimelineGroup(date: d, days: e.today.days(until: d))
            if overdue { g.hasOverdueBill = true }
            g.items.append(item)
            groups[d] = g
        }
        for x in e.upcomingBills(within: window) { add(x.due.date, .bill(x), overdue: x.due.overdue) }
        for x in e.upcomingDeposits(within: window) { add(x.occurrence.date, .deposit(x)) }
        for x in e.upcomingScheduled(within: window) { add(x.days < 0 ? e.today : x.date, .scheduled(x)) }
        return groups.values.sorted { $0.date < $1.date }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    /// Id of the row at the top of the timeline (a date's iso, "now" or "top").
    @State private var position: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.state.isEmpty { emptyState } else { content }
            }
            .background(Theme.bg)
            .navigationTitle("Cashline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(DayText.weekdays[store.today.weekday]), \(DayText.short(store.today))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            EmptyCard(title: "Track every due date in one place.",
                      message: "Add your checking accounts, then the credit cards and utility bills that pull from them.") {
                Button("Add first account") { store.tab = .accounts; store.sheet = .newAccount }.buttonStyle(.cardPrimary)
                Button("Load sample data") { store.loadSample() }.buttonStyle(.cardGhost)
            }
            .padding(16)
        }
    }

    private var content: some View {
        let e = store.engine
        let groups = TimelineGroup.build(e)
        let steps = e.balanceSteps()
        let focused = focusedDay(groups)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary(e).id("top")
                if groups.isEmpty {
                    EmptyCard(title: "Nothing due in the next 30 days.", message: "Add bills to see them on the timeline.") {
                        Button("Add a bill") { store.tab = .bills; store.sheet = .newBill }.buttonStyle(.cardPrimary)
                    }
                } else {
                    ForEach(rows(groups), id: \.self) { row in
                        if row == "now" {
                            TodayMarker(today: store.today).id("now")
                        } else if let g = groups.first(where: { $0.id == row }) {
                            DayGroupView(group: g, steps: steps).id(g.id)
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.bottom, 90)
        }
        .scrollPosition(id: $position, anchor: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            DayStrip(focused: focused) { day in jump(to: day, groups: groups) }
                .background(Theme.bg)
                .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
        .refreshable {
            store.refresh()
            await store.sync()
        }
    }

    /// Row ids in order, with the today marker before the first future date
    /// (unless a group is already on today).
    private func rows(_ groups: [TimelineGroup]) -> [String] {
        var out: [String] = []
        var placed = groups.contains { $0.days == 0 }
        for g in groups {
            if !placed && g.days > 0 { out.append("now"); placed = true }
            out.append(g.id)
        }
        if !placed { out.append("now") }
        return out
    }

    /// The date the person is reading, for the strip's highlight.
    private func focusedDay(_ groups: [TimelineGroup]) -> Day {
        guard let p = position, let d = Day(iso: p) else { return store.today }
        return d
    }

    private func jump(to day: Day, groups: [TimelineGroup]) {
        if groups.contains(where: { $0.date == day }) {
            withAnimation(.snappy) { position = day.iso }
        } else if day == store.today {
            withAnimation(.snappy) { position = "now" }
        } else {
            store.show(day < store.today ? "That date has passed — nothing left to act on."
                                         : "Nothing on that day in the next 30 days.")
        }
    }

    // MARK: summary

    @ViewBuilder
    private func summary(_ e: Engine) -> some View {
        let s = store.state
        let cash = s.accounts.reduce(0) { $0 + $1.balance }
        let up = e.upcomingBills(within: 30)
        let sched = e.upcomingScheduled(within: 30)
        let due = up.reduce(0) { $0 + $1.bill.outflow } + sched.reduce(0) { $0 + $1.payment.amount }
        let manual = up.filter { !$0.bill.autopay }.count
        let deps = e.upcomingDeposits(within: 30)
        let expected = deps.reduce(0) { $0 + $1.deposit.amount }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Tile(label: "Cash on hand", value: cash.usd, hint: "\(s.accounts.count) account\(s.accounts.count == 1 ? "" : "s")")
                Tile(label: "Due next 30 days", value: due.usd,
                     hint: "\(up.count) bill\(up.count == 1 ? "" : "s") · \(manual) manual" + (sched.isEmpty ? "" : " · \(sched.count) scheduled"),
                     valueColor: due > cash ? Theme.danger : nil)
            }
            if expected > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expected deposits · 30 days").sectionLabelStyle()
                        Text("\(deps.count) deposit\(deps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text("+" + expected.usd).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.good)
                }
                .card()
            }
            alerts(e)
            HStack {
                Text("Next 30 days").sectionLabelStyle()
                Spacer()
                CalendarLegend()
            }
            .padding(.top, 6)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func alerts(_ e: Engine) -> some View {
        let s = store.state
        let lead = s.settings.leadDays
        let up = e.upcomingBills(within: 30).filter { !$0.bill.autopay }
        let overdue = up.filter(\.due.overdue)
        let soon = up.filter { !$0.due.overdue && $0.due.days <= lead }
        let short = e.shortAccounts()
        if !(overdue.isEmpty && soon.isEmpty && short.isEmpty) {
            VStack(spacing: 8) {
                ForEach(overdue) { x in
                    AlertRow(danger: true, text: Text("**\(x.bill.name)** is \(-x.due.days) day\(x.due.days == -1 ? "" : "s") past due — \(x.bill.amount.usd) from \(s.accountName(x.bill.accountId))."))
                }
                ForEach(soon) { x in
                    AlertRow(danger: false, text: Text("**\(x.bill.name)** needs a manual payment of \(x.bill.amount.usd) — \(DayText.relative(x.due.days).lowercased())."))
                }
                ForEach(short) { x in
                    AlertRow(danger: true, text: Text("**\(x.account.name)** is projected to dip \((-x.projection.minimum).usd) below zero around \(DayText.short(x.projection.minimumDate)), even counting expected deposits."))
                }
            }
        }
    }
}

private struct Tile: View {
    let label: String
    let value: String
    let hint: String
    var valueColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).sectionLabelStyle().lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(valueColor ?? Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(hint).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct AlertRow: View {
    let danger: Bool
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(danger ? Theme.danger : Theme.warn).frame(width: 8, height: 8)
            text.font(.subheadline).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(danger ? Theme.dangerTint : Theme.warnTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The date "coin" + its cards.
private struct DayGroupView: View {
    let group: TimelineGroup
    let steps: [TimelineKey: BalanceStep]

    var body: some View {
        let d = group.date
        HStack(alignment: .top, spacing: 12) {
            DateCoin(top: group.hasOverdueBill ? "!" : DayText.months[d.monthIndex], number: d.day,
                     style: group.days == 0 ? .today : group.hasOverdueBill ? .overdue : .normal)
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.caption.weight(group.hasOverdueBill ? .semibold : .regular))
                    .foregroundStyle(group.hasOverdueBill ? Theme.danger : Theme.muted)
                ForEach(group.items) { item in
                    switch item {
                    case let .bill(x): BillCard(item: x, step: steps[.bill(x.bill.id)])
                    case let .deposit(x): DepositCard(deposit: x.deposit, occurrence: x.occurrence)
                    case let .scheduled(x): ScheduledCard(item: x, step: steps[.scheduled(x.payment.id)])
                    }
                }
            }
        }
    }

    private var label: String {
        let d = group.date
        let date = "\(DayText.months[d.monthIndex]) \(d.day)"
        if group.days < 0 && !group.hasOverdueBill { return "\(date) · expected, not yet received" }
        return "\(date) · \(DayText.relative(group.days))"
    }
}

private struct TodayMarker: View {
    let today: Day

    var body: some View {
        HStack(spacing: 12) {
            DateCoin(top: DayText.months[today.monthIndex], number: today.day, style: .today)
            Text("Today · \(DayText.short(today))")
                .font(.caption2.weight(.bold)).textCase(.uppercase).tracking(1)
                .foregroundStyle(Theme.accent)
            LinearGradient(colors: [Theme.accent, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 2).clipShape(Capsule())
        }
    }
}

struct DateCoin: View {
    enum Style { case normal, today, overdue }
    let top: String
    let number: Int
    var style: Style = .normal

    var body: some View {
        VStack(spacing: 0) {
            Text(top).font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(style == .today ? Theme.accentInk : Theme.muted)
            Text("\(number)").font(.system(size: 17, weight: .bold))
                .foregroundStyle(style == .today ? Theme.accentInk : style == .overdue ? Theme.danger : Theme.ink)
        }
        .frame(width: 44)
        .padding(.vertical, 4)
        .background(style == .today ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style == .today ? Theme.accent : style == .overdue ? Theme.danger : Theme.line))
        .accessibilityHidden(true)
    }
}

// MARK: - day strip

/// Five weeks of days (one before this week, four ahead) with event dots.
/// Tapping a day scrolls the timeline to it; scrolling the timeline moves
/// the highlight.
struct DayStrip: View {
    @Environment(AppStore.self) private var store
    let focused: Day
    let onSelect: (Day) -> Void
    @State private var stripPosition: String?

    var body: some View {
        let t = store.today
        let start = t.adding(days: -t.weekday - 7)
        let days = (0..<35).map { start.adding(days: $0) }
        let events = store.engine.calendarEvents(from: start, through: days[34])
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let markers = Array((events[d] ?? []).map(\.marker).sorted().prefix(3))
                    Button { onSelect(d) } label: {
                        DayCell(day: d, today: t, focused: d == focused, markers: markers)
                    }
                    .buttonStyle(.plain)
                    .id(d.iso)
                    .accessibilityLabel("\(DayText.short(d)): \(markers.isEmpty ? "nothing" : "\(events[d]?.count ?? 0) items")")
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
        }
        .scrollPosition(id: $stripPosition, anchor: .center)
        .frame(height: 66)
        .padding(.vertical, 4)
        .onAppear { stripPosition = focused.iso }
        .onChange(of: focused) { _, d in withAnimation(.snappy) { stripPosition = d.iso } }
    }
}

private struct DayCell: View {
    let day: Day
    let today: Day
    let focused: Bool
    let markers: [CalendarMarker]

    var body: some View {
        VStack(spacing: 2) {
            Text(day.day == 1 ? DayText.months[day.monthIndex] : String(DayText.weekdays[day.weekday].prefix(2)))
                .font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(focused ? Theme.accentInk : day.day == 1 ? Theme.accent : Theme.muted)
            Text("\(day.day)")
                .font(.system(size: 15, weight: day == today ? .heavy : .semibold))
                .foregroundStyle(focused ? Theme.accentInk : day < today ? Theme.faint : Theme.ink)
                .frame(minWidth: 24)
                .padding(.vertical, 1)
                .background {
                    if day == today && !focused { RoundedRectangle(cornerRadius: 7).fill(Theme.accentTint) }
                }
            HStack(spacing: 3) {
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    Circle().fill(m.color).frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(focused ? Theme.accentInk : .clear, lineWidth: 1))
                }
            }
            .frame(height: 5)
        }
        .frame(width: 42, height: 58)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(focused ? Theme.accent : markers.isEmpty ? .clear : Theme.surface)
        }
        .overlay {
            if !focused && !markers.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line)
            }
        }
    }
}

struct CalendarLegend: View {
    var body: some View {
        Menu {
            ForEach(CalendarMarker.allCases, id: \.self) { m in
                Label(m.label, systemImage: "circle.fill")
            }
        } label: {
            HStack(spacing: 3) {
                ForEach(CalendarMarker.allCases, id: \.self) { m in Circle().fill(m.color).frame(width: 6, height: 6) }
                Image(systemName: "info.circle").font(.caption2)
            }
            .foregroundStyle(Theme.muted)
        }
        .accessibilityLabel("Calendar legend")
    }
}

extension CalendarMarker {
    var color: Color {
        switch self {
        case .overdue: return Theme.danger
        case .manual: return Theme.warn
        case .scheduled: return Theme.accent
        case .deposit: return Theme.good
        case .autopayOrPaid: return Theme.faint
        }
    }
}
