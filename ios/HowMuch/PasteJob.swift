import SwiftUI
import HowMuchCore

/// Top card of Add shift: paste a job offer message and the editor is filled in for review.
struct PasteJobCard: View {
    let result: PastedJob?
    /// The pasted text; the editor reads it (rules first, then Apple Intelligence).
    let onText: (String) -> Void
    @State private var typing = false

    var body: some View {
        Card {
            Label("PASTE A JOB MESSAGE", systemImage: "text.bubble").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.muted)
            Text("Copy a job offer from WhatsApp or Telegram and paste it here. The dates, times, location and pay are filled in below for you to check.")
                .font(.caption).foregroundStyle(Palette.muted)
            if AppleIntelligence.isAvailable {
                Label("Apple Intelligence reads unusual wording, on your iPhone", systemImage: "apple.intelligence")
                    .font(.caption2.weight(.medium)).foregroundStyle(Palette.teal)
            }
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    DispatchQueue.main.async { onText(text) }
                }
                .buttonBorderShape(.roundedRectangle(radius: 16)).controlSize(.large).tint(Palette.accent).labelStyle(.titleAndIcon)
                .accessibilityIdentifier("paste.clipboard")
                Button("Type or edit", systemImage: "keyboard") { typing = true }
                    .glassAction().accessibilityIdentifier("paste.type")
            }
            if let result, !result.dates.isEmpty { summary(result) }
        }
        .sheet(isPresented: $typing) { JobMessageEntry { onText($0) } }
    }

    private func summary(_ job: PastedJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Filled in \(job.dates.count) \(job.dates.count == 1 ? "date" : "dates") from the message. Check the name and pay before saving.",
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(Palette.teal)
                .accessibilityIdentifier("paste.summary")
            if job.rate == nil && job.fixedPay == nil {
                Text("No pay was found in the message, so your usual rate is used.").font(.caption).foregroundStyle(Palette.muted)
            }
            ForEach(job.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.muted) }
            if !job.skipped.isEmpty {
                Text("Not used: " + job.skipped.prefix(4).joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
            }
        }.padding(.top, 4)
    }
}

/// For messages that can't be pasted in one go, or need a quick fix before reading.
struct JobMessageEntry: View {
    let onText: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste or type the job details. One date per line works best, for example “13-14 Nov 0800-2000hrs”.")
                    .font(.caption).foregroundStyle(Palette.muted)
                TextEditor(text: $text)
                    .focused($focused).scrollContentBackground(.hidden).padding(10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .frame(minHeight: 240).accessibilityIdentifier("paste.text")
                Spacer()
            }
            .padding(20).background(Palette.canvas)
            .navigationTitle("Job message").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fill in") { onText(text); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("paste.fill")
                }
            }
            .onAppear { focused = true }
        }
    }
}
