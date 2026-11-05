import XCTest
@testable import HowMuchCore

final class PetTests: XCTestCase {
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; calendar.firstWeekday = 2; return calendar }
    /// Wednesday 4 Nov 2026, noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))! }
    private func shift(_ day: String, paid: Bool = false, due: String? = nil) throws -> Shift {
        try Shift(event: "Roadshow", day: day, startMinute: 9 * 60, endMinute: 18 * 60, rate: 20, paid: paid, paymentDue: due)
    }

    func testANewAccountStartsAsASleepyEgg() {
        let pet = PetProgress(shifts: [], now: now, calendar: calendar)
        XCTAssertEqual(pet.stage, .egg)
        XCTAssertEqual(pet.mood, .sleepy)
        XCTAssertEqual(pet.xpToNext, 30)
        XCTAssertEqual(pet.message(name: "Penny", currency: "SGD"), "Penny is napping. Book your next shift to wake Penny up.")
    }

    func testWorkedAndPaidShiftsGrowThePet() throws {
        // 3 worked (30 XP) + 2 paid (30 XP) = 60 XP: a hatchling, 90 XP from coinling.
        let shifts = [try shift("2026-11-02", paid: true), try shift("2026-11-03", paid: true), try shift("2026-11-04"), try shift("2026-11-20")]
        let pet = PetProgress(shifts: shifts, now: calendar.date(byAdding: .hour, value: 8, to: now)!, calendar: calendar)
        XCTAssertEqual(pet.xp, 60)
        XCTAssertEqual(pet.stage, .hatchling)
        XCTAssertEqual(pet.coins, 2)
        XCTAssertEqual(pet.xpToNext, 90)
        XCTAssertEqual(pet.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(pet.mood, .happy)
    }

    func testOverduePayMakesThePetWorried() throws {
        let pet = PetProgress(shifts: [try shift("2026-10-01", due: "2026-10-15"), try shift("2026-11-03")], now: now, calendar: calendar)
        XCTAssertEqual(pet.mood, .worried)
        XCTAssertEqual(pet.overdue, 180)
        XCTAssertTrue(pet.message(name: "Penny", currency: "SGD").contains("SGD 180 of pay is overdue"))
    }

    func testStreakCountsWeeksInARowWithShifts() throws {
        let shifts = [try shift("2026-11-03"), try shift("2026-10-28"), try shift("2026-10-21"), try shift("2026-10-07")]
        XCTAssertEqual(PetProgress(shifts: shifts, now: now, calendar: calendar).streakWeeks, 3)
    }

    func testFiftyPaidShiftsMakeAGoldenCoin() throws {
        var shifts: [Shift] = []
        for offset in 1...21 { shifts.append(try shift(Shift.dayString(calendar.date(byAdding: .day, value: -offset, to: now)!), paid: true)) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.xp, 525)
        XCTAssertEqual(pet.stage, .golden)
        XCTAssertNil(pet.next)
        XCTAssertEqual(pet.progress, 1)
    }

    func testLevelsKeepGoingAfterTheGoldenCoin() throws {
        var shifts: [Shift] = []
        for offset in 1...30 { shifts.append(try shift(Shift.dayString(calendar.date(byAdding: .day, value: -offset, to: now)!), paid: true)) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.stage, .golden)
        XCTAssertEqual(pet.xp, 750)
        XCTAssertEqual(pet.level, 19)
        XCTAssertEqual(pet.xpToNextLevel, 10)
        XCTAssertEqual(pet.message(name: "Penny", currency: "SGD"), "Penny is happy! 10 XP to level 20.")
    }

    func testCoinsComeFromShiftsAndAchievements() throws {
        // 2 worked (10) + 1 paid (10) + badges: First shift, Payday (50) = 70 coins.
        let shifts = [try shift("2026-11-02", paid: true), try shift("2026-11-03")]
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(Set(pet.achievements.filter(\.earned).map(\.id)), ["first-shift", "payday"])
        XCTAssertEqual(pet.coinsEarned, 70)
    }

    func testBestStreakAndShiftTimeBadges() throws {
        let night = try Shift(event: "Gala", day: "2026-10-20", startMinute: 20 * 60, endMinute: 2 * 60, rate: 20)
        let early = try Shift(event: "Setup", day: "2026-10-27", startMinute: 6 * 60, endMinute: 12 * 60, rate: 20)
        let shifts = [night, early, try shift("2026-10-13"), try shift("2026-10-06"), try shift("2026-09-01")]
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.bestStreakWeeks, 4)
        XCTAssertEqual(pet.streakWeeks, 0)
        XCTAssertTrue(pet.hasAchievement("on-a-roll"))
        XCTAssertTrue(pet.hasAchievement("night-owl"))
        XCTAssertTrue(pet.hasAchievement("early-bird"))
    }

    func testWardrobeBuyingSpendsCoinsAndUnlocksAreEarned() throws {
        let shifts = try (1...8).map { try shift(Shift.dayString(calendar.date(byAdding: .day, value: -$0, to: now)!), paid: true) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        var closet = PetCloset()
        let start = closet.balance(pet)
        let partyHat = PetItem.named("party-hat")!
        try closet.buy(partyHat, pet)
        XCTAssertEqual(closet.balance(pet), start - 40)
        XCTAssertEqual(closet.wearing(.hat, pet), partyHat)
        try closet.toggle(partyHat, pet)
        XCTAssertNil(closet.wearing(.hat, pet))
        XCTAssertThrowsError(try closet.toggle(PetItem.named("royal-crown")!, pet)) // level 15 needed
        XCTAssertEqual(closet.wearing(.background, pet)?.id, "mint")
        var broke = PetCloset(); broke.spent = pet.coinsEarned
        XCTAssertThrowsError(try broke.buy(PetItem.named("wizard-hat")!, pet)) { error in
            XCTAssertEqual(error as? PetCloset.ClosetError, .notEnoughCoins(needed: 200))
        }
        let saved = try JSONDecoder().decode(PetCloset.self, from: JSONEncoder().encode(closet))
        XCTAssertEqual(saved, closet)
    }

    func testAccountSettingsTravelWithTheAccountAsPlainJSON() throws {
        var settings = AppPreferences()
        var closet = PetCloset(); closet.bought = ["party-hat"]; closet.spent = 40; closet.outfit["hat"] = "party-hat"
        settings.pet = PetPreferences(name: "Coco", closet: closet)
        var live = LiveShiftPreferences(); live.lockScreen = false
        for _ in 0..<305 { live.confirm(UUID()) }
        settings.liveShift = live
        var previews = WidgetPreviewPreferences(); previews.showPay = true
        settings.widgetPreview = previews
        XCTAssertEqual(live.confirmedFinishes?.count, 300)
        XCTAssertNoThrow(try settings.validate())
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        let outfit = ((json["pet"] as? [String: Any])?["closet"] as? [String: Any])?["outfit"] as? [String: String]
        XCTAssertEqual(outfit?["hat"], "party-hat") // an object the server can read, not a key/value array
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.pet?.displayName, "Coco")
        XCTAssertFalse(decoded.liveShift!.showsOnLockScreen)
        // Accounts saved before 1.1 have none of these and keep the defaults.
        let older = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"displayName":"A","defaultBreakMinutes":0,"defaultBreakPaid":false,"eventRates":{},"payers":{},"remindersEnabled":false,"reminderMinute":1200}"#.utf8))
        XCTAssertNil(older.pet)
        XCTAssertEqual(PetPreferences().displayName, "Penny")
        XCTAssertTrue(LiveShiftPreferences().showsOnLockScreen)
        var tooLong = AppPreferences(); tooLong.pet = PetPreferences(name: String(repeating: "x", count: 41))
        XCTAssertThrowsError(try tooLong.validate())
    }

    func testPioneersGetABadgeAndTheirOwnSkin() throws {
        let shifts = [try shift("2026-11-02")]
        let pioneer = PetProgress(shifts: shifts, now: now, calendar: calendar, pioneer: true)
        let later = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertTrue(pioneer.hasAchievement("pioneer"))
        XCTAssertFalse(later.achievements.contains { $0.id == "pioneer" }) // never shown as a locked badge
        XCTAssertEqual(pioneer.coinsEarned, later.coinsEarned + PetProgress.coinsPerAchievement)
        let skin = PetItem.named("pioneer")!
        XCTAssertTrue(skin.pioneerOnly)
        var closet = PetCloset()
        try closet.toggle(skin, pioneer)
        XCTAssertEqual(closet.wearing(.skin, pioneer), skin)
        XCTAssertNil(closet.wearing(.skin, later))
        XCTAssertThrowsError(try closet.toggle(skin, later))
        var preferences = AppPreferences(); preferences.pet = PetPreferences(closet: closet)
        XCTAssertNoThrow(try preferences.validate())
    }

    func testNewSkinsUnlockWithCoinsLevelsAndBadges() throws {
        let skins = PetItem.catalog.filter { $0.slot == .skin }.map(\.id)
        XCTAssertEqual(skins, ["classic", "pioneer", "rose-gold", "silver", "matcha", "sakura", "midnight", "rainbow"])
        let shifts = try (1...10).map { try shift(Shift.dayString(calendar.date(byAdding: .day, value: -$0, to: now)!)) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        var closet = PetCloset()
        XCTAssertTrue(closet.owns(PetItem.named("rainbow")!, pet)) // the Regular badge: 10 shifts
        XCTAssertFalse(closet.owns(PetItem.named("midnight")!, pet)) // level 8 needed
        try closet.buy(PetItem.named("rose-gold")!, pet)
        XCTAssertEqual(closet.wearing(.skin, pet)?.id, "rose-gold")
        XCTAssertFalse(PetItem.named("rose-gold")!.pioneerOnly)
    }
}
