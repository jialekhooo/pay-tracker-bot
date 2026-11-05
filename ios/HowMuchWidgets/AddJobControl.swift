import SwiftUI
import WidgetKit
import AppIntents

/// Control Center, Lock Screen or Action button: opens Add shift, filled in from a copied job message.
@available(iOSApplicationExtension 18.0, *)
struct AddJobControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "HowMuch.AddJob") {
            ControlWidgetButton(action: AddJobIntent()) {
                Label("Add job", systemImage: "plus.circle")
            }
        }
        .displayName("Add a job")
        .description("Opens Add shift in HowMuch. Copy a job message first and it's filled in for you.")
    }
}
