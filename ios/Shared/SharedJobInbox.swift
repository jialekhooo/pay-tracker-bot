import Foundation
import HowMuchCore

/// A job message handed from the Share extension to the app through the shared app group.
/// Holds at most one message, kept for a day, and is removed as soon as the app picks it up.
enum SharedJobInbox {
    private static let maximumAge: TimeInterval = 24 * 60 * 60
    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotFile.groupIdentifier)?
            .appendingPathComponent("shared-job-message.json")
    }
    private struct Saved: Codable { var text: String; var saved: Date }

    static func save(_ text: String) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let trimmed = String(text.prefix(JobMessageParser.maximumLength))
        try JSONEncoder().encode(Saved(text: trimmed, saved: Date()))
            .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The waiting message, if any; reading it removes it so it is only offered once.
    static func take(now: Date = Date()) -> String? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
              now.timeIntervalSince(saved.saved) < maximumAge, !saved.text.isEmpty else { return nil }
        return saved.text
    }
}
