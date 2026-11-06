import XCTest
@testable import HowMuchCore

final class PetTests: XCTestCase {
    private var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; calendar.firstWeekday = 2; return calendar }
    /// Wednesday 4 Nov 2026, noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))! }
    private func shift(_ day: String, paid: Bool = false, due: String? = nil) throws -> Shift {
        try Shift(event: "Roadshow", day: day, startMinute: 9 * 60, endMinute: 18 * 60, rate: 20, paid: paid, paymentDue: due)
    }

    private func daysAgo(_ n: Int) -> String { Shift.dayString(calendar.date(byAdding: .day, value: -n, to: now)!) }

    func testANewAccountStartsAsAnEggWithMissions() {
        let pet = PetProgress(shifts: [], now: now, calendar: calendar)
        XCTAssertEqual(pet.stage, .egg)
        XCTAssertEqual(pet.mood, .okay)
        XCTAssertEqual(pet.mood.label, "Peckish")
        XCTAssertEqual(pet.xpToNext, 60)
        XCTAssertEqual(pet.level, 1)
        XCTAssertEqual(pet.message(name: "Penny", currency: "SGD"), "Add and work your first shift to hatch Penny.")
        XCTAssertEqual(pet.missions.map(\.id), ["work", "busy", "paid", "streak"])
        XCTAssertFalse(pet.missions.contains(where: \.done))
    }

    func testWorkedDaysAndPaidShiftsGrowThePet() throws {
        // 3 shifts (30 XP) on 3 days (45 XP), 2 paid (30 XP) = 105 XP: a hatchling, 195 XP from coinling.
        let shifts = [try shift("2026-11-02", paid: true), try shift("2026-11-03", paid: true), try shift("2026-11-04"), try shift("2026-11-20")]
        let pet = PetProgress(shifts: shifts, now: calendar.date(byAdding: .hour, value: 8, to: now)!, calendar: calendar)
        XCTAssertEqual(pet.xp, 105)
        XCTAssertEqual(pet.stage, .hatchling)
        XCTAssertEqual(pet.xpToNext, 195)
        XCTAssertEqual(pet.progress, 0.1875, accuracy: 0.001)
        XCTAssertEqual(pet.mood, .happy)
        XCTAssertEqual(pet.daysWorked, 3)
        // 3 worked (15) + 2 paid (20) + a busy week (10) + First shift and Payday badges (50).
        XCTAssertEqual(pet.coinsEarned, 95)
        let done = Dictionary(uniqueKeysWithValues: pet.missions.map { ($0.id, $0.done) })
        XCTAssertEqual(done, ["work": true, "busy": true, "paid": false, "streak": false])
        XCTAssertEqual(pet.missions.first { $0.id == "paid" }?.detail, "1 waiting for pay, 10 coins each")
    }

    func testOverduePayMakesThePetWorried() throws {
        let pet = PetProgress(shifts: [try shift("2026-10-01", due: "2026-10-15"), try shift("2026-11-03")], now: now, calendar: calendar)
        XCTAssertEqual(pet.mood, .worried)
        XCTAssertEqual(pet.overdue, 180)
        XCTAssertTrue(pet.message(name: "Penny", currency: "SGD").contains("SGD 180 of pay is overdue"))
    }

    func testStreakCountsWorkedWeeksUpToThisWeekOrLast() throws {
        let shifts = [try shift("2026-11-03"), try shift("2026-10-28"), try shift("2026-10-21"), try shift("2026-10-07")]
        XCTAssertEqual(PetProgress(shifts: shifts, now: now, calendar: calendar).streakWeeks, 3)
        // Nothing yet this week: last week still keeps the streak alive.
        XCTAssertEqual(PetProgress(shifts: [try shift("2026-10-28"), try shift("2026-10-21")], now: now, calendar: calendar).streakWeeks, 2)
        XCTAssertEqual(PetProgress(shifts: [try shift("2026-10-21"), try shift("2026-10-14")], now: now, calendar: calendar).streakWeeks, 0)
        // Booked shifts don't count until they're worked.
        XCTAssertEqual(PetProgress(shifts: [try shift("2026-11-06")], now: now, calendar: calendar).streakWeeks, 0)
    }

    func testMoodDropsWhenYouGoQuietAndPicksUpWithAShiftBooked() throws {
        func mood(_ shifts: [Shift]) -> PetProgress.Mood { PetProgress(shifts: shifts, now: now, calendar: calendar).mood }
        XCTAssertEqual(mood([try shift(daysAgo(1)), try shift(daysAgo(8)), try shift(daysAgo(15))]), .thriving)
        XCTAssertEqual(mood([try shift(daysAgo(5))]), .happy)
        XCTAssertEqual(mood([try shift(daysAgo(10))]), .okay)
        XCTAssertEqual(mood([try shift(daysAgo(20))]), .hungry)
        XCTAssertEqual(mood([try shift(daysAgo(40))]), .sad)
        XCTAssertEqual(mood([try shift(daysAgo(40)), try shift("2026-11-07")]), .happy)
        let hungry = PetProgress(shifts: [try shift(daysAgo(20))], now: now, calendar: calendar)
        XCTAssertEqual(hungry.message(name: "Penny", currency: "SGD"), "Penny is hungry… it's been 20 days since your last shift.")
    }

    func testFiftyPaidDaysMakeATreasureAndLevelsKeepGoing() throws {
        let shifts = try (1...50).map { try shift(daysAgo($0), paid: true) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.xp, 2000)
        XCTAssertEqual(pet.stage, .treasure)
        XCTAssertNil(pet.next)
        XCTAssertEqual(pet.progress, 1)
        XCTAssertEqual(pet.level, 11)
        XCTAssertEqual(pet.xpToNextLevel, 420)
        XCTAssertEqual(pet.message(name: "Penny", currency: "SGD"), "On a roll! 8 weeks in a row. Keep the streak going.")
    }

    func testCoinsComeFromShiftsStreaksAndAchievements() throws {
        // 2 worked (10) + 1 paid (10) + badges: First shift, Payday (50) = 70 coins.
        let pet = PetProgress(shifts: [try shift("2026-11-02", paid: true), try shift("2026-11-03")], now: now, calendar: calendar)
        XCTAssertEqual(Set(pet.achievements.filter(\.earned).map(\.id)), ["first-shift", "payday"])
        XCTAssertEqual(pet.coinsEarned, 70)
        // 4 weeks in a row: 4 worked (20) + the 4-week milestone (25) + First shift and On a roll (50).
        let streak = PetProgress(shifts: [try shift("2026-11-03"), try shift("2026-10-27"), try shift("2026-10-20"), try shift("2026-10-13")], now: now, calendar: calendar)
        XCTAssertEqual(streak.coinsEarned, 95)
        XCTAssertTrue(streak.missions.first { $0.id == "streak" }!.done)
    }

    func testBestStreakAndShiftTimeBadges() throws {
        let night = try Shift(event: "Gala", day: "2026-10-20", startMinute: 20 * 60, endMinute: 2 * 60, rate: 20)
        let early = try Shift(event: "Setup", day: "2026-10-27", startMinute: 6 * 60, endMinute: 12 * 60, rate: 20)
        let shifts = [night, early, try shift("2026-10-13"), try shift("2026-10-06"), try shift("2026-09-01")]
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.bestStreakWeeks, 4)
        XCTAssertEqual(pet.streakWeeks, 4) // last worked last week
        XCTAssertTrue(pet.hasAchievement("on-a-roll"))
        XCTAssertTrue(pet.hasAchievement("night-owl"))
        XCTAssertTrue(pet.hasAchievement("early-bird"))
    }

    func testTheShopOpensUpAsPennyGrows() throws {
        let shifts = try (1...8).map { try shift(daysAgo($0), paid: true) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.stage, .coinling)
        XCTAssertEqual(pet.coinsEarned, 205) // 120 for shifts, a busy week, and First shift, Payday and Four figures
        var closet = PetCloset()
        let partyHat = PetItem.named("party-hat")!
        try closet.buy(partyHat, pet)
        XCTAssertEqual(closet.balance(pet), 165)
        XCTAssertEqual(closet.wearing(.hat, pet), partyHat)
        try closet.toggle(partyHat, pet)
        XCTAssertNil(closet.wearing(.hat, pet))
        let crown = PetItem.named("royal-crown")!
        XCTAssertTrue(closet.locked(crown, pet)) // a treasure's crown
        XCTAssertThrowsError(try closet.buy(crown, pet)) { XCTAssertEqual($0 as? PetCloset.ClosetError, .locked) }
        XCTAssertThrowsError(try closet.toggle(crown, pet))
        XCTAssertEqual(closet.wearing(.background, pet)?.id, "mint")
        var broke = PetCloset(); broke.spent = pet.coinsEarned
        XCTAssertThrowsError(try broke.buy(PetItem.named("cap")!, pet)) { error in
            XCTAssertEqual(error as? PetCloset.ClosetError, .notEnoughCoins(needed: 80))
        }
        var egg = PetCloset()
        XCTAssertThrowsError(try egg.buy(partyHat, PetProgress(shifts: [], now: now, calendar: calendar)))
        let saved = try JSONDecoder().decode(PetCloset.self, from: JSONEncoder().encode(closet))
        XCTAssertEqual(saved, closet)
    }

    func testCoinsTakenBackShowAsANegativeBalance() throws {
        let pet = PetProgress(shifts: [try shift("2026-11-02", paid: true), try shift("2026-11-03")], now: now, calendar: calendar)
        var closet = PetCloset(); closet.spent = 100
        XCTAssertEqual(closet.balance(pet), -30)
        // A 40-coin hat at -30 coins needs 70 more, not 40.
        let shifts = try (1...3).map { try shift(daysAgo($0)) }
        let grown = PetProgress(shifts: shifts + [try shift(daysAgo(4), paid: true), try shift(daysAgo(5), paid: true)], now: now, calendar: calendar)
        var owing = PetCloset(); owing.spent = grown.coinsEarned + 30
        XCTAssertThrowsError(try owing.buy(PetItem.named("party-hat")!, grown)) { XCTAssertEqual($0 as? PetCloset.ClosetError, .notEnoughCoins(needed: 70)) }
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

    func testNewSkinsUnlockWithCoinsStagesAndBadges() throws {
        let skins = PetItem.catalog.filter { $0.slot == .skin }.map(\.id)
        XCTAssertEqual(skins, ["classic", "pioneer", "rose-gold", "silver", "matcha", "sakura", "midnight", "rainbow"])
        let shifts = try (1...10).map { try shift(daysAgo($0)) }
        let pet = PetProgress(shifts: shifts, now: now, calendar: calendar)
        XCTAssertEqual(pet.stage, .hatchling)
        var closet = PetCloset()
        XCTAssertTrue(closet.owns(PetItem.named("rainbow")!, pet)) // the Regular badge: 10 shifts
        XCTAssertTrue(closet.locked(PetItem.named("midnight")!, pet)) // golden coins only
        XCTAssertThrowsError(try closet.buy(PetItem.named("silver")!, pet))
        try closet.buy(PetItem.named("rose-gold")!, pet)
        XCTAssertEqual(closet.wearing(.skin, pet)?.id, "rose-gold")
        XCTAssertFalse(PetItem.named("rose-gold")!.pioneerOnly)
    }
}
