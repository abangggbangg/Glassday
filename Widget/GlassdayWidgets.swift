import EventKit
import SwiftUI
import WidgetKit

// MARK: - Shared

/// Light / dark pairs chosen to pass WCAG AA (4.5:1) as text on the widget background.
/// (Following the app's selected theme needs an App Group; see REVIEW.md P3-1.)
enum Palette {
    static let gold = adaptive(light: 0x8E6F42, dark: 0xD2B07A)     // 4.6:1 on white, 8.7:1 on dark
    static let onGold = adaptive(light: 0xFFFFFF, dark: 0x16130D)   // text on a gold fill
    static let sunday = adaptive(light: 0xC23B36, dark: 0xE0675E)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }
    private static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

struct CalItem {
    let title: String
    let color: Color
    let allDay: Bool
    let start: Date
    let end: Date
}

enum CalData {
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// One store per widget process: EKEventStore is expensive to create, and rebuilding the
    /// month grid itself (at most 42 cells, about once an hour) is cheap, so this is the only cache
    /// worth having. Lazily created on first use, which only happens once access is granted.
    private static let store = EKEventStore()

    static func items(from start: Date, to end: Date) -> [CalItem] {
        guard authorized else { return [] }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred).compactMap { e in
            guard let s = e.startDate, let en = e.endDate else { return nil }
            return CalItem(title: e.title ?? "", color: Color(cgColor: e.calendar.cgColor),
                           allDay: e.isAllDay, start: s, end: en)
        }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.09, green: 0.09, blue: 0.10), Color(red: 0.14, green: 0.13, blue: 0.12)]
                : [Color.white, Color(red: 0.96, green: 0.955, blue: 0.94)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct NeedAccessView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.gold)
            // The whole widget opens the app (widgetURL), where the Connect card is.
            Text("Tap to connect Apple Calendar")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glassday needs calendar access. Opens Glassday to connect Apple Calendar.")
    }
}

// MARK: - Month widget (large)

struct DayCell: Identifiable {
    let id: Int
    let date: Date
    let number: Int
    let inMonth: Bool
    let isToday: Bool
    let isSunday: Bool
    let items: [CalItem]
}

struct MonthEntry: TimelineEntry {
    let date: Date
    let title: String
    let rows: Int
    let days: [DayCell]
    let authorized: Bool
}

struct MonthProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonthEntry { build(Date(), sample: true) }

    func getSnapshot(in context: Context, completion: @escaping (MonthEntry) -> Void) {
        completion(build(Date(), sample: !CalData.authorized))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonthEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400 + 30)
        let next = min(midnight, now.addingTimeInterval(3_600))
        completion(Timeline(entries: [build(now, sample: false)], policy: .after(next)))
    }

    private func build(_ now: Date, sample: Bool) -> MonthEntry {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 1 // Sunday first, like the reference widget

        let first = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let offset = cal.component(.weekday, from: first) - 1
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let rows = Int(ceil(Double(offset + daysInMonth) / 7.0))
        let gridStart = cal.date(byAdding: .day, value: -offset, to: first) ?? first
        let gridEnd = cal.date(byAdding: .day, value: rows * 7, to: gridStart) ?? first

        var buckets: [Int: [CalItem]] = [:]
        let source = sample ? sampleItems(gridStart: gridStart, cal: cal) : CalData.items(from: gridStart, to: gridEnd)
        for item in source {
            var day = max(cal.startOfDay(for: item.start), gridStart)
            let last = item.allDay ? item.end.addingTimeInterval(-1) : item.start
            while day <= last && day < gridEnd {
                let idx = cal.dateComponents([.day], from: gridStart, to: day).day ?? 0
                buckets[idx, default: []].append(item)
                guard let nextDay = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
        }

        let month = cal.component(.month, from: first)
        let days: [DayCell] = (0..<(rows * 7)).map { i in
            let d = cal.date(byAdding: .day, value: i, to: gridStart) ?? gridStart
            let items = (buckets[i] ?? []).sorted {
                $0.allDay != $1.allDay ? $0.allDay : $0.start < $1.start
            }
            return DayCell(id: i, date: d, number: cal.component(.day, from: d),
                           inMonth: cal.component(.month, from: d) == month,
                           isToday: cal.isDate(d, inSameDayAs: now),
                           isSunday: cal.component(.weekday, from: d) == 1,
                           items: items)
        }

        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return MonthEntry(date: now, title: fmt.string(from: first), rows: rows, days: days,
                          authorized: sample || CalData.authorized)
    }

    private func sampleItems(gridStart: Date, cal: Calendar) -> [CalItem] {
        let blue = Color(red: 0.36, green: 0.49, blue: 0.69), amber = Color(red: 0.94, green: 0.66, blue: 0.18)
        let coral = Color(red: 0.94, green: 0.54, blue: 0.49)
        return (0..<35).flatMap { i -> [CalItem] in
            guard let d = cal.date(byAdding: .day, value: i, to: gridStart),
                  (2...6).contains(cal.component(.weekday, from: d)) else { return [] }
            let at = { (h: Int) in cal.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? d }
            return [CalItem(title: "Lecture", color: blue, allDay: false, start: at(9), end: at(11)),
                    CalItem(title: "Lab", color: amber, allDay: false, start: at(14), end: at(16)),
                    CalItem(title: "Gym", color: coral, allDay: false, start: at(18), end: at(19))]
        }
    }
}

struct MonthWidgetView: View {
    let entry: MonthEntry
    private let letters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        if !entry.authorized {
            NeedAccessView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .padding(.leading, 4)
                    .padding(.bottom, 1)
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(letters[i])
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(i == 0 ? Palette.sunday : Color.primary)
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(spacing: 1) {
                    ForEach(0..<entry.rows, id: \.self) { r in
                        HStack(alignment: .top, spacing: 2) {
                            ForEach(entry.days[(r * 7)..<(r * 7 + 7)]) { day in
                                DayCellView(day: day, maxItems: entry.rows > 5 ? 2 : 3)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .padding(12)
        }
    }
}

struct DayCellView: View {
    let day: DayCell
    let maxItems: Int

    var body: some View {
        Link(destination: URL(string: "glassday://day/\(CalData.dayKey(day.date))")!) {
            VStack(spacing: 1.5) {
                Text("\(day.number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(day.isToday ? Palette.onGold : (day.isSunday ? Palette.sunday : Color.primary))
                    .frame(width: 21, height: 17)
                    .background { if day.isToday { Capsule().fill(Palette.gold) } }

                ForEach(Array(day.items.prefix(maxItems).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(item.color)
                            .frame(width: 2.5)
                            .widgetAccentable()
                        Text(item.title)
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 10)
                    .padding(.horizontal, 1.5)
                    .background(RoundedRectangle(cornerRadius: 2.5).fill(item.allDay ? item.color.opacity(0.2) : Color.clear))
                }

                if day.items.count > maxItems {
                    Text("+ \(day.items.count - maxItems)")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 7).fill(day.isToday ? Palette.gold.opacity(0.12) : Color.clear))
            .opacity(day.inMonth ? 1 : 0.35)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens this day in Glassday")
    }

    /// "Tuesday 10 November, today, 3 events: Lecture, Lab, Gym"
    private var accessibilityText: String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        if day.isToday { parts.append("today") }
        switch day.items.count {
        case 0: parts.append("no events")
        case 1: parts.append("1 event: \(day.items[0].title)")
        default: parts.append("\(day.items.count) events: " + day.items.prefix(4).map(\.title).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

struct MonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassdayMonth", provider: MonthProvider()) { entry in
            MonthWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
                // Day cells link to their own day; anywhere else (title, or the no-access state) opens today.
                .widgetURL(URL(string: "glassday://day/\(CalData.dayKey(entry.date))"))
        }
        .configurationDisplayName("Month")
        .description("Your whole month with Apple Calendar events. Tap a day to open it.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Today widget (small + medium)

struct TodayEntry: TimelineEntry {
    let date: Date
    let upcoming: [CalItem]
    let allDay: [CalItem]
    let authorized: Bool
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { sample() }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(CalData.authorized ? entry(at: Date(), all: todayItems()) : sample())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date(), all = todayItems()
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        // A new entry each time an event ends, so the list moves on by itself.
        var times = [now] + all.filter { !$0.allDay && $0.end > now && $0.end < midnight }.map(\.end)
        times = Array(Set(times)).sorted().prefix(12).map { $0 }
        var entries = times.map { entry(at: $0, all: all) }
        // Turn over to tomorrow (new date, new all-day events) exactly at midnight,
        // even if WidgetKit runs the next reload late.
        entries.append(entry(at: midnight, all: todayItems(on: midnight)))
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }

    private func todayItems(on day: Date = Date()) -> [CalItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return CalData.items(from: start, to: end).sorted { $0.start < $1.start }
    }

    private func entry(at date: Date, all: [CalItem]) -> TodayEntry {
        TodayEntry(date: date,
                   upcoming: all.filter { !$0.allDay && $0.end > date },
                   allDay: all.filter(\.allDay),
                   authorized: CalData.authorized)
    }

    private func sample() -> TodayEntry {
        let now = Date()
        return TodayEntry(date: now, upcoming: [
            CalItem(title: "Lecture", color: Color(red: 0.36, green: 0.49, blue: 0.69), allDay: false,
                    start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(9_000)),
            CalItem(title: "Gym", color: Color(red: 0.48, green: 0.71, blue: 0.38), allDay: false,
                    start: now.addingTimeInterval(14_400), end: now.addingTimeInterval(18_000))
        ], allDay: [], authorized: true)
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        if !entry.authorized {
            NeedAccessView()
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.date, format: .dateTime.weekday(.wide))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .foregroundStyle(Palette.gold)
            Text(entry.date, format: .dateTime.day())
                .font(.system(size: 38, weight: .heavy, design: .rounded))
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            dateHeader
            Spacer(minLength: 0)
            if let next = entry.upcoming.first {
                row(next, compact: true)
            } else {
                Text(entry.allDay.first?.title ?? "Nothing else today")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                dateHeader
                Spacer(minLength: 0)
                ForEach(Array(entry.allDay.prefix(2).enumerated()), id: \.offset) { _, a in
                    Text(a.title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(a.color.opacity(0.2)))
                }
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if entry.upcoming.isEmpty {
                    Spacer()
                    Text("Nothing else today")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(Array(entry.upcoming.prefix(3).enumerated()), id: \.offset) { _, item in
                        row(item, compact: false)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private func row(_ item: CalItem, compact: Bool) -> some View {
        let live = item.start <= entry.date && entry.date < item.end
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .frame(width: 4)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: compact ? 13 : 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if live {
                    Text("ends \(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.sunday)
                } else {
                    Text(item.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: compact ? 34 : 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live
            ? "\(item.title), now, ends \(item.end.formatted(date: .omitted, time: .shortened))"
            : "\(item.title), \(item.start.formatted(date: .omitted, time: .shortened)) to \(item.end.formatted(date: .omitted, time: .shortened))")
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlassdayToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(URL(string: "glassday://day/\(CalData.dayKey(entry.date))"))
        }
        .configurationDisplayName("Today")
        .description("What's next today.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Bundle

@main
struct GlassdayWidgets: WidgetBundle {
    var body: some Widget {
        MonthWidget()
        TodayWidget()
    }
}
