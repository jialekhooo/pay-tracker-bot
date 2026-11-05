import Foundation

/// HowMuch's pet: a little coin creature that grows as shifts are worked and paid.
/// Everything is worked out from the shifts already in the account, so nothing extra is stored or synced.
public struct PetProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case egg, hatchling, coinling, golden
        /// Experience needed to reach this stage.
        public var threshold: Int { [0, 30, 150, 500][rawValue] }
        public var title: String { ["Egg", "Hatchling", "Coinling", "Golden coin"][rawValue] }
    }
    public enum Mood: String, Sendable { case happy, sleepy, worried }

    public static let xpPerWorkedShift = 10
    public static let xpPerPaidShift = 15

    public let xp: Int
    public let stage: Stage
    /// Shifts marked paid; the pet's coin count.
    public let coins: Int
    public let mood: Mood
    /// Weeks in a row, up to this one, with at least one shift worked or booked.
    public let streakWeeks: Int
    /// Pay from finished shifts past their payment due date.
    public let overdue: Decimal

    public var next: Stage? { Stage(rawValue: stage.rawValue + 1) }
    /// 0...1 progress from this stage to the next (1 at the last stage).
    public var progress: Double {
        guard let next else { return 1 }
        return Double(xp - stage.threshold) / Double(next.threshold - stage.threshold)
    }
    public var xpToNext: Int? { next.map { $0.threshold - xp } }

    /// Levels never run out: one every `xpPerLevel`, long after the golden coin.
    public static let xpPerLevel = 40
    public var level: Int { 1 + xp / Self.xpPerLevel }
    public var levelProgress: Double { Double(xp % Self.xpPerLevel) / Double(Self.xpPerLevel) }
    public var xpToNextLevel: Int { Self.xpPerLevel - xp % Self.xpPerLevel }

    /// Coins to spend in the wardrobe: 5 per shift worked, 10 per shift paid, 25 per achievement.
    public static let coinsPerWorkedShift = 5, coinsPerPaidShift = 10, coinsPerAchievement = 25
    public let coinsEarned: Int
    public let achievements: [PetAchievement]
    /// The longest run of weeks in a row with a shift, ever.
    public let bestStreakWeeks: Int
    public func hasAchievement(_ id: String) -> Bool { achievements.contains { $0.id == id && $0.earned } }

    public init(shifts: [Shift], now: Date = Date(), calendar: Calendar = TrackerCalendar.calendar) {
        let worked = shifts.filter { $0.endDate <= now }
        let paid = worked.filter(\.paid)
        let points = worked.count * Self.xpPerWorkedShift + paid.count * Self.xpPerPaidShift
        xp = points
        stage = Stage.allCases.last { points >= $0.threshold } ?? .egg
        coins = paid.count
        let today = Shift.dayString(now)
        let late = worked.filter { !$0.paid && ($0.paymentDue ?? "9999-12-31") < today }
        overdue = late.reduce(Decimal(0)) { $0 + $1.pay }
        let week: TimeInterval = 7 * 24 * 60 * 60
        let recent = shifts.contains { abs($0.startDate.timeIntervalSince(now)) <= week || ($0.startDate <= now && now < $0.endDate) }
        mood = !late.isEmpty ? .worried : recent ? .happy : .sleepy
        var streak = 0
        var weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let starts = Set(shifts.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start })
        while starts.contains(weekStart) {
            streak += 1
            weekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
        }
        streakWeeks = streak
        // Best streak: longest run of consecutive weeks across all history.
        var best = 0, run = 0
        var previous: Date?
        for week in starts.sorted() {
            if let previous, calendar.date(byAdding: .weekOfYear, value: 1, to: previous) == week { run += 1 } else { run = 1 }
            best = max(best, run); previous = week
        }
        bestStreakWeeks = best
        let paidTotal = paid.reduce(Decimal(0)) { $0 + $1.pay }
        let list: [PetAchievement] = [
            .init(id: "first-shift", title: "First shift", detail: "Work your first shift", symbol: "briefcase.fill", current: worked.count, target: 1),
            .init(id: "regular", title: "Regular", detail: "Work 10 shifts", symbol: "calendar", current: worked.count, target: 10),
            .init(id: "veteran", title: "Veteran", detail: "Work 50 shifts", symbol: "medal.fill", current: worked.count, target: 50),
            .init(id: "payday", title: "Payday", detail: "Get a shift marked paid", symbol: "checkmark.seal.fill", current: paid.count, target: 1),
            .init(id: "collector", title: "Collector", detail: "Get 25 shifts paid", symbol: "tray.full.fill", current: paid.count, target: 25),
            .init(id: "four-figures", title: "Four figures", detail: "Be paid 1,000 in total", symbol: "banknote.fill", current: NSDecimalNumber(decimal: paidTotal).intValue, target: 1000),
            .init(id: "big-earner", title: "Big earner", detail: "Be paid 10,000 in total", symbol: "chart.line.uptrend.xyaxis", current: NSDecimalNumber(decimal: paidTotal).intValue, target: 10000),
            .init(id: "on-a-roll", title: "On a roll", detail: "Work 4 weeks in a row", symbol: "flame.fill", current: best, target: 4),
            .init(id: "unstoppable", title: "Unstoppable", detail: "Work 12 weeks in a row", symbol: "bolt.fill", current: best, target: 12),
            .init(id: "early-bird", title: "Early bird", detail: "Start a shift before 7am", symbol: "sunrise.fill", current: worked.contains { $0.startMinute < 7 * 60 } ? 1 : 0, target: 1),
            .init(id: "night-owl", title: "Night owl", detail: "Work past midnight", symbol: "moon.stars.fill", current: worked.contains { $0.endMinute <= $0.startMinute } ? 1 : 0, target: 1),
        ]
        achievements = list
        coinsEarned = worked.count * Self.coinsPerWorkedShift + paid.count * Self.coinsPerPaidShift
            + list.filter(\.earned).count * Self.coinsPerAchievement
    }

    /// What the pet says on Overview.
    public func message(name: String, currency: String) -> String {
        switch mood {
        case .worried: return "\(name) is worried: \(SpokenSummary.amount(overdue, currency)) of pay is overdue. Chase it up and mark it paid to cheer \(name) up."
        case .sleepy: return "\(name) is napping. Book your next shift to wake \(name) up."
        case .happy:
            if let xpToNext, let next { return "\(name) is happy! \(xpToNext) XP until \(next.title.lowercased())." }
            return "\(name) is happy! \(xpToNextLevel) XP to level \(level + 1)."
        }
    }
}

public struct PetAchievement: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let current: Int
    public let target: Int
    public var earned: Bool { current >= target }
    public var progress: Double { min(1, Double(current) / Double(target)) }
}

/// Things Penny can wear. Some are bought with coins, some unlock at a level or with an achievement.
public enum PetSlot: String, CaseIterable, Codable, Sendable {
    case hat, face, neck, background
    public var title: String { ["Hats", "Glasses", "Neckwear", "Backgrounds"][Self.allCases.firstIndex(of: self)!] }
}

public struct PetItem: Identifiable, Equatable, Sendable {
    public enum Unlock: Equatable, Sendable { case free, coins(Int), level(Int), achievement(String) }
    public let id: String
    public let name: String
    public let slot: PetSlot
    public let unlock: Unlock

    public static let catalog: [PetItem] = [
        .init(id: "party-hat", name: "Party hat", slot: .hat, unlock: .coins(40)),
        .init(id: "beanie", name: "Beanie", slot: .hat, unlock: .coins(60)),
        .init(id: "cap", name: "Cap", slot: .hat, unlock: .coins(80)),
        .init(id: "chef-hat", name: "Chef's hat", slot: .hat, unlock: .coins(120)),
        .init(id: "wizard-hat", name: "Wizard hat", slot: .hat, unlock: .coins(200)),
        .init(id: "flower", name: "Flower", slot: .hat, unlock: .achievement("on-a-roll")),
        .init(id: "royal-crown", name: "Royal crown", slot: .hat, unlock: .level(15)),
        .init(id: "round-glasses", name: "Round glasses", slot: .face, unlock: .coins(50)),
        .init(id: "sunglasses", name: "Sunglasses", slot: .face, unlock: .coins(90)),
        .init(id: "star-glasses", name: "Star glasses", slot: .face, unlock: .level(10)),
        .init(id: "bow-tie", name: "Bow tie", slot: .neck, unlock: .coins(40)),
        .init(id: "scarf", name: "Scarf", slot: .neck, unlock: .coins(70)),
        .init(id: "medal", name: "Gold medal", slot: .neck, unlock: .achievement("collector")),
        .init(id: "mint", name: "Mint", slot: .background, unlock: .free),
        .init(id: "sunset", name: "Sunset", slot: .background, unlock: .coins(60)),
        .init(id: "night-sky", name: "Night sky", slot: .background, unlock: .coins(100)),
        .init(id: "beach", name: "Beach", slot: .background, unlock: .coins(150)),
        .init(id: "confetti", name: "Confetti", slot: .background, unlock: .achievement("four-figures")),
    ]
    public static func named(_ id: String?) -> PetItem? { catalog.first { $0.id == id } }

    /// How to get it, e.g. "40 coins", "Level 15", "Achievement: On a roll".
    public var requirement: String {
        switch unlock {
        case .free: return "Free"
        case .coins(let price): return "\(price) coins"
        case .level(let level): return "Level \(level)"
        case .achievement(let id): return "Badge: " + (PetProgress(shifts: []).achievements.first { $0.id == id }?.title ?? id)
        }
    }
}

/// What's been bought and what Penny is wearing. Kept on the phone, per account.
public struct PetCloset: Codable, Equatable, Sendable {
    public var bought: Set<String> = []
    public var spent = 0
    public var outfit: [PetSlot: String] = [.background: "mint"]
    public init() {}

    public func balance(_ pet: PetProgress) -> Int { max(0, pet.coinsEarned - spent) }

    public func owns(_ item: PetItem, _ pet: PetProgress) -> Bool {
        switch item.unlock {
        case .free: return true
        case .coins: return bought.contains(item.id)
        case .level(let level): return pet.level >= level
        case .achievement(let id): return pet.hasAchievement(id)
        }
    }

    public func wearing(_ slot: PetSlot, _ pet: PetProgress) -> PetItem? {
        guard let item = PetItem.named(outfit[slot]), owns(item, pet) else { return nil }
        return item
    }

    public enum ClosetError: Error, Equatable { case notEnoughCoins(needed: Int), locked }

    /// Buys a coin item with the coins available and puts it on.
    public mutating func buy(_ item: PetItem, _ pet: PetProgress) throws {
        guard case .coins(let price) = item.unlock else { throw ClosetError.locked }
        guard !bought.contains(item.id) else { outfit[item.slot] = item.id; return }
        let available = balance(pet)
        guard available >= price else { throw ClosetError.notEnoughCoins(needed: price - available) }
        bought.insert(item.id); spent += price; outfit[item.slot] = item.id
    }

    /// Puts on an item already owned, or takes it off if it's being worn.
    public mutating func toggle(_ item: PetItem, _ pet: PetProgress) throws {
        guard owns(item, pet) else { throw ClosetError.locked }
        if outfit[item.slot] == item.id, item.slot != .background { outfit[item.slot] = nil } else { outfit[item.slot] = item.id }
    }
}
