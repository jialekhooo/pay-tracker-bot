import Foundation
import StoreKit
import SwiftUI

/// Everything HowMuch sells through the App Store.
enum StoreCatalog {
    static let prefix = "com.jialekhoo.howmuch."
    static let monthly = prefix + "pro.monthly"
    static let yearly = prefix + "pro.yearly"
    static let lifetime = prefix + "pro.lifetime"
    static let proPlans = [yearly, monthly, lifetime]
    /// Penny packs: product ID → the pack's items (the same lists the server keeps).
    static let packs: [String: [String]] = [
        prefix + "penny.celebration": ["halo", "heart-glasses", "lei", "fireworks", "galaxy"],
        prefix + "penny.wonder": ["bunny-ears", "3d-glasses", "bell-collar", "aurora", "frost"],
    ]
    static let packOrder = [prefix + "penny.celebration", prefix + "penny.wonder"]
    /// Coin bundles: product ID → coins.
    static let coins: [String: Int] = [prefix + "coins.150": 150, prefix + "coins.400": 400, prefix + "coins.1000": 1000]
    static let coinOrder = [prefix + "coins.150", prefix + "coins.400", prefix + "coins.1000"]
    static var all: [String] { proPlans + packOrder + coinOrder }
    static func pack(for item: String) -> String? { packs.first { $0.value.contains(item) }?.key }
}

/// What the person has from the App Store, and buying more.
///
/// Pro comes from any of: a live subscription or lifetime on this Apple Account (StoreKit), a purchase the server
/// has on record for the HowMuch account (so it follows the account to another iPhone), or being an early
/// supporter or developer (the server decides). Coin bundles only count once the server has credited them:
/// until then the transaction is left unfinished, so StoreKit hands it over again on the next launch.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loadingProducts = false
    /// Plans whose free trial this Apple Account can still use.
    @Published private(set) var trialEligible: Set<String> = []
    /// A live subscription or lifetime on this Apple Account.
    @Published private(set) var purchasedPro = false
    /// The plan in use, when bought on this Apple Account.
    @Published private(set) var activePlan: String?
    @Published private(set) var renewalDate: Date?
    /// Penny packs (product IDs) owned on this Apple Account.
    @Published private(set) var ownedPacks: Set<String> = []
    /// Pro as the server sees the HowMuch account: early supporter, developer or a purchase on record.
    @Published private(set) var serverPro = false
    @Published private(set) var serverReason: String?
    @Published var busy: String?
    @Published var message: String?
    /// TestFlight and Xcode only: see HowMuch as a new person would, ignoring early-supporter Pro.
    @AppStorage("pro.testAsNewUser") var testAsNewUser = false
    @Published private(set) var isTestBuild = false

    /// Sends signed transactions to the account; returns the IDs the server accepted.
    var recordPurchases: (([String]) async -> Set<String>?)?
    var accountToken: UUID?
    private var updates: Task<Void, Never>?

    var hasPro: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test-pro") { return true }
        if CommandLine.arguments.contains("--ui-test-free") { return false }
        #endif
        if purchasedPro { return true }
        if testAsNewUser && isTestBuild { return serverReason == "purchase" }
        return serverPro
    }

    /// Why Pro is on, in words, for Settings.
    var statusLine: String {
        if purchasedPro {
            switch activePlan {
            case StoreCatalog.lifetime: return "Lifetime"
            case StoreCatalog.yearly: return "Yearly plan" + (renewalDate.map { " · renews \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
            case StoreCatalog.monthly: return "Monthly plan" + (renewalDate.map { " · renews \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
            default: return "Active"
            }
        }
        guard hasPro else { return "Not active" }
        switch serverReason {
        case "pioneer": return "Free for early supporters"
        case "developer": return "Developer"
        default: return "Active"
        }
    }

    /// What StoreKit last said, so a launch doesn't briefly lock Pro features while it checks again.
    private init() { purchasedPro = UserDefaults.standard.bool(forKey: "pro.purchased") }

    func start() {
        guard updates == nil else { return }
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--ui-test") || $0 == "--preview" }) { return }
        #endif
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates { await self?.handle(result) }
        }
        Task {
            if let shared = try? await AppTransaction.shared, case .verified(let app) = shared {
                isTestBuild = app.environment != .production
            }
            await refreshEntitlements()
            await finishWaitingTransactions()
        }
    }

    /// Remembers the server's answer, per account, for offline launches.
    func setServer(pro: Bool?, reason: String?, accountID: String) {
        let key = "pro.server.\(accountID)"
        if let pro {
            serverPro = pro; serverReason = reason
            UserDefaults.standard.set(pro, forKey: key); UserDefaults.standard.set(reason, forKey: key + ".reason")
        } else {
            serverPro = UserDefaults.standard.bool(forKey: key); serverReason = UserDefaults.standard.string(forKey: key + ".reason")
        }
    }

    func signedOut() { serverPro = false; serverReason = nil; accountToken = nil }

    func loadProducts() async {
        guard products.isEmpty, !loadingProducts else { return }
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let found = try await Product.products(for: StoreCatalog.all)
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            var eligible = Set<String>()
            for product in found where product.subscription?.introductoryOffer != nil {
                if await product.subscription?.isEligibleForIntroOffer == true { eligible.insert(product.id) }
            }
            trialEligible = eligible
            if found.isEmpty { message = "The App Store isn't available right now. Try again later." }
        } catch {
            message = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    /// Buys a product. Returns true once it's bought (coins: once they're added to the account).
    @discardableResult
    func buy(_ id: String) async -> Bool {
        guard let product = products[id] else { message = "This isn't available right now. Try again later."; return false }
        busy = id; message = nil
        defer { busy = nil }
        do {
            var options: Set<Product.PurchaseOption> = []
            if let accountToken { options.insert(.appAccountToken(accountToken)) }
            switch try await product.purchase(options: options) {
            case .success(let result): return await handle(result)
            case .pending: message = "Your purchase is waiting for approval. It will appear here once it's approved."
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            message = "The purchase didn't go through. You haven't been charged. \(error.localizedDescription)"
        }
        return false
    }

    /// Restore purchases: asks the App Store for this Apple Account's purchases again.
    func restore() async {
        busy = "restore"; message = nil
        defer { busy = nil }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = purchasedPro || !ownedPacks.isEmpty ? "Your purchases are restored." : "No purchases were found for this Apple Account."
        } catch {
            message = "Couldn't restore purchases. Check your connection and try again."
        }
    }

    /// Reads what this Apple Account owns, and tells the server about it.
    func refreshEntitlements() async {
        var pro = false, plan: String?, renews: Date?, packs = Set<String>(), signed: [String] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            signed.append(result.jwsRepresentation)
            if StoreCatalog.proPlans.contains(transaction.productID) {
                if let expiry = transaction.expirationDate, expiry < Date() { continue }
                pro = true
                if plan != StoreCatalog.lifetime { plan = transaction.productID; renews = transaction.expirationDate }
            } else if StoreCatalog.packs[transaction.productID] != nil {
                packs.insert(transaction.productID)
            }
        }
        purchasedPro = pro; activePlan = plan; renewalDate = renews; ownedPacks = packs
        UserDefaults.standard.set(pro, forKey: "pro.purchased")
        if !signed.isEmpty { _ = await recordPurchases?(signed) }
    }

    /// Coin purchases the server hasn't credited yet (for example, bought while offline).
    func finishWaitingTransactions() async {
        for await result in StoreKit.Transaction.unfinished { await handle(result) }
    }

    @discardableResult
    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else {
            message = "This purchase couldn't be verified, so nothing was added."
            return false
        }
        if let coins = StoreCatalog.coins[transaction.productID] {
            guard transaction.revocationDate == nil else { await transaction.finish(); return false }
            guard let accepted = await recordPurchases?([result.jwsRepresentation]) else {
                message = "Your \(coins) coins are bought and will be added when HowMuch can reach your account."
                return false
            }
            if accepted.contains(String(transaction.id)) {
                await transaction.finish()
                message = "\(coins) coins added to Penny's purse."
                return true
            }
            await transaction.finish()  // refused for good (for example, already added to another account): don't ask again
            message = "These coins couldn't be added to this account. If you were charged, contact HowMuch support from Settings."
            return false
        }
        await transaction.finish()
        await refreshEntitlements()
        return transaction.revocationDate == nil
    }

    // MARK: Prices for display

    func price(_ id: String) -> String? { products[id]?.displayPrice }

    /// "S$1.67/month" for the yearly plan.
    func monthlyEquivalent(_ id: String) -> String? {
        guard let product = products[id], let period = product.subscription?.subscriptionPeriod, period.unit == .year else { return nil }
        let perMonth = product.price / Decimal(12 * period.value)
        return perMonth.formatted(product.priceFormatStyle) + "/month"
    }

    /// "1-week free trial" when the plan has a free introductory offer this person can use.
    func trial(_ id: String) -> String? {
        guard trialEligible.contains(id), let offer = products[id]?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let unit: String
        switch offer.period.unit {
        case .day: unit = offer.period.value == 7 ? "week" : "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        let count = offer.period.unit == .day && offer.period.value == 7 ? 1 : offer.period.value
        return "\(count)-\(unit) free trial"
    }
}
