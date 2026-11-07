import SwiftUI
import HowMuchCore

struct ShiftDetailView: View {
    @EnvironmentObject private var store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    let shiftID: UUID
    @State private var editing = false
    @State private var deleting = false
    @State private var duplicating = false
    @State private var calendar = false
    @State private var directions = false
    private var shift: Shift? { store.data.shifts.first { $0.id == shiftID } }
    var body: some View {
        Group {
            if let shift {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Card {
                            HStack { Text("WORK PAYOUT").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(Palette.muted); Spacer(); StatusPill(title: shift.state(at: Date()), paid: shift.paid && shift.endDate <= Date()) }
                            Text(money(shift.total, shift.currency)).font(.heroAmount).foregroundStyle(Palette.ink).minimumScaleFactor(0.6).lineLimit(1)
                            Text("\(PayEngine.rounded(shift.hours)) paid hours · \(shift.fixedPay == nil ? "Hourly" : "Fixed payout")").font(.subheadline).foregroundStyle(Palette.muted)
                            if let extra = shift.extra {
                                Text("\(money(shift.pay, shift.currency)) pay + \(money(extra, shift.currency)) \(shift.extraNote ?? "extra")")
                                    .font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("shift.extraBreakdown")
                            }
                            // Payment only makes sense once the work is done.
                            if shift.endDate <= Date() {
                                Button(shift.paid ? "Mark as unpaid" : "Mark as paid", systemImage: shift.paid ? "arrow.uturn.backward" : "checkmark.circle") {
                                    var updated = shift; updated.paid.toggle(); _ = store.save(updated)
                                }.primaryButton().accessibilityIdentifier("shift.paid")
                            }
                        }
                        Card {
                            Label(shift.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year()), systemImage: "calendar").font(.subheadline.weight(.semibold))
                            Label("\(Shift.clock(shift.startMinute))–\(Shift.clock(shift.endMinute))\(shift.endMinute <= shift.startMinute ? " (+1 day)" : "")", systemImage: "clock").font(.subheadline)
                            if !shift.location.isEmpty { Label(shift.location, systemImage: "mappin.and.ellipse").font(.subheadline) }
                            if let due = shift.paymentDue { Divider(); LabeledContent("Payment due", value: displayDay(due)).font(.subheadline) }
                        }
                        if !shift.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Map & directions", systemImage: "map.fill") { directions = true }.glassAction().accessibilityIdentifier("shift.directions")
                            if shift.startDate > Date() {
                                NavigationLink(destination: TravelDepartureView(shift: shift)) { Label("Time to leave", systemImage: "figure.walk.departure") }
                                    .glassAction().accessibilityIdentifier("shift.travel")
                            }
                        }
                        let clashes = store.data.shifts.filter { shift.overlaps($0) }
                        if !clashes.isEmpty {
                            Card { ForEach(clashes) { other in Label("\(other.event) · \(displayDay(other.day))", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) } }
                        }
                        Card {
                            DisclosureGroup("Pay breakdown") {
                                VStack(spacing: 14) {
                                    LabeledContent("Paid hours", value: "\(PayEngine.rounded(shift.hours))")
                                    LabeledContent("Break", value: "\(shift.breakMinutes) min · \(shift.paidBreak ? "paid" : "unpaid")")
                                    if let fixed = shift.fixedPay {
                                        LabeledContent("Lump Sum Rate", value: money(fixed, shift.currency))
                                    } else {
                                        LabeledContent("Hourly Rate", value: money(shift.rate, shift.currency) + "/h")
                                        if let threshold = shift.overtimeAfter {
                                            Text("Overtime after \(threshold)h · ×\(shift.overtimeMultiplier)").font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    if let extra = shift.extra {
                                        LabeledContent(shift.extraNote ?? "Extra", value: "+ " + money(extra, shift.currency))
                                    }
                                }.font(.subheadline).padding(.top, 14)
                            }.font(.subheadline.weight(.semibold))
                        }
                        ReimbursementsSection(shifts: [shift], currency: shift.currency)
                        VStack(spacing: 10) {
                            Button("Add to Apple Calendar", systemImage: "calendar.badge.plus") { calendar = true }.glassAction()
                            Button("Duplicate as new shift", systemImage: "plus.square.on.square") { duplicating = true }.glassAction()
                            NavigationLink { EventDetailView(event: shift.event, currency: shift.currency) } label: {
                                Label("View event earnings", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                            if store.canUndo {
                                Button { store.undo() } label: {
                                    Label("Undo last change", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                                }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                            }
                            Button(role: .destructive) { deleting = true } label: {
                                Label("Delete shift", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        }
                    }.padding(20)
                }.detailStyle(shift.event)
                    .toolbar { Button("Edit") { editing = true } }
                    .sheet(isPresented: $editing) { ShiftEditor(existing: shift) }
                    .sheet(isPresented: $duplicating) { ShiftEditor(existing: shift, duplicating: true) }
                    .sheet(isPresented: $directions) { JobDirectionsView(location: shift.location) }
                    .sheet(isPresented: $calendar) { CalendarEventEditor(shift: shift) }
                    .confirmationDialog("Delete this shift and its claims?", isPresented: $deleting, titleVisibility: .visible) {
                        Button("Delete shift", role: .destructive) { store.delete(shift); if store.error == nil { dismiss() } }
                    }
            } else { ContentUnavailableView("Shift deleted", systemImage: "calendar") }
        }
    }
}

func displayDay(_ day: String) -> String {
    TrackerCalendar.localDate(day)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? day
}

struct ReimbursementsSection: View {
    @EnvironmentObject private var store: TrackerStore
    let shifts: [Shift]
    let currency: String
    @State private var adding = false
    @State private var viewingReceipt: CabClaim?
    @State private var editing: CabClaim?
    @State private var deleting: CabClaim?
    private var claims: [CabClaim] { store.data.claims.filter { claim in shifts.contains { $0.id == claim.shiftID } }.sorted { $0.day > $1.day } }
    private var total: Decimal { claims.reduce(0) { $0 + $1.amount } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Reimbursements", detail: money(total, currency))
            if claims.isEmpty {
                Card {
                    Label("Keep your expenses with this work", systemImage: "receipt").font(.subheadline.weight(.medium))
                    Text("Add cab, food or miscellaneous claims to your estimated bank credit.").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            ForEach(claims) { claim in
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: claim.category.symbol).font(.system(size: 17)).foregroundStyle(Palette.teal).frame(width: 40, height: 40).background(Palette.mint, in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(claim.note.isEmpty ? claim.category.title + " claim" : claim.note).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                            Text(claim.category.title + " · " + displayDay(claim.day) + (claim.receiptID == nil ? "" : " · Receipt attached")).font(.caption).foregroundStyle(Palette.muted)
                            Text(money(claim.amount, currency)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.teal)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if claim.receiptID != nil { Button("View receipt", systemImage: "doc.viewfinder") { viewingReceipt = claim } }
                            Button("Edit claim", systemImage: "pencil") { editing = claim }
                            Button("Delete claim", systemImage: "trash", role: .destructive) { deleting = claim }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink).frame(width: 44, height: 44).contentShape(Circle()).glassChrome(in: Circle())
                        }.accessibilityLabel(claim.category.title + " claim actions" + (claim.note.isEmpty ? "" : ": " + claim.note)).accessibilityIdentifier("claim.actions.\(claim.id)")
                    }
                }
            }
            if shifts.first != nil {
                Button("Add claim", systemImage: "plus") { adding = true }.glassAction()
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Estimated bank credit").font(.subheadline.weight(.semibold))
                        Text("Work payout + claims").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Text(money(shifts.reduce(Decimal.zero) { $0 + $1.total } + total, currency)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                }
            }
            Text("Claims are separate from earnings. Marking work paid tracks its payout only.").font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 4)
        }
        .sheet(isPresented: $adding) { if let shift = shifts.first { ClaimEditor(shift: shift) } }
        .sheet(item: $viewingReceipt) { claim in if let id = claim.receiptID { SavedReceiptView(receiptID: id) } }
        .sheet(item: $editing) { claim in if let shift = shifts.first(where: { $0.id == claim.shiftID }) { ClaimEditor(shift: shift, existing: claim) } }
        .confirmationDialog("Delete this claim?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete claim", role: .destructive) {
                if let deleting { store.update { $0.claims.removeAll { $0.id == deleting.id && shifts.contains(where: { $0.id == deleting.shiftID }) } } }
                deleting = nil
            }
        }
    }
}
