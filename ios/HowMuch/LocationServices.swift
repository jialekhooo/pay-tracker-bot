import SwiftUI
import MapKit
import HowMuchCore

@MainActor
final class JobPlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var places: [MKMapItem] = []
    @Published var searching = false
    @Published var error: String?
    private let completer = MKLocalSearchCompleter()
    private var request: MKLocalSearch?
    private var generation = UUID()
    private var fragment = ""
    // Bias suggestions toward the app's initial Singapore audience without restricting results.
    private let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198), span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.7))

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = region
    }
    func update(_ query: String) {
        generation = UUID(); request?.cancel(); searching = false
        fragment = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestions = []; error = nil
        completer.queryFragment = fragment
        if fragment.isEmpty { completer.cancel() }
    }
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor [weak self] in
            guard let self, !self.fragment.isEmpty else { return }
            self.suggestions = completer.results
            self.error = nil
        }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.fragment.isEmpty else { return }
            self.suggestions = []
            self.error = "Place suggestions are unavailable. Try again or keep your typed location."
        }
    }
    func find(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        request?.cancel()
        let token = UUID(); generation = token
        places = []; error = nil
        guard !query.isEmpty else { searching = false; return }
        searching = true
        let options = MKLocalSearch.Request()
        options.naturalLanguageQuery = query
        options.resultTypes = [.address, .pointOfInterest]
        options.region = region
        let search = MKLocalSearch(request: options); request = search
        do {
            let response = try await search.start()
            guard generation == token, !Task.isCancelled else { return }
            places = response.mapItems
            if places.isEmpty { error = "No matching places found. Try a street address, building name or postal code." }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = "Couldn't load this location. Check your connection and try a more complete address."
        }
        if generation == token { searching = false }
    }
    func stop() {
        generation = UUID(); request?.cancel(); completer.cancel(); searching = false
    }
    static func address(_ item: MKMapItem) -> String {
        item.placemark.title ?? item.name ?? "Selected place"
    }
    static func savedLocation(_ title: String, _ subtitle: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, subtitle.range(of: title, options: [.anchored, .caseInsensitive]) != nil { return subtitle }
        return [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct JobLocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = JobPlaceSearch()
    @State private var query: String
    @FocusState private var focused: Bool
    let purpose: String
    let onSelect: (String) -> Void
    init(initial: String, purpose: String = "FIND YOUR WORKPLACE", onSelect: @escaping (String) -> Void) {
        _query = State(initialValue: initial)
        self.purpose = purpose
        self.onSelect = onSelect
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Label(purpose, systemImage: "mappin.and.ellipse").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        TextField("Place, address or postal code", text: $query).font(.appBody).frame(minHeight: 48)
                            .autocorrectionDisabled().focused($focused).submitLabel(.search).accessibilityIdentifier("location.query")
                            .onSubmit { focused = false; Task { await search.find(query) } }
                        Text("Place searches are sent to Apple Maps. You can also keep a location you type yourself.").font(.caption).foregroundStyle(Palette.muted)
                    }
                    if search.searching { ProgressView("Finding places…").frame(maxWidth: .infinity) }
                    if let error = search.error { Label(error, systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(Palette.muted) }
                    if !search.places.isEmpty {
                        Text("Matching places").font(.appHeadline)
                        ForEach(Array(search.places.enumerated()), id: \.offset) { index, item in
                            Button { choose(JobPlaceSearch.savedLocation(item.name ?? "", JobPlaceSearch.address(item))) } label: {
                                Card { placeLabel(item.name ?? "Place", JobPlaceSearch.address(item)) }
                            }.buttonStyle(.plain).accessibilityIdentifier("location.result.\(index)")
                        }
                    } else {
                        ForEach(Array(search.suggestions.prefix(8).enumerated()), id: \.offset) { index, item in
                            Button { choose(JobPlaceSearch.savedLocation(item.title, item.subtitle)) } label: {
                                Card { placeLabel(item.title, item.subtitle) }
                            }.buttonStyle(.plain).accessibilityIdentifier("location.suggestion.\(index)")
                        }
                    }
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Search Apple Maps", systemImage: "magnifyingglass") { focused = false; Task { await search.find(query) } }.glassAction().accessibilityIdentifier("location.search")
                        Button("Use typed location", systemImage: "checkmark") { choose(query.trimmingCharacters(in: .whitespacesAndNewlines)) }.glassAction().accessibilityIdentifier("location.useTyped")
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).detailStyle("Find a place")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onChange(of: query) { _, value in search.places = []; search.update(value) }
                .onAppear { search.update(query); focused = true }
                .onDisappear { search.stop() }
        }
    }
    private func choose(_ value: String) { onSelect(value); dismiss() }
    private func placeLabel(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(Palette.teal)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.chevron).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
}

struct JobDirectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = JobPlaceSearch()
    let location: String
    @State private var selected: MKMapItem?
    @State private var launchError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        Label("JOB LOCATION", systemImage: "mappin.and.ellipse").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
                        Text(location).font(.appHeadline)
                        Text("Confirm the destination before starting directions.").font(.caption).foregroundStyle(Palette.muted)
                    }
                    if search.searching { ProgressView("Looking up your workplace…").frame(maxWidth: .infinity) }
                    if let item = selected {
                        Map(initialPosition: .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))) {
                            Marker(item: item)
                        }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("location.map")
                        Card {
                            Text(item.name ?? "Destination").font(.appHeadline)
                            Text(JobPlaceSearch.address(item)).font(.subheadline).foregroundStyle(Palette.muted)
                            Text("Apple Maps will show routes from your current location and handle any location permission.").font(.caption).foregroundStyle(Palette.muted)
                        }
                        VStack(spacing: 10) {
                            Button("Public transport", systemImage: "tram.fill") { open(item, mode: MKLaunchOptionsDirectionsModeTransit) }.glassAction().accessibilityIdentifier("location.transit")
                            Button("Driving", systemImage: "car.fill") { open(item, mode: MKLaunchOptionsDirectionsModeDriving) }.glassAction().accessibilityIdentifier("location.driving")
                            Button("Cycling", systemImage: "bicycle") { open(item, mode: MKLaunchOptionsDirectionsModeCycling) }.glassAction().accessibilityIdentifier("location.cycling")
                            Button("Walking", systemImage: "figure.walk") { open(item, mode: MKLaunchOptionsDirectionsModeWalking) }.glassAction().accessibilityIdentifier("location.walking")
                        }
                        if search.places.count > 1 { Button("Choose a different match") { selected = nil }.glassAction() }
                    } else {
                        ForEach(Array(search.places.enumerated()), id: \.offset) { index, item in
                            Button { selected = item } label: {
                                Card {
                                    Text(item.name ?? "Place").font(.appHeadline).foregroundStyle(Palette.ink)
                                    Text(JobPlaceSearch.address(item)).font(.caption).foregroundStyle(Palette.muted)
                                    Label("Show this destination", systemImage: "map").font(.subheadline).foregroundStyle(Palette.teal)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("location.destination.\(index)")
                        }
                    }
                    if let error = search.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Palette.muted)
                        Button("Try again", systemImage: "arrow.clockwise") { Task { await lookup() } }.glassAction()
                    }
                    if let launchError { Text(launchError).font(.subheadline).foregroundStyle(.red) }
                    Text("Maps and route availability depend on Apple Maps coverage and your connection.").font(.caption).foregroundStyle(Palette.muted)
                }.padding(20)
            }.detailStyle("Map & directions")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .task { await lookup() }
                .onDisappear { search.stop() }
        }
    }
    private func lookup() async {
        selected = nil
        await search.find(location)
        if search.places.count == 1 { selected = search.places.first }
    }
    private func open(_ item: MKMapItem, mode: String) {
        launchError = nil
        if !item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode]) {
            launchError = "Apple Maps couldn't open. Install or enable Apple Maps, then try again."
        }
    }
}

@MainActor
final class NativeTransitPlanner: ObservableObject {
    static let shared = NativeTransitPlanner()
    @Published var message = "Open HowMuch to refresh public-transport estimates."
    private var cache: [String: TravelEstimate] = [:]
    func clear() { cache = [:]; message = "Open HowMuch to refresh public-transport estimates." }
    func estimate(shift: Shift, options: TravelReminderOptions, accountID: String) async throws -> TravelEstimate {
        func checkOwner() throws {
            try Task.checkCancellation()
            guard PushCenter.shared.currentAccountID?.lowercased() == accountID.lowercased() else { throw CancellationError() }
        }
        try checkOwner()
        let key = [accountID, shift.id.uuidString, options.origin, shift.location, "\(shift.startDate.timeIntervalSince1970)", "\(options.arrivalBuffer)"].joined(separator: "|")
        if let estimate = cache[key], Date().timeIntervalSince1970 - estimate.checkedAt < 900 { return estimate }
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test-travel") {
            if CommandLine.arguments.contains("--ui-test-travel-error") { throw TrackerError.invalid("Public transport estimates are unavailable. Your saved preferences are kept.") }
            let arrival = shift.startDate.timeIntervalSince1970 - Double(options.arrivalBuffer * 60)
            let leave = CommandLine.arguments.contains("--ui-test-transit-notification") ? Date().timeIntervalSince1970 + 20 : arrival - 1800
            return TravelEstimate(durationSeconds: 1800, distanceMeters: 10000, leaveAt: leave, arriveAt: arrival, shiftStart: shift.startDate.timeIntervalSince1970, originName: "Singapore Botanic Gardens", destinationName: "Marina Bay Sands", checkedAt: Date().timeIntervalSince1970)
        }
        #endif
        message = "Checking Apple Maps public-transport estimates…"
        let source = try await resolve(options.origin)
        try checkOwner()
        let destination = try await resolve(shift.location)
        try checkOwner()
        let request = MKDirections.Request(); request.source = source; request.destination = destination; request.transportType = .transit
        let arrival = shift.startDate.addingTimeInterval(-Double(options.arrivalBuffer * 60))
        if arrival > Date() { request.arrivalDate = arrival } else { request.departureDate = Date() }
        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler(operation: { try await directions.calculateETA() }, onCancel: { directions.cancel() })
        try checkOwner()
        guard response.expectedTravelTime.isFinite, response.expectedTravelTime > 0, response.expectedTravelTime <= 86400 else { throw TrackerError.invalid("No public-transport estimate was found for this journey.") }
        let result = TravelEstimate(durationSeconds: Int(ceil(response.expectedTravelTime)), distanceMeters: Int(response.distance), leaveAt: response.expectedDepartureDate.timeIntervalSince1970,
            arriveAt: response.expectedArrivalDate.timeIntervalSince1970, shiftStart: shift.startDate.timeIntervalSince1970,
            originName: JobPlaceSearch.savedLocation(source.name ?? "", JobPlaceSearch.address(source)), destinationName: JobPlaceSearch.savedLocation(destination.name ?? "", JobPlaceSearch.address(destination)), checkedAt: Date().timeIntervalSince1970)
        if cache.count >= 32 { cache = [:] }; cache[key] = result
        message = "Public-transport estimates refreshed on this iPhone. Open Maps before leaving to check service changes."
        return result
    }
    private func resolve(_ address: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = address
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        let result = try await withTaskCancellationHandler(operation: { try await search.start() }, onCancel: { search.cancel() })
        try Task.checkCancellation()
        if result.mapItems.count == 1, let first = result.mapItems.first { return first }
        let title = address.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? address
        let exact = result.mapItems.filter { $0.name?.caseInsensitiveCompare(title) == .orderedSame || JobPlaceSearch.address($0).caseInsensitiveCompare(address) == .orderedSame }
        guard exact.count == 1, let item = exact.first else { throw TrackerError.invalid("This address has multiple or no matches. Choose a complete address in Find a departure address, and check the job location.") }
        return item
    }
}
