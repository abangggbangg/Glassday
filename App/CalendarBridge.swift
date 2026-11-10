import EventKit
import UIKit
import WebKit
import WidgetKit

/// Two-way link between the Glassday page and Apple Calendar (EventKit).
///
/// Page → native messages (window.webkit.messageHandlers.gd.postMessage):
///   ready, access, load{from,to}, upsert{...}, delete{series,occDate,span},
///   persist{data}, haptic{style}, awake{on}
/// Native → page calls: GDN.access, GDN.calendars, GDN.events, GDN.saved, GDN.openDay
final class CalendarBridge: NSObject, WKScriptMessageHandler {
    static let stateKey = "gd.state"

    let store = EKEventStore()
    weak var webView: WKWebView?

    private var range: (start: Date, end: Date, from: String, to: String)?
    private var pageReady = false
    private var pendingDay: String?
    private var reloadWork: DispatchWorkItem?
    private var lastStatus: EKAuthorizationStatus?
    private let cal = Calendar.current

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .EKEventStoreChanged, object: store)
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            if let day = pendingDay { pendingDay = nil; openDay(day) }
        case "status":
            reportStatus()
        case "access":
            requestAccess()
        case "settings":
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case "load":
            if let from = body["from"] as? String, let to = body["to"] as? String,
               let a = date(from), let b = date(to), let end = cal.date(byAdding: .day, value: 1, to: b) {
                range = (a, end, from, to)
                pushEvents()
            }
        case "upsert":
            upsert(body)
        case "delete":
            delete(body)
        case "persist":
            if let data = body["data"] as? String { UserDefaults.standard.set(data, forKey: Self.stateKey) }
        case "haptic":
            haptic(body["style"] as? String)
        case "awake":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        default:
            break
        }
    }

    // MARK: access

    /// Tell the page where access stands without ever showing the system prompt.
    /// "ask" means not decided yet: the page explains why before asking (HIG: ask in context).
    private func reportStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        lastStatus = status
        switch status {
        case .fullAccess: accessGranted()
        case .notDetermined: run("GDN.access('ask')")
        case .writeOnly: run("GDN.access('limited')")   // can add events but not read them
        default: run("GDN.access('denied')")
        }
    }

    /// Only called when the person taps Connect on the page.
    private func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return reportStatus() }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.store.reset() }
                self.reportStatus()
            }
        }
    }

    private func accessGranted() {
        run("GDN.access('granted')")
        sendCalendars()
        pushEvents()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The web view is about to reload (content process died). Forget page state and
    /// never leave the screen pinned awake by a page that no longer exists.
    func pageWillReload() {
        pageReady = false
        range = nil
        lastStatus = nil
        reloadWork?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func appBecameActive() {
        // Only when access changed (e.g. in Settings). Event edits made elsewhere already
        // arrive through EKEventStoreChanged, so an unchanged status needs no reload.
        guard pageReady, EKEventStore.authorizationStatus(for: .event) != lastStatus else { return }
        reportStatus()
    }

    @objc private func storeChanged() {
        DispatchQueue.main.async { self.scheduleReload() }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sendCalendars()
            self?.pushEvents()
            WidgetCenter.shared.reloadAllTimelines()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: reading

    private func sendCalendars() {
        guard hasAccess else { return }
        let list: [[String: Any]] = store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { ["id": $0.calendarIdentifier, "title": $0.title, "color": hex($0.cgColor)] }
        let def = store.defaultCalendarForNewEvents?.calendarIdentifier ?? ""
        run("GDN.calendars(\(json(list)), \(json(def)))")
    }

    private func pushEvents() {
        guard hasAccess, let r = range else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: r.start, end: r.end, calendars: nil))
        var out: [[String: Any]] = []
        out.reserveCapacity(events.count)
        for e in events {
            guard let start = e.startDate, let end = e.endDate else { continue }
            var item: [String: Any] = [
                "series": e.calendarItemIdentifier,
                "title": e.title ?? "",
                "date": key(start),
                "allDay": e.isAllDay,
                "color": hex(e.calendar.cgColor),
                "cal": e.calendar.title,
                "calId": e.calendar.calendarIdentifier,
                "notes": e.notes ?? "",
                "editable": e.calendar.allowsContentModifications,
                "rep": repeatName(e)
            ]
            item["endDate"] = key(end.addingTimeInterval(-1))
            if !e.isAllDay {
                item["start"] = cal.component(.hour, from: start) * 60 + cal.component(.minute, from: start)
                item["dur"] = max(5, Int(end.timeIntervalSince(start) / 60))
            }
            out.append(item)
        }
        run("GDN.events(\(json(out)), \(json(r.from)), \(json(r.to)))")
    }

    private func repeatName(_ e: EKEvent) -> String {
        guard let rule = e.recurrenceRules?.first else { return "none" }
        switch rule.frequency {
        case .daily where rule.interval == 1:
            return "daily"
        case .weekly where rule.interval == 1:
            let days = Set((rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue })
            if days == Set(2...6) { return "weekdays" }
            if days.count <= 1 { return "weekly" }
            return "custom"
        case .monthly where rule.interval == 1 && (rule.daysOfTheWeek ?? []).isEmpty:
            return "monthly"
        case .yearly where rule.interval == 1:
            return "yearly"
        default:
            return "custom"
        }
    }

    // MARK: writing

    private func occurrence(_ series: String, on day: String) -> EKEvent? {
        guard let d = date(day), let next = cal.date(byAdding: .day, value: 1, to: d) else { return nil }
        let pred = store.predicateForEvents(withStart: d, end: next, calendars: nil)
        return store.events(matching: pred).first { $0.calendarItemIdentifier == series }
    }

    private func upsert(_ b: [String: Any]) {
        let req = b["reqId"] as? String ?? ""
        guard hasAccess else { return reply(req, nil, "Calendar access is off") }
        guard let day = b["date"] as? String, let base = date(day) else {
            return reply(req, nil, "Missing date")
        }
        let allDay = (b["allDay"] as? Bool) ?? false
        let start: Date
        let finish: Date
        if allDay {
            // Inclusive last day, e.g. Fri → Sun is three days.
            let last = (b["endDate"] as? String).flatMap { date($0) } ?? base
            start = base
            finish = cal.date(byAdding: .second, value: 86_399, to: max(last, base)) ?? base
        } else {
            guard let startMin = b["start"] as? Int, let dur = b["dur"] as? Int,
                  let s = cal.date(byAdding: .minute, value: startMin, to: base) else {
                return reply(req, nil, "Missing time")
            }
            start = s
            finish = s.addingTimeInterval(TimeInterval(max(5, dur) * 60))
        }

        var event: EKEvent
        var span: EKSpan = .thisEvent
        if let series = b["series"] as? String {
            // Editing an existing event. If it can't be found (changed or deleted in Calendar
            // since we loaded), never fall through to creating a duplicate.
            guard let occ = b["occDate"] as? String, let existing = occurrence(series, on: occ) else {
                scheduleReload()
                return reply(req, nil, "It was changed or removed in Apple Calendar, so nothing was saved")
            }
            event = existing
            if existing.hasRecurrenceRules { span = .futureEvents }
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let calId = b["calId"] as? String, let target = store.calendar(withIdentifier: calId),
           target.allowsContentModifications {
            event.calendar = target
        }
        guard event.calendar != nil else { return reply(req, nil, "No calendar to save into") }

        event.title = (b["title"] as? String) ?? "Untitled"
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = finish
        if let notes = b["notes"] as? String { event.notes = notes.isEmpty ? nil : notes }

        if let rep = b["repeat"] as? String, rep != "custom" {
            event.recurrenceRules = rule(for: rep).map { [$0] }
        }

        do {
            try store.save(event, span: span, commit: true)
            reply(req, event.calendarItemIdentifier, nil)
        } catch {
            reply(req, nil, error.localizedDescription)
        }
        scheduleReload()
    }

    /// span: "one" = this occurrence, "future" = this and later, "all" = the whole series
    /// Failures are reported back (GDN.saved("delete", "", error)) so the page never claims a
    /// delete that didn't happen; the reload that always follows restores the true state.
    private func delete(_ b: [String: Any]) {
        defer { scheduleReload() }
        guard hasAccess else { return reply("delete", nil, "Calendar access is off") }
        guard let series = b["series"] as? String else { return reply("delete", nil, "Missing event") }
        let span = b["span"] as? String ?? "one"

        let target: EKEvent?
        let ekSpan: EKSpan
        if span == "all" {
            // For a repeating event this returns the first occurrence, so .futureEvents removes
            // every repeat (daily, weekly, monthly and yearly rules alike).
            target = store.calendarItem(withIdentifier: series) as? EKEvent
            ekSpan = .futureEvents
        } else {
            target = (b["occDate"] as? String).flatMap { occurrence(series, on: $0) }
            ekSpan = span == "one" ? .thisEvent : .futureEvents
        }
        guard let event = target else {
            return reply("delete", nil, "It was already changed or removed in Apple Calendar")
        }
        do {
            try store.remove(event, span: ekSpan, commit: true)
        } catch {
            reply("delete", nil, error.localizedDescription)
        }
    }

    private func rule(for name: String) -> EKRecurrenceRule? {
        switch name {
        case "daily":
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly":
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly":
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly":
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        case "weekdays":
            let days = (2...6).compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        default:
            return nil
        }
    }

    private func reply(_ req: String, _ id: String?, _ err: String?) {
        run("GDN.saved(\(json(req)), \(json(id ?? "")), \(err.map { json($0) } ?? "null"))")
    }

    // MARK: misc

    func openDay(_ day: String) {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return }
        if pageReady { run("GDN.openDay(\(json(day)))") } else { pendingDay = day }
    }

    private func haptic(_ style: String?) {
        switch style {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func run(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.GDN && (\(js))", completionHandler: nil)
        }
    }

    private func key(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    private func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private func hex(_ cg: CGColor?) -> String {
        guard let cg else { return "#5B7DB1" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(cgColor: cg).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func json(_ value: Any) -> String {
        if let s = value as? String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(arr.dropFirst().dropLast()).replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
