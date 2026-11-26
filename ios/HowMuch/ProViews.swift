import SwiftUI
import StoreKit
import HowMuchCore

/// The parts of HowMuch that need Pro. Tracking shifts (in up to FreePlan.eventLimit events), earnings, the calendar and Penny stay free.
enum ProFeature: String, CaseIterable, Identifiable {
    case events, payIn, reminders, calendar, insights
    var id: String { rawValue }
    var title: String {
        switch self {
        case .events: "Unlimited events"
        case .payIn: "Pay-in tracking"
        case .reminders: "Reminders and live shift"
        case .calendar: "Calendar sync and exports"
        case .insights: "Insights and widgets"
        }
    }
    var detail: String {
        switch self {
        case .events: "Free accounts keep up to \(FreePlan.eventLimit) events. Pro keeps every job you work."
        case .payIn: "Bank alerts and forwarded emails mark your shifts paid."
        case .reminders: "Job reminders, time to leave, and your shift on the Lock Screen."
        case .calendar: "Your shifts in Apple or Google Calendar, plus CSV and calendar exports."
        case .insights: "A monthly recap, earnings by month, and Home Screen widgets."
        }
    }
    var symbol: String {
        switch self {
        case .events: "square.stack.3d.up"
        case .payIn: "creditcard"
        case .reminders: "bell.badge"
        case .calendar: "calendar.badge.plus"
        case .insights: "chart.bar.xaxis"
        }
    }
}

enum ProLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://howmuch-ios.fly.dev/privacy")!
}

/// A small "PRO" tag beside things that need Pro.
struct ProBadge: View {
    var body: some View {
        Text("PRO").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(Palette.teal)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.teal.opacity(0.1), in: Capsule())
            .fixedSize().accessibilityLabel("Needs HowMuch Pro")
    }
}

/// Shows `content` with Pro, and what Pro includes (with the plans) without it.
struct ProGate<Content: View>: View {
    let feature: ProFeature
    @ViewBuilder var content: () -> Content
    @ObservedObject private var pro = ProStore.shared
    var body: some View {
        if pro.hasPro { content() } else { ProPaywall(feature: feature).detailStyle(feature.title) }
    }
}

/// In place of something that needs Pro: what it is, and a button to the plans.
struct ProLockedCard: View {
    let feature: ProFeature
    let title: String
    let message: String
    @State private var showingPlans = false
    var body: some View {
        Card {
            HStack(spacing: 8) { Image(systemName: feature.symbol).foregroundStyle(Palette.teal); Text(title).font(.appHeadline); Spacer(); ProBadge() }
            Text(message).font(.subheadline).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Button("See HowMuch Pro") { showingPlans = true }.primaryButton().accessibilityIdentifier("pro.locked.\(feature.rawValue)")
        }
        .sheet(isPresented: $showingPlans) {
            NavigationStack { ProPaywall(feature: feature).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showingPlans = false } } } }
        }
    }
}

/// Settings → HowMuch Pro.
struct ProSettingsView: View {
    @ObservedObject private var pro = ProStore.shared
    @State private var managing = false
    var body: some View {
        Group {
            if pro.hasPro {
                AppForm {
                    Section(styled: "Your plan") {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Palette.success)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pro is on").font(.appHeadline)
                                Text(pro.statusLine).font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("pro.status")
                            }
                        }.padding(.vertical, 4)
                        if pro.activePlan == StoreCatalog.monthly || pro.activePlan == StoreCatalog.yearly {
                            Button("Manage subscription", systemImage: "arrow.triangle.2.circlepath") { managing = true }.rowAction()
                        }
                        Button(pro.busy == "restore" ? "Restoring…" : "Restore purchases", systemImage: "arrow.clockwise") { Task { await pro.restore() } }
                            .rowAction().disabled(pro.busy != nil)
                        if let message = pro.message { Text(message).formFootnote() }
                    }
                    Section(styled: "Included") {
                        ForEach(ProFeature.allCases) { feature in ProFeatureRow(feature: feature) }
                    }
                    if pro.serverReason == "pioneer" && !pro.purchasedPro {
                        Text("Thank you for being here early. Pro stays free on this account.").formFootnote()
                    }
                    testerSection
                }
                .manageSubscriptionsSheet(isPresented: $managing)
            } else {
                ProPaywall(feature: nil)
            }
        }
        .detailStyle("HowMuch Pro")
    }

    @ViewBuilder private var testerSection: some View {
        if pro.isTestBuild {
            Section(styled: "Testing") {
                Toggle("Test as a new user", isOn: $pro.testAsNewUser).accessibilityIdentifier("pro.testAsNewUser")
                Text("TestFlight only. Ignores early-supporter Pro on this iPhone so you can try the paywall and sandbox purchases.").formFootnote()
            }
        }
    }
}

struct ProFeatureRow: View {
    let feature: ProFeature
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol).font(.rowIcon).frame(width: 32, height: 32).foregroundStyle(Palette.teal)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(feature.detail).font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// What Pro includes, the three plans, and buying one. Shown wherever a Pro feature is opened without Pro.
struct ProPaywall: View {
    let feature: ProFeature?
    @ObservedObject private var pro = ProStore.shared
    @State private var plan = StoreCatalog.yearly
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOWMUCH PRO").font(.caption.weight(.bold)).tracking(2.2).foregroundStyle(Palette.teal)
                    Text(feature.map { "\($0.title) is part of Pro" } ?? "Less admin, more paid shifts").font(.appTitle).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pro.paywall.title")
                    Text("Tracking shifts in up to \(FreePlan.eventLimit) events, earnings, the calendar and Penny stay free. Pro adds unlimited events and the tools that do the chasing for you.")
                        .font(.subheadline).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Card {
                    ForEach(ProFeature.allCases) { item in ProFeatureRow(feature: item) }
                }
                VStack(spacing: 10) {
                    ForEach(StoreCatalog.proPlans, id: \.self) { id in planButton(id) }
                }
                if pro.loadingProducts && pro.products.isEmpty {
                    ProgressView("Loading prices…").frame(maxWidth: .infinity)
                }
                Button { Task { await pro.buy(plan) } } label: {
                    if pro.busy == plan { ProgressView().tint(.white) } else { Text(buyTitle) }
                }
                .primaryButton().disabled(pro.products[plan] == nil || pro.busy != nil)
                .accessibilityIdentifier("pro.buy")
                if pro.products[plan] != nil {
                    Text(terms).font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let message = pro.message {
                    Text(message).font(.caption).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pro.message")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { links }
                    VStack(alignment: .leading, spacing: 4) { links }
                }
                // While testing as a new user, Pro is off, so Settings shows these plans instead of the switch: keep it here.
                if pro.isTestBuild && pro.testAsNewUser {
                    Card {
                        Toggle("Test as a new user", isOn: $pro.testAsNewUser).font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("pro.paywall.testAsNewUser")
                        Text("TestFlight only. Turn this off to see HowMuch with your own Pro again.").font(.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20).readableWidth()
        }
        .background(AppBackdrop())
        .task { await pro.loadProducts() }
    }

    @ViewBuilder private var links: some View {
        Button(pro.busy == "restore" ? "Restoring…" : "Restore purchases") { Task { await pro.restore() } }
            .font(.caption.weight(.semibold)).frame(minHeight: 44).disabled(pro.busy != nil).accessibilityIdentifier("pro.restore")
        Button("Terms of Use") { openURL(ProLinks.terms) }.font(.caption.weight(.semibold)).frame(minHeight: 44)
        Button("Privacy Policy") { openURL(ProLinks.privacy) }.font(.caption.weight(.semibold)).frame(minHeight: 44)
    }

    private func planButton(_ id: String) -> some View {
        let selected = plan == id
        let name = id == StoreCatalog.yearly ? "Yearly" : id == StoreCatalog.monthly ? "Monthly" : "Lifetime"
        let period = id == StoreCatalog.yearly ? "/year" : id == StoreCatalog.monthly ? "/month" : " once"
        let note: String? = id == StoreCatalog.lifetime ? "Pay once, keep Pro forever" : [pro.trial(id), pro.monthlyEquivalent(id)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        return Button { plan = id } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.title3).foregroundStyle(selected ? Palette.teal : Palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.appHeadline).foregroundStyle(Palette.ink)
                        if id == StoreCatalog.yearly { Text("BEST VALUE").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent).padding(.horizontal, 6).padding(.vertical, 2).background(Palette.mint, in: Capsule()).fixedSize() }
                    }
                    if let note { Text(note).font(.caption).foregroundStyle(Palette.muted) }
                }
                Spacer(minLength: 8)
                Text((pro.price(id) ?? "–") + period).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(14).frame(minHeight: 60)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Palette.teal : Palette.line.opacity(0.7), lineWidth: selected ? 2 : 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("pro.plan.\(name.lowercased())")
    }

    private var buyTitle: String {
        if plan == StoreCatalog.lifetime { return "Buy lifetime" + (pro.price(plan).map { " · \($0)" } ?? "") }
        return pro.trial(plan) != nil ? "Start free trial" : "Subscribe" + (pro.price(plan).map { " · \($0)" } ?? "")
    }

    private var terms: String {
        if plan == StoreCatalog.lifetime { return "One payment. No subscription." }
        let price = pro.price(plan) ?? "The price shown"
        let every = plan == StoreCatalog.yearly ? "year" : "month"
        // "1-week free trial" → "Free for 1 week, then "
        let start = pro.trial(plan).map { "Free for \($0.replacingOccurrences(of: " free trial", with: "").replacingOccurrences(of: "-", with: " ")), then " } ?? ""
        return "\(start)\(price) a \(every). Renews automatically until you cancel, at least 24 hours before the period ends, in Settings → your name → Subscriptions."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Penny's item packs and coin bundles. Coins are also earned free by working shifts, getting paid, missions and friends.
struct PennyStoreView: View {
    let petName: String
    @EnvironmentObject private var store: TrackerStore
    @ObservedObject private var purchases = ProStore.shared
    @State private var trying: String?

    var body: some View {
        let pet = store.petProgress()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "Item packs", detail: "Yours to keep")
                ForEach(StoreCatalog.packOrder, id: \.self) { id in packCard(id, pet) }
                SectionHeading(title: "Coins", detail: "For the shop")
                VStack(spacing: 10) { ForEach(StoreCatalog.coinOrder, id: \.self) { coinRow($0) } }
                Text("Coins are also free: \(petName) earns them for every shift you work and get paid for, for missions, badges and saying hi to friends.")
                    .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if let message = purchases.message {
                    Text(message).font(.caption).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("store.message")
                }
                Button(purchases.busy == "restore" ? "Restoring…" : "Restore purchases") { Task { await purchases.restore() } }
                    .font(.caption.weight(.semibold)).frame(minHeight: 44).disabled(purchases.busy != nil)
            }
            .padding(20).readableWidth()
        }
        .background(AppBackdrop())
        .detailStyle("Penny's store")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CoinLabel(amount: store.petCloset.balance(pet)) } }
        .task { await purchases.loadProducts() }
        .sheet(item: Binding(get: { trying.map(PackChoice.init) }, set: { trying = $0?.id })) { choice in
            NavigationStack { packTryOn(choice.id, pet) }
        }
    }

    private struct PackChoice: Identifiable { let id: String }

    /// The whole pack on your pet before buying. The App Store asks to confirm the purchase itself.
    private func packTryOn(_ id: String, _ pet: PetProgress) -> some View {
        let pack = PetPack.named(id.replacingOccurrences(of: StoreCatalog.prefix + "penny.", with: ""))!
        let owned = pack.items.allSatisfy { store.petCloset.owns($0, pet) }
        return PetTryOnView(title: pack.name, detail: pack.detail, items: pack.items, pet: pet, closet: store.petCloset, petName: petName) {
            if owned {
                Label("Owned · wear them from the wardrobe", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.success)
            } else {
                Button { Task { if await purchases.buy(id) { trying = nil } } } label: {
                    if purchases.busy == id { ProgressView().tint(.white) } else { Text("Buy " + (purchases.price(id).map { "· \($0)" } ?? "")) }
                }
                .primaryButton().disabled(purchases.products[id] == nil || purchases.busy != nil).accessibilityIdentifier("store.tryOn.buy.\(pack.id)")
            }
            if let message = purchases.message {
                Text(message).font(.caption).foregroundStyle(Palette.warning).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func packCard(_ id: String, _ pet: PetProgress) -> some View {
        let pack = PetPack.named(id.replacingOccurrences(of: StoreCatalog.prefix + "penny.", with: ""))!
        let owned = pack.items.allSatisfy { store.petCloset.owns($0, pet) }
        var outfit: [PetSlot: PetItem] = [:]
        for item in pack.items where item.slot != .background { outfit[item.slot] = item }
        return Card {
            HStack(spacing: 14) {
                ZStack {
                    PetScene(item: pack.items.first { $0.slot == .background })
                    PetSprite(stage: max(pet.stage, .coinling), mood: .happy, outfit: outfit, animate: false).frame(width: 78, height: 78)
                }
                .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name).font(.appHeadline).foregroundStyle(Palette.ink)
                    Text(pack.detail).font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button { trying = id } label: { Label("Try it on \(petName)", systemImage: "sparkles") }
                .rowAction().accessibilityIdentifier("store.tryOn.\(pack.id)")
            if owned {
                Label("Owned · wear them from the wardrobe", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.success)
                    .accessibilityIdentifier("store.owned.\(pack.id)")
            } else {
                Button { Task { await purchases.buy(id) } } label: {
                    if purchases.busy == id { ProgressView().tint(.white) } else { Text("Buy " + (purchases.price(id).map { "· \($0)" } ?? "")) }
                }
                .primaryButton().disabled(purchases.products[id] == nil || purchases.busy != nil).accessibilityIdentifier("store.buy.\(pack.id)")
            }
        }
    }

    private func coinRow(_ id: String) -> some View {
        let coins = StoreCatalog.coins[id] ?? 0
        return HStack(spacing: 12) {
            CoinLabel(amount: coins, font: .appHeadline)
            Spacer()
            Button { Task { await purchases.buy(id) } } label: {
                if purchases.busy == id { ProgressView() } else { Text(purchases.price(id) ?? "–").monospacedDigit() }
            }
            .buttonStyle(.bordered).tint(Palette.accent).frame(minHeight: 44)
            .disabled(purchases.products[id] == nil || purchases.busy != nil)
            .accessibilityIdentifier("store.coins.\(coins)")
        }
        .padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.7), lineWidth: 0.6))
        .accessibilityElement(children: .combine)
    }
}
