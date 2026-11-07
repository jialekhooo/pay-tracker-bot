import UIKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import HowMuchCore

/// Share → HowMuch from WhatsApp, Telegram, Mail or Notes. Shows what was read from the message,
/// then hands it to the app, which opens Add shift filled in for review. Nothing is saved to the account here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(close: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(from: extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var text = ""
    @Published var job: PastedJob?
    @Published var stage = Stage.loading
    enum Stage { case loading, ready, handedOff, failed(String) }
    let close: () -> Void
    init(close: @escaping () -> Void) { self.close = close }

    func load(from items: [NSExtensionItem]) async {
        var pieces: [String] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { pieces.append(text) }
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let string = value as? String { pieces.append(string) }
                    else if let data = value as? Data, let string = String(data: data, encoding: .utf8) { pieces.append(string) }
                    else if let url = value as? URL, let string = try? String(contentsOf: url, encoding: .utf8) { pieces.append(string) }
                }
            }
        }
        text = pieces.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage = .failed("There was no text to read. Share the message text itself."); return
        }
        job = JobMessageParser.parse(text)
        stage = .ready
    }

    func handOff() async {
        do {
            try SharedJobInbox.save(text)
        } catch {
            stage = .failed("Couldn't pass this to HowMuch. Copy the message and use Paste in Add shift instead."); return
        }
        // Extensions can't open their app directly; a notification tap opens HowMuch straight to the filled-in shift.
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional {
            let content = UNMutableNotificationContent()
            content.title = "Job ready to review"
            content.body = "Tap to check the dates and pay, then save it in HowMuch."
            content.userInfo = ["kind": "shared_job"]
            content.sound = nil
            try? await center.add(UNNotificationRequest(identifier: "howmuch.shared-job", content: content,
                                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
        stage = .handedOff
    }
}

/// HowMuch teal; a lighter jade in Dark Mode so text and buttons stay readable on the dark share sheet.
private let teal = Color(UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.53, green: 0.9, blue: 0.76, alpha: 1) : UIColor(red: 0.071, green: 0.42, blue: 0.369, alpha: 1) })

struct ShareView: View {
    @ObservedObject var model: ShareModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.stage {
                    case .loading:
                        ProgressView("Reading the message…").frame(maxWidth: .infinity, minHeight: 200)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    case .handedOff:
                        Label("Sent to HowMuch.", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(teal)
                        Text("Tap the “Job ready to review” notification, or open HowMuch. Add shift opens with everything filled in so you can check it and save.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    case .ready:
                        if let job = model.job { summary(job) }
                    }
                }.padding(20)
            }
            .navigationTitle("Add to HowMuch").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .handedOff = model.stage { EmptyView() } else { Button("Cancel") { model.close() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .handedOff = model.stage { Button("Done") { model.close() }.fontWeight(.semibold) }
                    else if case .ready = model.stage { Button("Add") { Task { await model.handOff() } }.fontWeight(.semibold) }
                }
            }
        }
        .tint(teal)
    }

    @ViewBuilder private func summary(_ job: PastedJob) -> some View {
        if job.dates.isEmpty {
            Label("No dates and times were found. You can still add it and fill them in.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(job.name.isEmpty ? "New job" : job.name).font(.title3.weight(.semibold))
            if let location = job.location { Label(location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary) }
        }
        if !job.dates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(job.dates.enumerated()), id: \.offset) { _, date in
                    HStack {
                        Text(label(date.day)).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Shift.clock(date.startMinute))–\(Shift.clock(date.endMinute))").font(.subheadline).monospacedDigit()
                    }
                }
            }.padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        if let rate = job.rate { Text("Pay: \(job.currency ?? "") \(rate) per hour").font(.subheadline) }
        else if let fixed = job.fixedPay { Text("Pay: \(job.currency ?? "") \(fixed) per date").font(.subheadline) }
        else { Text("No pay in the message. Your usual rate will be used.").font(.caption).foregroundStyle(.secondary) }
        ForEach(job.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        Text("Nothing is saved until you check it in HowMuch.").font(.caption).foregroundStyle(.secondary)
    }

    private func label(_ day: String) -> String {
        guard let date = TrackerCalendar.localDate(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
