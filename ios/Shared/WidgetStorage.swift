import Foundation
import WidgetKit
import HowMuchCore

enum SharedWidgetStorage {
    static var directory: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotFile.groupIdentifier) }
    static func read() -> WidgetSnapshot? { directory.flatMap { WidgetSnapshotFile.read(directory: $0) } }
    static func publish(_ snapshot: WidgetSnapshot) throws {
        guard let directory else { throw TrackerError.invalid("Widget sharing is unavailable in this installation.") }
        try WidgetSnapshotFile.write(snapshot, directory: directory)
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func clear() {
        if let directory { try? WidgetSnapshotFile.clear(directory: directory) }
        PennyWidgetFile.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// What the Penny widget shows: the pet only (and, on the medium size, the next shift from the main snapshot).
struct PennyWidgetInfo: Codable, Equatable {
    var accountID: String
    var name: String
    var stage: String
    var level: Int
    var mood: String
    var streakWeeks: Int
    var hatched: Bool
}

/// Penny's details plus a picture of her (light and dark rooms), drawn by the app into the shared app group,
/// because the widget can't run the app's pet drawing code.
enum PennyWidgetFile {
    private static let infoName = "penny-widget.json"
    private static func imageName(dark: Bool) -> String { dark ? "penny-dark.png" : "penny-light.png" }
    private static func url(_ name: String) -> URL? { SharedWidgetStorage.directory?.appendingPathComponent(name) }

    static func read() -> PennyWidgetInfo? {
        guard let url = url(infoName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PennyWidgetInfo.self, from: data)
    }
    static func imageURL(dark: Bool) -> URL? {
        guard let url = url(imageName(dark: dark)), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    static func write(_ info: PennyWidgetInfo, light: Data, dark: Data) throws {
        guard let directory = SharedWidgetStorage.directory, let infoURL = url(infoName),
              let lightURL = url(imageName(dark: false)), let darkURL = url(imageName(dark: true)) else {
            throw TrackerError.invalid("Widget sharing is unavailable in this installation.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try light.write(to: lightURL, options: options)
        try dark.write(to: darkURL, options: options)
        try JSONEncoder().encode(info).write(to: infoURL, options: options)
        WidgetCenter.shared.reloadTimelines(ofKind: "HowMuch.Penny")
    }
    static func clear() {
        for name in [infoName, imageName(dark: false), imageName(dark: true)] {
            if let url = url(name), FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
