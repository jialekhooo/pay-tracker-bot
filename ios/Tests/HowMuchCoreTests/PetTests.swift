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
}
