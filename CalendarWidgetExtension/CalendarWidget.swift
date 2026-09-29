import WidgetKit
import SwiftUI

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let events: [WidgetEvent]
    let signedIn: Bool
    // Only fetched (and only shown) in the medium/large sizes — the small widget has no
    // room for a second column.
    let scratchText: String?
}

struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(
            date: Date(),
            events: [
                WidgetEvent(id: "p1", title: "Team standup", start: Date(), isAllDay: false),
                WidgetEvent(id: "p2", title: "Lunch with Alex", start: Date().addingTimeInterval(3600 * 3), isAllDay: false),
            ],
            signedIn: true,
            scratchText: "Sample scratch note"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await fetchEntry(family: context.family)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        Task {
            let entry = await fetchEntry(family: context.family)
            // iOS budgets how often a widget can actually refresh — this just states
            // our preference (every 30 min), matching the "background-refresh" scope
            // this widget was built for; the system may space real refreshes out further.
            let nextRefresh = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func fetchEntry(family: WidgetFamily) async -> UpcomingEntry {
        guard let token = await WidgetAuth.loadValidAccessToken() else {
            return UpcomingEntry(date: Date(), events: [], signedIn: false, scratchText: nil)
        }
        // Piggyback the app icon badge's unread-count refresh onto this same timeline
        // wake-up — keeps it current even when the main app hasn't been opened. (The
        // widget's own UI no longer shows an unread count itself — see
        // scratchSideColumn — but the OS app-icon badge still does.)
        // The large size shows more events than medium/small (it's twice medium's
        // height), so fetch enough to fill it rather than the usual 4. Bumped up
        // from 8 now that per-day headers are gone from the layout — there's more
        // room for actual event rows than there used to be. Extra Large Portrait
        // (iOS 27+, roughly twice Large's height) gets a bigger budget still.
        let isLargeOrBigger: Bool = {
            if family == .systemLarge { return true }
            if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return true }
            return false
        }()
        let isExtraLargePortrait: Bool = {
            if #available(iOS 27.0, *) { return family == .systemExtraLargePortrait }
            return false
        }()
        let maxEvents = isExtraLargePortrait ? 20 : (isLargeOrBigger ? 12 : 4)
        async let events = WidgetCalendarFetcher.fetchUpcoming(accessToken: token, max: maxEvents)
        async let badgeRefresh: Void = WidgetBadgeUpdater.refresh(accessToken: token)
        let (resolvedEvents, _) = await (events, badgeRefresh)
        var scratchText: String?
        if family == .systemMedium || isLargeOrBigger {
            scratchText = await WidgetScratchFetcher.fetchFirstBox(accessToken: token)
        }
        return UpcomingEntry(
            date: Date(),
            events: resolvedEvents,
            signedIn: true,
            scratchText: scratchText
        )
    }
}

// Fixed dark-theme colors (the app's own dark-mode palette from Theme.swift) rather
// than Theme's light/dark-adaptive colors — the widget stays pure black regardless of
// system appearance, per an explicit ask, not just "black in dark mode."
private enum WidgetTheme {
    static let background = Color.black
    static let ink = Color(red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xEA / 255)
    static let inkSoft = Color(red: 0x8C / 255, green: 0x8C / 255, blue: 0x84 / 255)
}

struct CalendarWidgetEntryView: View {
    var entry: UpcomingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            // A plain black layer drawn as actual content, not just the required
            // .containerBackground call below — turns out some devices composite
            // containerBackground's color slightly differently (e.g. under Home Screen
            // tinting) than an ordinary view drawn as content, so this is what's
            // actually giving the true black. Sized to fill exactly (not oversized —
            // WidgetKit clips to the widget's own shape regardless of size, and a
            // deliberately oversized frame here was distorting the ZStack's own layout,
            // throwing off `content`'s topLeading-anchored children). Listed first, so
            // it stays behind everything else drawn in `content`.
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            content
        }
        .containerBackground(WidgetTheme.background, for: .widget)
    }

    // Same row spacing (eventRowSpacing) used everywhere an event tile can border
    // another one — inside the top full-width group, inside the bottom-left group,
    // and between the top group and the bottom row — so every gap between two
    // events reads as the same gap, with nothing that looks like a break.
    private let eventRowSpacing: CGFloat = 5

    // Top: however many upcoming events fit in a fixed budget (topEvents) — full
    // width, since this is the one part of the widget not sharing horizontal space
    // with anything else. Sized to its own content now (no forced height, no
    // trailing Spacer) instead of being pinned to a fixed fraction of the widget —
    // pinning it meant a light day with only 1-2 events left a dead, empty gap
    // before the bottom row started. Bottom splits into two columns: whatever
    // events didn't fit the top budget (narrower, left) and Notes (right) — both
    // run all the way to the bottom. Each region/column is its own Link (Links
    // can't nest) so tapping anywhere in the calendar portions opens Calendar and
    // tapping Notes opens Notes.
    @ViewBuilder
    private var content: some View {
        // GeometryReader ties the VStack's total height back to the widget's real,
        // fixed on-screen size — without it, the top region's now-natural (not
        // forced-1/3) sizing plus the bottom row's greedy maxHeight: .infinity have
        // no shared bound to divide up, so the assembled content can end up taller
        // than the widget and spill off both the top and bottom edges.
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: eventRowSpacing) {
                Link(destination: URL(string: "rystools://calendar")!) {
                    Group {
                        if !entry.signedIn {
                            Text("Open LessMTP to sign in.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(WidgetTheme.inkSoft)
                        } else if entry.events.isEmpty {
                            Text("Nothing on your calendar.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(WidgetTheme.inkSoft)
                        } else {
                            eventGroupsView(topEvents)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }

                HStack(alignment: .top, spacing: 14) {
                    Link(destination: URL(string: "rystools://calendar")!) {
                        eventGroupsView(bottomEvents)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .contentShape(Rectangle())
                    }
                    scratchSideColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: geo.size.height, alignment: .top)
            .clipped()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // The email unread-count badge that used to sit above this was removed entirely
    // (per an explicit ask to drop the email portion of the widget) — Notes now
    // takes the whole bottom-right quadrant, including the vertical space that badge
    // used to occupy (see scratchColumn's own maxHeight: .infinity).
    private var scratchSideColumn: some View {
        Link(destination: URL(string: "rystools://scratch")!) {
            scratchColumn
                .contentShape(Rectangle())
        }
    }

    private var scratchColumn: some View {
        // Same cream-box treatment as a Scratch box in the app and an event tile
        // elsewhere in this widget. Grows to fill the whole quadrant (maxHeight:
        // .infinity) instead of sizing to just its own text and leaving blank space
        // below it.
        Group {
            if let scratchText = entry.scratchText, !scratchText.isEmpty {
                Text(scratchText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(LightBoxTheme.ink)
                    .multilineTextAlignment(.leading)
            } else {
                Text("Nothing noted yet.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(LightBoxTheme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(LightBoxTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // Same design as the app's Upcoming box: no per-day title any more — each event
    // tile carries its own date (see timeOrDateLabel) instead. Shared by the top
    // (full width) and bottom-left (narrower) sections — each passes in its own
    // slice of sortedEvents.
    @ViewBuilder
    private func eventGroupsView(_ events: [WidgetEvent]) -> some View {
        VStack(alignment: .leading, spacing: eventRowSpacing) {
            ForEach(events) { event in
                eventRow(event)
            }
        }
    }

    // Extra Large Portrait (iOS 27+) is roughly twice Large's height, so it gets
    // roughly double the event budget below — everything else (Large, and any
    // older-OS fallback) keeps the existing counts.
    private var isExtraLargePortrait: Bool {
        if #available(iOS 27.0, *) {
            return family == .systemExtraLargePortrait
        }
        return false
    }

    // Bumped up from 6 now that per-day headers are gone — each row is shorter than
    // a header-plus-rows group used to be, so more of them fit in the same space.
    private var sortedEvents: [WidgetEvent] {
        let cap = isExtraLargePortrait ? 20 : 10
        return Array(entry.events.prefix(cap)).sorted { ($0.start ?? entry.date) < ($1.start ?? entry.date) }
    }

    // The top section is now only 1/3 of the height (was 2/3), so it only has room
    // for a couple of rows before it'd run into the bottom region — anything past
    // that budget moves to the narrower bottom-left column instead, which has the
    // other 2/3 of the height to work with.
    private var topEvents: [WidgetEvent] {
        let cap = isExtraLargePortrait ? 4 : 2
        return Array(sortedEvents.prefix(cap))
    }

    private var bottomEvents: [WidgetEvent] {
        let cap = isExtraLargePortrait ? 4 : 2
        return Array(sortedEvents.dropFirst(cap))
    }

    // Same cream-box look (and the same 48-hour fade) as an upcoming event card in the
    // app's Calendar tab, just sized down for widget space.
    private func eventRow(_ event: WidgetEvent) -> some View {
        let isSoon = isEventSoon(event)
        let textColor = isSoon ? LightBoxTheme.ink : LightBoxTheme.inkSoft

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(timeOrDateLabel(event))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(LightBoxTheme.gold)
            Text(event.title)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LightBoxTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isSoon ? 1 : 0.6)
    }

    private func isEventSoon(_ event: WidgetEvent) -> Bool {
        guard let start = event.start else { return true }
        return start <= entry.date.addingTimeInterval(48 * 3600)
    }

    // M/d H:mm — matches the app's own Upcoming list exactly (CalendarView's
    // timeLabel), now that there's no day header above to carry the date instead.
    private func timeOrDateLabel(_ event: WidgetEvent) -> String {
        guard let start = event.start else { return "" }
        let f = DateFormatter()
        f.dateFormat = event.isAllDay ? "M/d" : "M/d H:mm"
        return f.string(from: start)
    }
}

struct CalendarWidget: Widget {
    let kind = "CalendarWidget"

    // .systemExtraLargePortrait is iOS 27+ only (as wide as Large but roughly twice
    // as tall — a 4-by-6-ish icon grid instead of Large's 4-by-4, taking up a whole
    // Home Screen page on iPhone) — added alongside Large rather than replacing it,
    // so on iOS 27 the existing widget can be resized up to it in place (long-press
    // → Edit Widget) without needing to be removed and re-added, and older iOS
    // versions still just get Large.
    private var supportedFamilies: [WidgetFamily] {
        if #available(iOS 27.0, *) {
            return [.systemLarge, .systemExtraLargePortrait]
        }
        return [.systemLarge]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarProvider()) { entry in
            CalendarWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "rystools://calendar"))
        }
        .configurationDisplayName("Upcoming")
        .description("Shows your next events from LessMTP Calendar.")
        .supportedFamilies(supportedFamilies)
        // Without this, WidgetKit adds its own default content margins on top of the
        // padding already below — the two stacked is what was eating the left/right
        // space. Disabling it hands full edge-to-edge control to our own padding.
        .contentMarginsDisabled()
    }
}

@main
struct CalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalendarWidget()
    }
}
