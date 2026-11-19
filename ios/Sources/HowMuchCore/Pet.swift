import Foundation

/// HowMuch's pet: a little coin creature that grows as shifts are worked and paid, in the style of a
/// daily-habit pet: XP and stages, a mood that drops when you go quiet, a streak, weekly missions and coins
/// to spend in a shop that opens up as Penny grows. Everything is worked out from the shifts already in the
/// account, so nothing extra is stored or synced, and it can't drift between iPhones.
public struct PetProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Comparable, Sendable {
        case egg, hatchling, coinling, golden, treasure
        /// Experience needed to reach this stage.
        public var threshold: Int { [0, 60, 300, 900, 2000][rawValue] }
        public var title: String { ["Egg", "Hatchling", "Coinling", "Golden coin", "Treasure"][rawValue] }
        public var next: Stage? { Stage(rawValue: rawValue + 1) }
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        public static func of(xp: Int) -> Stage { allCases.last { xp >= $0.threshold } ?? .egg }
    }

    public enum Mood: String, Sendable {
        case thriving, happy, okay, hungry, sad, worried
        public var label: String {
            switch self {
            case .thriving: "Thriving"
            case .happy: "Happy"
            case .okay: "Peckish"
            case .hungry: "Hungry"
            case .sad: "Lonely"
            case .worried: "Worried"
            }
        }
    }

    // MARK: Rules
    public static let xpPerWorkedShift = 10
    /// On top of the shift XP, once per day with a shift worked.
    public static let xpPerWorkedDay = 15
    public static let xpPerPaidShift = 15
    public static let coinsPerWorkedShift = 5
    public static let coinsPerPaidShift = 10
    /// A week with 3 or more shifts worked.
    public static let busyWeekShifts = 3, coinsBusyWeek = 10
    /// Every 4th week in a row with a shift worked.
    public static let streakMilestone = 4, coinsStreakMilestone = 25
    public static let coinsPerAchievement = 25

    public let xp: Int
    public let stage: Stage
    public let mood: Mood
    /// Weeks in a row with a shift worked, counting this week or last week (this week isn't over yet).
    public let streakWeeks: Int
    /// The longest run of weeks in a row with a shift worked, ever.
    public let bestStreakWeeks: Int
    /// Days with at least one shift worked.
    public let daysWorked: Int
    public let shiftsWorked: Int
    /// Days since the last shift finished; nil before the first one.
    public let daysSinceLastShift: Int?
    /// Overdue pay in the main currency.
    public let overdue: Decimal
    /// Overdue pay in every currency, never added together.
    public let overdueByCurrency: [String: Decimal]
    public let coinsEarned: Int
    public let achievements: [PetAchievement]
    /// One of the people building HowMuch: every item in the wardrobe is theirs.
    public let developer: Bool
    /// Items unlocked with gift codes (kept on the server, so they can't be typed into the account).
    public let unlocked: Set<String>
    /// This week's missions. The rewards are the same coins the rules above pay out, shown as goals.
    public let missions: [PetMission]

    public var next: Stage? { stage.next }
    /// 0...1 progress from this stage to the next (1 at the last stage).
    public var progress: Double {
        guard let next else { return 1 }
        return min(max(Double(xp - stage.threshold) / Double(next.threshold - stage.threshold), 0), 1)
    }
    public var xpToNext: Int? { next.map { max($0.threshold - xp, 0) } }

    /// Levels never run out, but each one takes a little longer: level n needs 20·(n−1)² XP.
    public var level: Int { 1 + Int((Double(xp) / 20).squareRoot()) }
    private static func xpFor(level: Int) -> Int { 20 * (level - 1) * (level - 1) }
    public var levelProgress: Double {
        let from = Self.xpFor(level: level), to = Self.xpFor(level: level + 1)
        return Double(xp - from) / Double(to - from)
    }
    public var xpToNextLevel: Int { Self.xpFor(level: level + 1) - xp }

    public func hasAchievement(_ id: String) -> Bool { achievements.contains { $0.id == id && $0.earned } }

    /// `pioneer`: the account was made before HowMuch's official launch.
    /// `currency`: the person's main currency; money badges only count pay in it. Defaults to the most used one.
    public init(shifts: [Shift], now: Date = Date(), calendar: Calendar = TrackerCalendar.calendar, pioneer: Bool = false, developer: Bool = false, unlocked: Set<String> = [], currency: String? = nil, bonusCoins: Int = 0) {
        self.developer = developer
        self.unlocked = unlocked
        let main = currency ?? Dictionary(grouping: shifts, by: \.currency).max { $0.value.count < $1.value.count }?.key ?? "SGD"
        let worked = shifts.filter { $0.endDate <= now }
        let paid = worked.filter(\.paid)
        let workedDays = Set(worked.map(\.day))
        shiftsWorked = worked.count
        daysWorked = workedDays.count
        let points = worked.count * Self.xpPerWorkedShift + workedDays.count * Self.xpPerWorkedDay + paid.count * Self.xpPerPaidShift
        var coins = worked.count * Self.coinsPerWorkedShift + paid.count * Self.coinsPerPaidShift

        // Weeks worked: streaks, busy-week bonuses and streak milestones.
        func weekStart(_ date: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
        let perWeek = Dictionary(grouping: worked, by: { weekStart($0.startDate) }).mapValues(\.count)
        var best = 0, run = 0
        var previous: Date?
        for week in perWeek.keys.sorted() {
            if let previous, calendar.date(byAdding: .weekOfYear, value: 1, to: previous) == week { run += 1 } else { run = 1 }
            if run % Self.streakMilestone == 0 { coins += Self.coinsStreakMilestone }
            if (perWeek[week] ?? 0) >= Self.busyWeekShifts { coins += Self.coinsBusyWeek }
            best = max(best, run); previous = week
        }
        bestStreakWeeks = best
        let thisWeek = weekStart(now)
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        streakWeeks = previous == thisWeek || previous == lastWeek ? run : 0

        let today = Shift.dayString(now)
        let late = worked.filter { !$0.paid && ($0.paymentDue ?? "9999-12-31") < today }
        // Never add different currencies together.
        overdueByCurrency = Dictionary(grouping: late, by: \.currency).mapValues { $0.reduce(Decimal(0)) { $0 + $1.total } }
        overdue = overdueByCurrency[main] ?? 0

        // Mood: how long since the last shift, lifted by a shift coming up, and worried while pay is overdue.
        let since = worked.map(\.endDate).max().map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: now)).day ?? 0 }
        daysSinceLastShift = since
        let week: TimeInterval = 7 * 24 * 60 * 60
        let comingUp = shifts.contains { ($0.startDate > now && $0.startDate.timeIntervalSince(now) <= week) || ($0.startDate <= now && now < $0.endDate) }
        var feeling: Mood
        switch since {
        case nil: feeling = .okay
        case .some(0...3): feeling = streakWeeks >= 3 ? .thriving : .happy
        case .some(4...7): feeling = .happy
        case .some(8...14): feeling = .okay
        case .some(15...30): feeling = .hungry
        default: feeling = .sad
        }
        if comingUp, [.okay, .hungry, .sad].contains(feeling) { feeling = .happy }
        mood = late.isEmpty ? feeling : .worried

        let paidTotal = paid.filter { $0.currency == main }.reduce(Decimal(0)) { $0 + $1.total }
        var list: [PetAchievement] = developer
            ? [.init(id: "developer", title: "Developer", detail: "Builds HowMuch", symbol: "hammer.circle.fill", current: 1, target: 1)] : []
        if pioneer { list.append(.init(id: "pioneer", title: "Pioneer", detail: "Joined HowMuch before launch", symbol: "star.circle.fill", current: 1, target: 1)) }
        list += [
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
        coins += list.filter(\.earned).count * Self.coinsPerAchievement
        // Coins from outside the shifts, such as hellos from friends (kept on the server).
        coinsEarned = coins + max(bonusCoins, 0)
        xp = points
        stage = Stage.of(xp: points)

        // This week's missions.
        let workedThisWeek = worked.filter { weekStart($0.startDate) == thisWeek }.count
        let bookedThisWeek = shifts.filter { $0.endDate > now && weekStart($0.startDate) == thisWeek }.count
        let unpaid = worked.filter { !$0.paid }.count
        let busy = Self.busyWeekShifts
        var list2: [PetMission] = []
        list2.append(PetMission(id: "work", title: "Work a shift this week", symbol: "briefcase", reward: Self.coinsPerWorkedShift, done: workedThisWeek > 0,
                                detail: workedThisWeek > 0 ? "Done! Coins added" : bookedThisWeek > 0 ? "Booked. Coins arrive when it's done" : "Book a shift to start"))
        list2.append(PetMission(id: "busy", title: "Work \(busy) shifts this week", symbol: "list.number", reward: Self.coinsBusyWeek, done: workedThisWeek >= busy,
                                detail: workedThisWeek >= busy ? "Done! Busy-week bonus added"
                                    : "\(workedThisWeek) of \(busy) worked" + (bookedThisWeek > 0 ? ", \(bookedThisWeek) more booked" : "")))
        list2.append(PetMission(id: "paid", title: "Mark finished shifts paid", symbol: "checkmark.seal", reward: Self.coinsPerPaidShift, done: worked.count > 0 && unpaid == 0,
                                detail: worked.isEmpty ? "Coins for every shift that's paid"
                                    : unpaid == 0 ? "All caught up" : "\(unpaid) waiting for pay, \(Self.coinsPerPaidShift) coins each"))
        list2.append(PetMission(id: "streak", title: "Reach a \(Self.streakMilestone)-week streak", symbol: "flame", reward: Self.coinsStreakMilestone, done: streakWeeks >= Self.streakMilestone,
                                detail: streakWeeks >= Self.streakMilestone ? "Done! \(Self.coinsStreakMilestone) more every \(Self.streakMilestone) weeks in a row"
                                    : "\(streakWeeks) of \(Self.streakMilestone) weeks in a row"))
        missions = list2
    }

    /// What the pet says, on Overview and in its speech bubble.
    public func message(name: String, currency: String) -> String {
        switch mood {
        case .worried:
            let amounts = overdueByCurrency.sorted { ($0.key == currency ? "" : $0.key) < ($1.key == currency ? "" : $1.key) }
                .map { SpokenSummary.amount($0.value, $0.key) }
            let total = amounts.count > 1 ? amounts.dropLast().joined(separator: ", ") + " and " + amounts.last! : amounts.first ?? SpokenSummary.amount(overdue, currency)
            return "\(name) is worried: \(total) of pay is overdue. Chase it up and mark it paid to cheer \(name) up."
        case .thriving: return "On a roll! \(streakWeeks) weeks in a row. Keep the streak going."
        case .happy:
            if shiftsWorked == 0 { return "A shift is coming up! Work it to hatch \(name)." }
            if let xpToNext, let next { return "Fed and happy! \(xpToNext) XP until \(name) becomes a \(next.title.lowercased())." }
            return "Fed and happy! \(xpToNextLevel) XP to level \(level + 1)."
        case .okay:
            return shiftsWorked == 0 ? "Add and work your first shift to hatch \(name)." : "Feeling peckish. Book a shift to feed \(name)."
        case .hungry: return "\(name) is hungry… it's been \(daysSinceLastShift ?? 0) days since your last shift."
        case .sad: return "\(name) misses you. Book a shift to cheer \(name) up."
        }
    }
}

/// One of the week's goals on Penny's page.
public struct PetMission: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let reward: Int
    public let done: Bool
    public var detail: String?
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

/// Things Penny can wear. Most are bought with coins once Penny has grown enough; a few come with a badge.
public enum PetSlot: String, CaseIterable, Codable, Sendable {
    case hat, face, neck, background, skin
    public var title: String { ["Hats", "Glasses", "Neckwear", "Scenes", "Skins"][Self.allCases.firstIndex(of: self)!] }
}

public struct PetItem: Identifiable, Equatable, Sendable {
    public enum Unlock: Equatable, Sendable { case free, coins(Int), achievement(String), code }
    public let id: String
    public let name: String
    public let slot: PetSlot
    public let unlock: Unlock
    /// How grown Penny has to be before it can be bought.
    public let stage: PetProgress.Stage

    init(id: String, name: String, slot: PetSlot, unlock: Unlock, stage: PetProgress.Stage = .egg) {
        self.id = id; self.name = name; self.slot = slot; self.unlock = unlock; self.stage = stage
    }

    public static let catalog: [PetItem] = [
        .init(id: "party-hat", name: "Party hat", slot: .hat, unlock: .coins(40)),
        .init(id: "straw-hat", name: "Straw sun hat", slot: .hat, unlock: .coins(50), stage: .hatchling),
        .init(id: "beanie", name: "Cosy beanie", slot: .hat, unlock: .coins(60), stage: .hatchling),
        .init(id: "cap", name: "Jade cap", slot: .hat, unlock: .coins(80), stage: .coinling),
        .init(id: "beret", name: "Artist's beret", slot: .hat, unlock: .coins(90), stage: .coinling),
        .init(id: "headphones", name: "Headphones", slot: .hat, unlock: .coins(110), stage: .coinling),
        .init(id: "chef-hat", name: "Chef's hat", slot: .hat, unlock: .coins(120), stage: .coinling),
        .init(id: "wizard-hat", name: "Wizard hat", slot: .hat, unlock: .coins(200), stage: .golden),
        .init(id: "top-hat", name: "Top hat", slot: .hat, unlock: .coins(260), stage: .golden),
        .init(id: "flower", name: "Flower", slot: .hat, unlock: .achievement("on-a-roll")),
        .init(id: "hard-hat", name: "Hard hat", slot: .hat, unlock: .achievement("veteran")),
        .init(id: "royal-crown", name: "Royal crown", slot: .hat, unlock: .coins(400), stage: .treasure),
        .init(id: "round-glasses", name: "Round glasses", slot: .face, unlock: .coins(50), stage: .hatchling),
        .init(id: "square-specs", name: "Square specs", slot: .face, unlock: .coins(60), stage: .hatchling),
        .init(id: "sunglasses", name: "Cool shades", slot: .face, unlock: .coins(90), stage: .coinling),
        .init(id: "monocle", name: "Monocle", slot: .face, unlock: .coins(120), stage: .coinling),
        .init(id: "star-glasses", name: "Star glasses", slot: .face, unlock: .coins(150), stage: .golden),
        .init(id: "visor", name: "Pixel visor", slot: .face, unlock: .coins(220), stage: .golden),
        .init(id: "sleep-mask", name: "Sleep mask", slot: .face, unlock: .achievement("night-owl")),
        .init(id: "bow-tie", name: "Bow tie", slot: .neck, unlock: .coins(40)),
        .init(id: "necktie", name: "Office tie", slot: .neck, unlock: .coins(60), stage: .hatchling),
        .init(id: "scarf", name: "Red scarf", slot: .neck, unlock: .coins(70), stage: .hatchling),
        .init(id: "bandana", name: "Bandana", slot: .neck, unlock: .coins(90), stage: .coinling),
        .init(id: "pearls", name: "Pearl necklace", slot: .neck, unlock: .coins(160), stage: .golden),
        .init(id: "gold-chain", name: "Gold chain", slot: .neck, unlock: .coins(300), stage: .treasure),
        .init(id: "lanyard", name: "Crew lanyard", slot: .neck, unlock: .achievement("first-shift")),
        .init(id: "medal", name: "Gold medal", slot: .neck, unlock: .achievement("collector")),
        .init(id: "mint", name: "Mint room", slot: .background, unlock: .free),
        .init(id: "sunset", name: "Sunset", slot: .background, unlock: .coins(60), stage: .hatchling),
        .init(id: "rainy-day", name: "Rainy day", slot: .background, unlock: .coins(80), stage: .hatchling),
        .init(id: "night-sky", name: "Starry night", slot: .background, unlock: .coins(100), stage: .coinling),
        .init(id: "snowfall", name: "Snowfall", slot: .background, unlock: .coins(140), stage: .coinling),
        .init(id: "beach", name: "Beach day", slot: .background, unlock: .coins(150), stage: .coinling),
        .init(id: "city-lights", name: "City lights", slot: .background, unlock: .coins(220), stage: .golden),
        .init(id: "vault", name: "Coin vault", slot: .background, unlock: .coins(350), stage: .treasure),
        .init(id: "sunrise", name: "Sunrise", slot: .background, unlock: .achievement("early-bird")),
        .init(id: "confetti", name: "Confetti", slot: .background, unlock: .achievement("four-figures")),
        .init(id: "classic", name: "Classic gold", slot: .skin, unlock: .free),
        .init(id: "pioneer", name: "Pioneer", slot: .skin, unlock: .achievement("pioneer")),
        .init(id: "rose-gold", name: "Rose gold", slot: .skin, unlock: .coins(80), stage: .hatchling),
        .init(id: "copper", name: "Copper", slot: .skin, unlock: .coins(90), stage: .hatchling),
        .init(id: "bubblegum", name: "Bubblegum", slot: .skin, unlock: .coins(100), stage: .hatchling),
        .init(id: "silver", name: "Silver", slot: .skin, unlock: .coins(120), stage: .coinling),
        .init(id: "matcha", name: "Matcha", slot: .skin, unlock: .coins(150), stage: .coinling),
        .init(id: "ocean", name: "Ocean", slot: .skin, unlock: .coins(180), stage: .golden),
        .init(id: "sakura", name: "Sakura", slot: .skin, unlock: .coins(200), stage: .golden),
        .init(id: "midnight", name: "Midnight", slot: .skin, unlock: .coins(250), stage: .golden),
        .init(id: "lava", name: "Lava", slot: .skin, unlock: .coins(320), stage: .treasure),
        .init(id: "rainbow", name: "Rainbow", slot: .skin, unlock: .achievement("regular")),
        .init(id: "blaze", name: "Blaze", slot: .skin, unlock: .achievement("unstoppable")),
        .init(id: "terminal", name: "Terminal", slot: .skin, unlock: .achievement("developer")),
        .init(id: "holo", name: "Holographic", slot: .skin, unlock: .achievement("developer")),
        // Gift-code specials: only from a code (or for developers).
        .init(id: "halo", name: "Golden halo", slot: .hat, unlock: .code),
        .init(id: "heart-glasses", name: "Heart glasses", slot: .face, unlock: .code),
        .init(id: "lei", name: "Flower lei", slot: .neck, unlock: .code),
        .init(id: "fireworks", name: "Fireworks", slot: .background, unlock: .code),
        .init(id: "galaxy", name: "Galaxy", slot: .skin, unlock: .code),
        .init(id: "bunny-ears", name: "Bunny ears", slot: .hat, unlock: .code),
        .init(id: "3d-glasses", name: "3D glasses", slot: .face, unlock: .code),
        .init(id: "bell-collar", name: "Lucky bell", slot: .neck, unlock: .code),
        .init(id: "aurora", name: "Aurora", slot: .background, unlock: .code),
        .init(id: "frost", name: "Frost", slot: .skin, unlock: .code),
    ]
    /// Only for people who joined before launch: hidden from everyone else.
    public var pioneerOnly: Bool { unlock == .achievement("pioneer") }
    /// Only for pioneers or developers: hidden from everyone else.
    public var exclusive: Bool { unlock == .achievement("pioneer") || unlock == .achievement("developer") || unlock == .code }
    public static func named(_ id: String?) -> PetItem? { catalog.first { $0.id == id } }
    public var price: Int? { if case .coins(let price) = unlock { return price }; return nil }

    /// How to get it, e.g. "40 coins", "Badge: On a roll".
    public var requirement: String {
        switch unlock {
        case .free: return "Free"
        case .coins(let price): return "\(price) coins"
        case .achievement(let id): return "Badge: " + (PetProgress(shifts: []).achievements.first { $0.id == id }?.title ?? id)
        case .code: return "Gift code"
        }
    }
}

/// What's been bought and what Penny is wearing. Synced with the account.
public struct PetCloset: Codable, Equatable, Sendable {
    public var bought: Set<String> = []
    public var spent = 0
    /// Item id worn in each slot, keyed by `PetSlot.rawValue` so it stays a plain JSON object.
    public var outfit: [String: String] = [PetSlot.background.rawValue: "mint"]
    public init() {}

    /// Coins left to spend. It can drop below zero when coins are taken back (a shift deleted or marked
    /// unpaid) after they were spent; Penny's page explains that rather than hiding it.
    public func balance(_ pet: PetProgress) -> Int { pet.coinsEarned - spent }

    public func owns(_ item: PetItem, _ pet: PetProgress) -> Bool {
        // Developers have the whole wardrobe: every hat, pair of glasses, neckwear, scene and skin.
        if pet.developer || pet.unlocked.contains(item.id) { return true }
        switch item.unlock {
        case .free: return true
        case .coins: return bought.contains(item.id)
        case .achievement(let id): return pet.hasAchievement(id)
        case .code: return false
        }
    }

    /// Not yet for sale: Penny hasn't grown enough.
    public func locked(_ item: PetItem, _ pet: PetProgress) -> Bool { !owns(item, pet) && pet.stage < item.stage }

    public func wearing(_ slot: PetSlot, _ pet: PetProgress) -> PetItem? {
        guard let item = PetItem.named(outfit[slot.rawValue]), owns(item, pet) else { return nil }
        return item
    }

    public enum ClosetError: Error, Equatable { case notEnoughCoins(needed: Int), locked }

    /// Buys a coin item with the coins available and puts it on.
    public mutating func buy(_ item: PetItem, _ pet: PetProgress) throws {
        guard case .coins(let price) = item.unlock else { throw ClosetError.locked }
        guard !bought.contains(item.id) else { outfit[item.slot.rawValue] = item.id; return }
        guard pet.stage >= item.stage else { throw ClosetError.locked }
        let available = balance(pet)
        guard available >= price else { throw ClosetError.notEnoughCoins(needed: price - available) }
        bought.insert(item.id); spent += price; outfit[item.slot.rawValue] = item.id
    }

    /// Puts on an item already owned, or takes it off if it's being worn.
    public mutating func toggle(_ item: PetItem, _ pet: PetProgress) throws {
        guard owns(item, pet) else { throw ClosetError.locked }
        if outfit[item.slot.rawValue] == item.id, item.slot != .background { outfit[item.slot.rawValue] = nil } else { outfit[item.slot.rawValue] = item.id }
    }
}

/// Penny's settings, synced with the account.
public struct PetPreferences: Codable, Equatable, Sendable {
    public var name: String?
    public var closet: PetCloset?
    public init(name: String? = nil, closet: PetCloset? = nil) { self.name = name; self.closet = closet }
    public var displayName: String { (name ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Penny" : name! }
    func validate() throws {
        guard (name ?? "").count <= 40, (closet?.bought.count ?? 0) <= 200, (closet?.spent ?? 0) >= 0, (closet?.outfit.count ?? 0) <= PetSlot.allCases.count else {
            throw TrackerError.invalid("Penny's settings couldn't be saved.")
        }
    }
}

/// Live shift choices, synced with the account so every iPhone signed in behaves the same.
public struct LiveShiftPreferences: Codable, Equatable, Sendable {
    public var lockScreen: Bool?
    public var askFinish: Bool?
    /// Shifts whose finishing time was already confirmed (most recent last).
    public var confirmedFinishes: [UUID]?
    public init() {}
    public var showsOnLockScreen: Bool { lockScreen ?? true }
    public var asksFinishTime: Bool { askFinish ?? true }
    public var confirmed: Set<UUID> { Set(confirmedFinishes ?? []) }
    public mutating func confirm(_ id: UUID) {
        var list = (confirmedFinishes ?? []).filter { $0 != id }
        list.append(id)
        confirmedFinishes = Array(list.suffix(300))
    }
    func validate() throws {
        guard (confirmedFinishes?.count ?? 0) <= 300 else { throw TrackerError.invalid("Too many confirmed finish times.") }
    }
}

/// Settings → Widgets preview toggles.
public struct WidgetPreviewPreferences: Codable, Equatable, Sendable {
    public var showPay: Bool?
    public var showLocation: Bool?
    public init() {}
}
