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
        WidgetCenter.shared.reloadAllTimelines()
    }
}
