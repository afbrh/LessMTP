import MapKit

// Live address/place suggestions as the user types into the event Location field —
// MapKit's own autocomplete (MKLocalSearchCompleter), so no separate API key or
// account setup is needed. Selecting a suggestion fills in its full formatted
// address, which the calendar's own event-detail view already renders as a tappable
// maps.apple.com link (see CalendarView.mapsURL) — this only needed to add the
// suggestion UI, not the tap-to-open behavior, which already existed.
@MainActor
final class LocationAutocompleter: NSObject, ObservableObject {
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func clear() {
        results = []
    }

    static func fullAddress(for completion: MKLocalSearchCompletion) -> String {
        completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)"
    }
}

extension LocationAutocompleter: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let completions = completer.results
        Task { @MainActor in self.results = completions }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
