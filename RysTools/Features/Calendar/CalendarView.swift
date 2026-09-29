import MapKit
import SwiftUI
import UIKit

// Matches cal.html closely: an "Upcoming" agenda box pinned above the scroll area (it
// lives in the web app's sticky header, so it never scrolls away either) showing the
// next 3 events or a tapped day's events, and a month grid below that scrolls — with
// more months loading in as you near the bottom, same as the web app's infinite
// downward scroll. Scrolling further back in time uses a "Load earlier months" tap
// instead of fully automatic upward infinite scroll — SwiftUI has no built-in way to
// prepend content without a visible scroll-position jump the way the web app's manual
// scrollTop adjustment does, so this trades a little automation for not janking the
// user's scroll position on every prepend.
@MainActor
final class CalendarViewModel: ObservableObject {
    @Published var listEvents: [CalendarEvent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var months: [Date] = [] // ascending month-start dates
    @Published var eventsByDay: [Date: [CalendarEvent]] = [:]
    @Published var selectedDay: Date?
    @Published var isLoadingMoreMonths = false

    private let calendar = Calendar.current
    private var loadedMonthKeys: Set<String> = []

    // The scrollable range: never further back than 2 weeks before today, never
    // further forward than 5 years from today.
    let minDate: Date = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -14, to: today) ?? today
    }()
    let maxDate: Date = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .year, value: 5, to: today) ?? today
    }()

    // Whether "Load earlier months" should still be offered — false once the earliest
    // loaded month is already the one minDate falls in (there's nothing further back
    // to show).
    var canLoadEarlierMonths: Bool {
        guard let first = months.first else { return true }
        let minMonth = calendar.dateInterval(of: .month, for: minDate)?.start ?? minDate
        return first > minMonth
    }

    func loadUpcoming(service: CalendarService) async {
        isLoading = true
        errorMessage = nil
        selectedDay = nil
        defer { isLoading = false }
        do {
            listEvents = try await service.listUpcoming()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDay(_ day: Date, service: CalendarService) async {
        let normalized = calendar.startOfDay(for: day)
        if let selectedDay, calendar.isDate(selectedDay, inSameDayAs: normalized) {
            await loadUpcoming(service: service)
            return
        }
        selectedDay = normalized
        errorMessage = nil
        listEvents = (eventsByDay[normalized] ?? []).sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    // Re-fetches every day from `from` through `through` (inclusive) after creating an
    // event — a multi-day all-day event needs every one of its days re-bucketed, not
    // just the day that was selected when "+ Create event" was tapped, or its dot
    // indicator and per-day event list would only ever show up on its start day.
    // Unlike selectDay(), this never toggles the current selection off.
    func refreshDayRange(from: Date, through: Date, service: CalendarService) async {
        let start = calendar.startOfDay(for: from)
        let throughDay = calendar.startOfDay(for: through)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: throughDay) else { return }
        do {
            let events = try await service.listEvents(from: start, to: rangeEnd)
            var day = start
            while day < rangeEnd {
                eventsByDay[day] = []
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            for event in events {
                for bucketDay in bucketDays(for: event) where bucketDay >= start && bucketDay < rangeEnd {
                    appendIfMissing(event, to: bucketDay)
                }
            }
            if let selectedDay {
                listEvents = (eventsByDay[selectedDay] ?? []).sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Every calendar day an event should show up on — a multi-day all-day event spans
    // every day from its start up to (but not including) its end, which the Calendar
    // API always represents as one exclusive end date rather than one entry per day.
    private func bucketDays(for event: CalendarEvent) -> [Date] {
        guard let start = event.start else { return [] }
        let startDay = calendar.startOfDay(for: start)
        guard event.isAllDay, let end = event.end else { return [startDay] }
        let endDay = calendar.startOfDay(for: end)
        var days: [Date] = []
        var current = startDay
        while current < endDay {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days.isEmpty ? [startDay] : days
    }

    // A multi-day event can come back from more than one overlapping fetch (adjacent
    // months, or a day-range refresh that overlaps an already-loaded month) — avoid
    // bucketing the same event onto the same day twice.
    private func appendIfMissing(_ event: CalendarEvent, to day: Date) {
        var bucket = eventsByDay[day] ?? []
        guard !bucket.contains(where: { $0.id == event.id }) else { return }
        bucket.append(event)
        eventsByDay[day] = bucket
    }

    // After a delete, strip the event out of every day it was bucketed under (a
    // multi-day event could be in several) and out of whichever list is on screen,
    // without needing a network round-trip just to reflect the removal.
    func removeEventLocally(_ event: CalendarEvent) {
        for key in eventsByDay.keys {
            eventsByDay[key]?.removeAll { $0.id == event.id }
        }
        listEvents.removeAll { $0.id == event.id }
    }

    func initMonthsIfNeeded(service: CalendarService) async {
        guard months.isEmpty else { return }
        let current = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let next = calendar.date(byAdding: .month, value: 1, to: current) ?? current
        let minMonth = calendar.dateInterval(of: .month, for: minDate)?.start ?? minDate
        // Only seed a prev month if it actually has any days on or after minDate —
        // otherwise (the common case, when today isn't within the first 2 weeks of
        // its month) it would render as an empty month block with no day cells.
        var seed = [current, next]
        if let prev = calendar.date(byAdding: .month, value: -1, to: current), prev >= minMonth {
            seed.insert(prev, at: 0)
        }
        months = seed
        for month in months {
            await loadMonth(month, service: service)
        }
    }

    func appendNextMonth(service: CalendarService) async {
        guard !isLoadingMoreMonths, let last = months.last,
              let next = calendar.date(byAdding: .month, value: 1, to: last) else { return }
        let maxMonth = calendar.dateInterval(of: .month, for: maxDate)?.start ?? maxDate
        guard next <= maxMonth else { return } // already at (or would pass) the 5-year ceiling
        isLoadingMoreMonths = true
        defer { isLoadingMoreMonths = false }
        months.append(next)
        await loadMonth(next, service: service)
    }

    func prependPreviousMonth(service: CalendarService) async {
        guard !isLoadingMoreMonths, let first = months.first,
              let prev = calendar.date(byAdding: .month, value: -1, to: first) else { return }
        let minMonth = calendar.dateInterval(of: .month, for: minDate)?.start ?? minDate
        guard prev >= minMonth else { return } // already at (or would pass) the 2-week floor
        isLoadingMoreMonths = true
        defer { isLoadingMoreMonths = false }
        months.insert(prev, at: 0)
        await loadMonth(prev, service: service)
    }

    private func loadMonth(_ month: Date, service: CalendarService) async {
        let key = monthKey(month)
        guard !loadedMonthKeys.contains(key) else { return }
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        do {
            let events = try await service.listEvents(from: interval.start, to: interval.end)
            for event in events {
                for day in bucketDays(for: event) {
                    appendIfMissing(event, to: day)
                }
            }
            loadedMonthKeys.insert(key)
        } catch {
            // A month-grid failure shouldn't clobber whatever the Upcoming list is showing.
        }
    }

    func monthKey(_ month: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: month)
    }
}

// listEvents flattens every upcoming event regardless of which day it falls on — this
// buckets them back into one group per day so each day can get its own header instead
// of one title for the whole box (which used to just say "Upcoming").
private struct DayEventGroup: Identifiable {
    let day: Date
    let events: [CalendarEvent]
    var id: Date { day }
}

struct CalendarView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appSettings: AppSettings
    // Set by RootView's header "+" button (now in line with the nav dropdown,
    // instead of a button living in this screen's own content) — flipped back to
    // false immediately after triggering, so it can fire again next tap.
    @Binding var triggerCreateEvent: Bool
    // Owned by RootView's header search field (same pattern as EmailView's own
    // searchText) — matched against every event title already loaded for the month
    // grid; see searchResultEvents.
    @Binding var searchText: String
    @StateObject private var viewModel = CalendarViewModel()
    @State private var expandedEventID: String?
    @State private var showingCompose = false
    @State private var editingEvent: CalendarEvent?
    @State private var pendingDeleteEvent: CalendarEvent?
    @State private var saveErrorMessage: String?

    private var service: CalendarService { CalendarService(auth: auth) }
    private let calendar = Calendar.current

    var body: some View {
        // geo's own frame in .global screen coordinates tells us how far down the
        // physical screen this view already starts (status bar, RootView's header
        // bar, and the nav dropdown row above it all included) — so the Upcoming
        // box's height can be set to land its bottom edge, and so the month grid's
        // ScrollView below it, at exactly the midpoint of the WHOLE screen, not just
        // the midpoint of whatever space is left within this view.
        GeometryReader { geo in
            let topInset = geo.frame(in: .global).minY
            let upcomingHeight = max(0, UIScreen.main.bounds.height / 2 - topInset)

            VStack(spacing: 0) {
                // Pinned — like the web app's #cal-upcoming living in the sticky header,
                // this never scrolls away, only the month grid below it does. Top padding
                // is deliberately tighter than the sides/bottom, so the box sits close up
                // under the header's tool switcher instead of floating in the middle of a
                // big gap.
                upcomingSection
                    .padding(.horizontal, 16)
                    // Tuned down from 6 (then 2, then 0) so the "+" button here lines up
                    // with the exact same button in Email's header row — switching tools
                    // shouldn't make it visibly shift.
                    .padding(.top, 1)
                    .padding(.bottom, 16)
                    .background(Theme.paper)
                    .frame(height: upcomingHeight, alignment: .top)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if viewModel.canLoadEarlierMonths {
                            Button {
                                Task { await viewModel.prependPreviousMonth(service: service) }
                            } label: {
                                Text(viewModel.isLoadingMoreMonths ? "Loading…" : "Load earlier months")
                                    .font(Theme.Font.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            .disabled(viewModel.isLoadingMoreMonths)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }

                        ForEach(viewModel.months, id: \.self) { month in
                            monthBlock(month)
                                .onAppear {
                                    if month == viewModel.months.last {
                                        Task { await viewModel.appendNextMonth(service: service) }
                                    }
                                }
                        }

                        if viewModel.isLoadingMoreMonths {
                            ProgressView().frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await reloadAll() }
            }
            .background(Theme.paper)
        }
        .task { await reloadAll() }
        .onChange(of: auth.isSignedIn) { Task { await reloadAll() } }
        .onChange(of: triggerCreateEvent) { _, newValue in
            guard newValue else { return }
            showingCompose = true
            triggerCreateEvent = false
        }
        .sheet(isPresented: $showingCompose) {
            // The Create button is always visible now, not just once a day is
            // selected, so this needs its own fallback (today) instead of only ever
            // rendering when viewModel.selectedDay was already set.
            let day = viewModel.selectedDay ?? calendar.startOfDay(for: Date())
            ComposeEventView(day: day) { id, title, location, start, end, endDay, recurrence in
                Task { await saveEvent(id: id, title: title, location: location, start: start, end: end, day: day, endDay: endDay, recurrence: recurrence) }
            }
        }
        .sheet(item: $editingEvent) { event in
            let day = calendar.startOfDay(for: event.start ?? Date())
            ComposeEventView(day: day, existingEvent: event) { id, title, location, start, end, endDay, recurrence in
                Task { await saveEvent(id: id, title: title, location: location, start: start, end: end, day: day, endDay: endDay, recurrence: recurrence) }
            }
        }
        .alert("Delete this event?", isPresented: Binding(
            get: { pendingDeleteEvent != nil },
            set: { if !$0 { pendingDeleteEvent = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let event = pendingDeleteEvent {
                    Task { await deleteEvent(event) }
                }
                pendingDeleteEvent = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteEvent = nil }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Couldn't save event", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private func reloadAll() async {
        guard auth.isSignedIn else { return }
        await viewModel.loadUpcoming(service: service)
        await viewModel.initMonthsIfNeeded(service: service)
    }

    private func saveEvent(id: String?, title: String, location: String, start: Date?, end: Date?, day: Date, endDay: Date, recurrence: [String]?) async {
        do {
            if let id {
                try await service.updateEvent(id: id, title: title, location: location, start: start, end: end, day: day, endDay: endDay, recurrence: recurrence)
            } else {
                try await service.createEvent(title: title, location: location, start: start, end: end, day: day, endDay: endDay)
            }
            // For an all-day event, endDay may be later than day (a multi-day span) —
            // refresh every day in between so the month grid and each day's own list
            // both pick the event up correctly, not just the day that was selected.
            let through = (start == nil) ? endDay : day
            await viewModel.refreshDayRange(from: day, through: through, service: service)
        } catch {
            // Surfaced as an unmissable alert, not just the passive Upcoming-section
            // error text — a failed save with only a quiet inline error is exactly
            // what looked like "the event just didn't show up" before.
            saveErrorMessage = error.localizedDescription
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func deleteEvent(_ event: CalendarEvent) async {
        do {
            try await service.deleteEvent(id: event.id)
            if expandedEventID == event.id { expandedEventID = nil }
            viewModel.removeEventLocally(event)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func loadSeriesForEdit(_ recurringEventId: String) async {
        do {
            editingEvent = try await service.fetchEvent(id: recurringEventId)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Searches every event already loaded for the month grid (viewModel.eventsByDay
    // — built up as you scroll through months), not just the handful in the Upcoming
    // list — a much broader set to match against, and free, since it's already
    // fetched. This won't find events from months you haven't scrolled to yet, but
    // reaching further than that would mean a dedicated server-side search call,
    // which is a bigger feature than what was asked for here.
    private var searchResultEvents: [CalendarEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var seenIDs = Set<String>()
        var results: [CalendarEvent] = []
        for events in viewModel.eventsByDay.values {
            for event in events where event.title.lowercased().contains(query) {
                guard seenIDs.insert(event.id).inserted else { continue }
                results.append(event)
            }
        }
        return results
    }

    // One date per day actually showing in the box, instead of one "Upcoming" title for
    // everything — the "Upcoming" view can span several different days, so this buckets
    // the current source (listEvents normally, or every matching event while
    // searching) back into one group per day, in day order.
    private var groupedEvents: [DayEventGroup] {
        let source = isSearching ? searchResultEvents : viewModel.listEvents
        let groups = Dictionary(grouping: source) { calendar.startOfDay(for: $0.start ?? Date()) }
        return groups.keys.sorted().map { day in
            DayEventGroup(day: day, events: groups[day]!.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) })
        }
    }


    @ViewBuilder
    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The box's own height is fixed by the caller (exactly half the screen —
            // see body's GeometryReader), so this just fills whatever space that gives
            // it and shows as many events as fit — no more measuring row heights to
            // size the box to its content.
            Group {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).foregroundStyle(Theme.inkSoft)
                        Button("Retry") { Task { await viewModel.loadUpcoming(service: service) } }
                            .font(Theme.Font.footnote.weight(.semibold))
                            .foregroundStyle(Theme.gold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if groupedEvents.isEmpty {
                    Text(
                        isSearching ? "No matching events."
                            : viewModel.selectedDay == nil ? "Nothing on your calendar." : "No events."
                    )
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    List {
                        ForEach(groupedEvents) { group in
                            ForEach(group.events) { event in
                                eventCard(event)
                                    // Reports this row's frame to BackgroundSwipeDetector, so a
                                    // swipe here deletes instead of switching tools.
                                    .swipeableCard()
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            pendingDeleteEvent = event
                                        } label: {
                                            Text("Delete")
                                                .font(Theme.Font.subheadline.weight(.bold))
                                                .foregroundStyle(Theme.expense)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .stroke(Theme.expense, lineWidth: 1.5)
                                                )
                                        }
                                        .tint(Theme.paper)
                                    }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                    .listRowSpacing(0)
                    // Scrolling stays off in the normal browsing state — the box just
                    // shows as many events as fit its fixed half-screen height with no
                    // scroll indicator. Turned back on only while an event's expanded
                    // detail or a search's full match list might not fit, so nothing
                    // becomes unreachable now that the box can no longer grow taller.
                    .scrollDisabled(expandedEventID == nil && !isSearching)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func monthBlock(_ month: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Same font/style as an Upcoming day header (caption, semibold, inkSoft,
            // uppercase) instead of its own headline treatment, per an explicit ask to
            // keep every date label in Calendar looking the same.
            Text(monthTitle(month))
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .center)

            if month == viewModel.months.first {
                weekdayHeader
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<leadingBlanksCount(month), id: \.self) { _ in
                    Color.clear.frame(height: 42)
                }
                ForEach(daysInMonth(month), id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                Text(d)
                    .font(Theme.Font.caption2.weight(.semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let normalized = calendar.startOfDay(for: day)
        let isSelected = viewModel.selectedDay.map { calendar.isDate($0, inSameDayAs: normalized) } ?? false
        let isToday = calendar.isDateInToday(day)
        let hasEvents = !(viewModel.eventsByDay[normalized] ?? []).isEmpty
        let dayNumber = calendar.component(.day, from: day)

        // Today is a solid, colored-in square; a selected (but not today) day is just
        // a bordered square — the two are independent, so today-and-selected shows both.
        return Button {
            Task { await viewModel.selectDay(day, service: service) }
        } label: {
            VStack(spacing: 3) {
                Text("\(dayNumber)")
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LightBoxTheme.ink)
                Circle()
                    .fill(hasEvents ? (isToday ? LightBoxTheme.ink : LightBoxTheme.gold) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isToday ? Theme.gold : LightBoxTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? LightBoxTheme.gold : LightBoxTheme.paperLine, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func monthTitle(_ month: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    // Clipped to [viewModel.minDate, viewModel.maxDate] — the boundary month (the one
    // 2 weeks back, or 5 years forward) only shows the days actually inside that
    // range; leadingBlanksCount derives its indent from whichever day ends up first
    // here, so a floor month that starts mid-week still lines up under the right
    // weekday column with no extra work.
    private func daysInMonth(_ month: Date) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        var days: [Date] = []
        var current = interval.start
        while current < interval.end {
            if current >= viewModel.minDate && current <= viewModel.maxDate {
                days.append(current)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private func leadingBlanksCount(_ month: Date) -> Int {
        guard let firstDay = daysInMonth(month).first else { return 0 }
        return calendar.component(.weekday, from: firstDay) - 1 // weekday: 1 = Sunday
    }

    // Same inline accordion pattern as EmailView's rows: tap expands the card in place
    // (instead of pushing a screen or presenting a sheet), tap again — or tap a
    // different event — to collapse it. Delete is a native .swipeActions button (see
    // upcomingSection), not a hand-built gesture — simpler, and guaranteed not to fight
    // the List's own scrolling.
    // The 48-hour fade for events further out stays in the widget (space is tight
    // there, so it's a useful glance cue) but not here — every event in the app reads
    // at the same full strength now, for readability.
    private func eventCard(_ event: CalendarEvent) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleExpanded(event)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(timeLabel(event))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.cyan)
                        Text(event.title)
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(LightBoxTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expandedEventID == event.id {
                    // For a recurring instance, "Edit" edits the whole series (the
                    // master event, fetched by its recurringEventId) — "Edit
                    // Occurrence" edits just this one date, using the instance
                    // already in hand. For a non-recurring event there's no series,
                    // so "Edit" just edits it directly, same as always.
                    Button {
                        if let recurringEventId = event.recurringEventId {
                            Task { await loadSeriesForEdit(recurringEventId) }
                        } else {
                            editingEvent = event
                        }
                    } label: {
                        Text("Edit")
                            .font(Theme.Font.footnote.weight(.bold))
                            .foregroundStyle(LightBoxTheme.gold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(Capsule().stroke(LightBoxTheme.gold, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)

                    if event.recurringEventId != nil {
                        Button {
                            editingEvent = event
                        } label: {
                            Text("Edit Occurrence")
                                .font(Theme.Font.footnote.weight(.bold))
                                .foregroundStyle(LightBoxTheme.gold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(Capsule().stroke(LightBoxTheme.gold, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if expandedEventID == event.id {
                eventDetailContent(event)
            }
        }
        .padding(12)
        .background(LightBoxTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 5)
    }

    private func toggleExpanded(_ event: CalendarEvent) {
        expandedEventID = (expandedEventID == event.id) ? nil : event.id
    }

    @ViewBuilder
    private func eventDetailContent(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let location = event.location, !location.isEmpty, let url = mapsURL(for: location) {
                Link(destination: url) {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(LightBoxTheme.gold)
                        .underline()
                }
            } else if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(LightBoxTheme.inkSoft)
            }

            if let description = event.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.subheadline)
                    .foregroundStyle(LightBoxTheme.ink)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 10)
    }

    // maps.apple.com links are what iOS itself redirects to the user's chosen default
    // maps app for (Settings > Apps > Default Apps, iOS 17.4+) — a plain maps:// URL
    // would only ever open Apple Maps regardless of that setting.
    private func mapsURL(for location: String) -> URL? {
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://maps.apple.com/?q=\(encoded)")
    }

    private func timeLabel(_ event: CalendarEvent) -> String {
        guard let start = event.start else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = event.isAllDay ? "M/d" : "M/d H:mm"
        return formatter.string(from: start)
    }
}

// A simplified view of an RRULE line — just frequency, interval, and how it ends
// (never / on a date / after N occurrences). No BYDAY/BYMONTHDAY/etc. editing — a
// rule using those still parses (frequency/interval/end survive), but saving rewrites
// it into this simpler shape, which is the deliberate tradeoff for a compact editor
// rather than a full RRULE builder.
private struct RecurrenceRule {
    enum Frequency: String, CaseIterable, Identifiable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    enum End {
        case never
        case onDate(Date)
        case afterCount(Int)
    }

    var frequency: Frequency = .weekly
    var interval: Int = 1
    var end: End = .never

    static func parse(_ rules: [String]) -> RecurrenceRule? {
        guard let rruleLine = rules.first(where: { $0.hasPrefix("RRULE:") }) else { return nil }
        var parts: [String: String] = [:]
        for pair in rruleLine.dropFirst("RRULE:".count).split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[String(kv[0])] = String(kv[1]) }
        }
        guard let freqStr = parts["FREQ"], let freq = Frequency(rawValue: freqStr) else { return nil }

        var rule = RecurrenceRule()
        rule.frequency = freq
        rule.interval = Int(parts["INTERVAL"] ?? "1") ?? 1

        if let until = parts["UNTIL"] {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = until.count > 8 ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd"
            if let date = formatter.date(from: until) {
                rule.end = .onDate(date)
            }
        } else if let countStr = parts["COUNT"], let count = Int(countStr) {
            rule.end = .afterCount(count)
        }
        return rule
    }

    func toRRuleString() -> String {
        var s = "RRULE:FREQ=\(frequency.rawValue)"
        if interval > 1 { s += ";INTERVAL=\(interval)" }
        switch end {
        case .never:
            break
        case .onDate(let date):
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            s += ";UNTIL=\(formatter.string(from: date))"
        case .afterCount(let count):
            s += ";COUNT=\(count)"
        }
        return s
    }
}

// Matches cal.html's trimmed create-event form (Title, Start time blank/off = all-day,
// Location), plus an explicit End: an "End day" picker for a (possibly multi-day)
// all-day event, or an "End time" next to Start time for a timed one — defaulting to
// one hour after whatever Start time is set to, both in 15-minute increments.
private struct ComposeEventView: View {
    let day: Date
    let eventId: String?
    // id is nil for a new event, or the event being edited — the caller routes that to
    // a create vs. update call. start/end are both nil together (all-day: use
    // day/endDay instead) or both set. recurrence is nil unless this is a series edit.
    var onSave: (_ id: String?, _ title: String, _ location: String, _ start: Date?, _ end: Date?, _ endDay: Date, _ recurrence: [String]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var location: String
    @State private var isAllDay: Bool
    @State private var time: Date
    @State private var endTime: Date
    @State private var endDay: Date
    @StateObject private var locationCompleter = LocationAutocompleter()

    // Only populated (and only shown) when editing a series' own master event — an
    // individual occurrence has no recurrence rule of its own to edit.
    @State private var showsRecurrenceEditor: Bool
    @State private var recurrenceRule: RecurrenceRule
    @State private var recurrenceEndMode: Int // 0 = never, 1 = on date, 2 = after N
    @State private var recurrenceEndDate: Date
    @State private var recurrenceEndCount: Int

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(
        day: Date,
        existingEvent: CalendarEvent? = nil,
        onSave: @escaping (_ id: String?, _ title: String, _ location: String, _ start: Date?, _ end: Date?, _ endDay: Date, _ recurrence: [String]?) -> Void
    ) {
        self.day = day
        self.eventId = existingEvent?.id
        self.onSave = onSave
        _title = State(initialValue: existingEvent?.title ?? "")
        _location = State(initialValue: existingEvent?.location ?? "")
        _isAllDay = State(initialValue: existingEvent?.isAllDay ?? true)

        if let existingEvent, existingEvent.isAllDay, let end = existingEvent.end {
            // end is the API's exclusive end date — the actual last included day is
            // end minus one, which is what the "End day" picker should show.
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
            _endDay = State(initialValue: lastDay)
        } else {
            _endDay = State(initialValue: day)
        }

        if let existingEvent, !existingEvent.isAllDay, let start = existingEvent.start {
            _time = State(initialValue: start)
            _endTime = State(initialValue: existingEvent.end ?? start.addingTimeInterval(3600))
        } else {
            let now = Date()
            _time = State(initialValue: now)
            _endTime = State(initialValue: now.addingTimeInterval(3600))
        }

        if let rules = existingEvent?.recurrenceRules, let parsed = RecurrenceRule.parse(rules) {
            _showsRecurrenceEditor = State(initialValue: true)
            _recurrenceRule = State(initialValue: parsed)
            switch parsed.end {
            case .never:
                _recurrenceEndMode = State(initialValue: 0)
                _recurrenceEndDate = State(initialValue: Date())
                _recurrenceEndCount = State(initialValue: 10)
            case .onDate(let date):
                _recurrenceEndMode = State(initialValue: 1)
                _recurrenceEndDate = State(initialValue: date)
                _recurrenceEndCount = State(initialValue: 10)
            case .afterCount(let count):
                _recurrenceEndMode = State(initialValue: 2)
                _recurrenceEndDate = State(initialValue: Date())
                _recurrenceEndCount = State(initialValue: count)
            }
        } else {
            _showsRecurrenceEditor = State(initialValue: false)
            _recurrenceRule = State(initialValue: RecurrenceRule())
            _recurrenceEndMode = State(initialValue: 0)
            _recurrenceEndDate = State(initialValue: Date())
            _recurrenceEndCount = State(initialValue: 10)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(label: "Title") {
                        TextField("Event title", text: $title)
                    }

                    Toggle("All day", isOn: $isAllDay.animation())
                        .tint(Theme.gold)
                        .font(Theme.Font.subheadline)
                        .foregroundStyle(Theme.ink)

                    if isAllDay {
                        field(label: "End day") {
                            DatePicker("", selection: $endDay, in: day..., displayedComponents: .date)
                                .labelsHidden()
                        }
                    } else {
                        HStack(spacing: 12) {
                            field(label: "Start time") {
                                FifteenMinuteTimePicker(date: $time)
                            }
                            field(label: "End time") {
                                FifteenMinuteTimePicker(date: $endTime)
                            }
                        }
                        .onChange(of: time) { _, newValue in
                            endTime = newValue.addingTimeInterval(3600)
                        }
                    }

                    field(label: "Location") {
                        TextField("Optional", text: $location)
                            .onChange(of: location) { _, newValue in
                                locationCompleter.update(query: newValue)
                            }
                    }

                    if !locationCompleter.results.isEmpty {
                        locationSuggestions
                    }

                    if showsRecurrenceEditor {
                        Divider().background(Theme.paperLine)

                        field(label: "Repeats") {
                            Picker("", selection: $recurrenceRule.frequency) {
                                ForEach(RecurrenceRule.Frequency.allCases) { freq in
                                    Text(freq.label).tag(freq)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("ENDS")
                                .font(Theme.Font.caption.weight(.semibold))
                                .foregroundStyle(Theme.inkSoft)
                            Picker("Ends", selection: $recurrenceEndMode) {
                                Text("Never").tag(0)
                                Text("On date").tag(1)
                                Text("After").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }

                        if recurrenceEndMode == 1 {
                            field(label: "End date") {
                                DatePicker("", selection: $recurrenceEndDate, in: day..., displayedComponents: .date)
                                    .labelsHidden()
                            }
                        } else if recurrenceEndMode == 2 {
                            field(label: "Occurrences") {
                                Stepper("\(recurrenceEndCount) times", value: $recurrenceEndCount, in: 1...365)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle(eventId != nil ? "Edit event" : dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
                        let recurrence: [String]? = showsRecurrenceEditor ? [finalRecurrenceRule().toRRuleString()] : nil
                        if isAllDay {
                            onSave(eventId, trimmedTitle, trimmedLocation, nil, nil, endDay, recurrence)
                        } else {
                            onSave(eventId, trimmedTitle, trimmedLocation, combined(time), combined(endTime), day, recurrence)
                        }
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private var locationSuggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(locationCompleter.results.prefix(5).enumerated()), id: \.offset) { _, result in
                Button {
                    location = LocationAutocompleter.fullAddress(for: result)
                    locationCompleter.clear()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.paperLine, lineWidth: 1)
        )
    }

    private func finalRecurrenceRule() -> RecurrenceRule {
        var rule = recurrenceRule
        switch recurrenceEndMode {
        case 1: rule.end = .onDate(recurrenceEndDate)
        case 2: rule.end = .afterCount(recurrenceEndCount)
        default: rule.end = .never
        }
        return rule
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: day)
    }

    // Combines the selected day with just the hour/minute picked in a time field.
    private func combined(_ timeOfDay: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: timeOfDay)
        return cal.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: day) ?? day
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            content()
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.paperLine, lineWidth: 1)
                )
        }
    }
}

// SwiftUI's own DatePicker has no minute-interval control, so this wraps UIDatePicker
// (which does, via .minuteInterval) to get 15-minute-increment time selection while
// keeping the same compact, tap-to-open-a-wheel appearance SwiftUI's own DatePicker uses.
// A plain SwiftUI menu Picker over a fixed list of 15-minute slots, instead of a
// UIViewRepresentable-wrapped UIDatePicker — the wrapped version (its only reason for
// existing was minuteInterval, which plain SwiftUI's DatePicker doesn't expose) turned
// out to be unreliably tappable once embedded in this sheet's ScrollView, apparently
// swallowing touches for the rest of the form along with it. This is fully
// SwiftUI-native, so it doesn't carry that risk.
private struct FifteenMinuteTimePicker: View {
    @Binding var date: Date

    private static let slots: [Date] = {
        var result: [Date] = []
        let calendar = Calendar.current
        for hour in 0..<24 {
            for minute in stride(from: 0, to: 60, by: 15) {
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                if let d = calendar.date(from: comps) { result.append(d) }
            }
        }
        return result
    }()

    private var selection: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let minute = calendar.component(.minute, from: date)
                let roundedMinute = (minute / 15) * 15
                let hour = calendar.component(.hour, from: date)
                return Self.slots.first {
                    calendar.component(.hour, from: $0) == hour && calendar.component(.minute, from: $0) == roundedMinute
                } ?? Self.slots[0]
            },
            set: { newValue in
                let calendar = Calendar.current
                let comps = calendar.dateComponents([.hour, .minute], from: newValue)
                date = calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: date) ?? date
            }
        )
    }

    var body: some View {
        Picker("", selection: selection) {
            ForEach(Self.slots, id: \.self) { slot in
                Text(Self.label(for: slot)).tag(slot)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private static func label(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
