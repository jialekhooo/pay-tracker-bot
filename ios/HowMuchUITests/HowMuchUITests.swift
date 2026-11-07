import XCTest

final class HowMuchUITests: XCTestCase {
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<10 {
            let top = window.frame.minY + 110
            let bottom = window.frame.maxY - 100
            if element.exists && element.isHittable && element.frame.midY > top && element.frame.midY < bottom { return }
            if element.exists && element.frame.midY < top { app.swipeDown() } else { app.swipeUp() }
        }
    }
    @MainActor
    func testProfilePhotoReplacementFailureAndRemovalKeepCurrentPhotoUntilConfirmed() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-profile-photo"]; app.launch()
        app.buttons["Profile settings"].tap()
        let sample = app.buttons["profile.samplePhoto"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5)); sample.tap()
        XCTAssertTrue(app.alerts["Use selected profile photo?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Use photo"].tap()
        let image = app.images["Profile photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        sample.tap(); app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(image.exists)
        app.buttons["profile.invalidPhoto"].tap()
        XCTAssertTrue(app.alerts["Photo kept"].waitForExistence(timeout: 5)); app.alerts.buttons["OK"].tap()
        XCTAssertTrue(image.exists)
        app.buttons["profile.removePhoto"].tap()
        XCTAssertTrue(app.alerts["Remove profile photo?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap(); XCTAssertTrue(image.exists)
        attach("Profile photo preserved and removal requires confirmation", app: app)
        app.buttons["profile.removePhoto"].tap(); app.alerts.buttons["Remove photo"].tap()
        XCTAssertFalse(image.exists)
        sample.tap(); app.alerts.buttons["Use photo"].tap(); XCTAssertTrue(image.waitForExistence(timeout: 5))
        app.buttons["profile.save"].tap(); app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["Profile settings"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
    }
    @MainActor
    func testAllShiftsGroupingIncludesCompletedWorkAndKeepsFiltersAndSort() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["Search shifts"].tap()
        let toggle = app.switches["upcoming.groupEvents"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" { toggle.tap() }
        let wedding = app.buttons["shifts.event.SGD|wedding reception"]
        reveal(wedding, in: app); XCTAssertTrue(wedding.exists)
        XCTAssertTrue(wedding.label.contains("2 shifts"))
        attach("All shifts grouped by event including completed work", app: app)
        tapTrailingArea(wedding, in: app)
        XCTAssertTrue(app.navigationBars["Wedding reception"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        // Wait for the list to come back before looking for the sort button.
        let sortButton = app.buttons.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", ["Earliest first", "Latest first"], ["Earliest first", "Latest first"])).firstMatch
        XCTAssertTrue(sortButton.waitForExistence(timeout: 5))
        reveal(sortButton, in: app); sortButton.tap()
        app.buttons["Unpaid"].tap()
        XCTAssertTrue(toggle.exists)
        app.buttons["All"].tap(); toggle.tap()
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wedding reception,"))
        reveal(cards.firstMatch, in: app); XCTAssertEqual(cards.count, 2)
    }

    @MainActor
    private func openShift(_ name: String, in app: XCUIApplication) {
        app.buttons["Search shifts"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(name)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ","))
        // Other matches (e.g. "Weekend roadshow") can push the card behind the keyboard: dismiss it and scroll to the card.
        if !(cards.allElementsBoundByIndex.contains { $0.isHittable }) {
            search.typeText("\n")
            if let card = cards.allElementsBoundByIndex.first { reveal(card, in: app) }
        }
        guard let card = cards.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible shift card for " + name); return
        }
        card.tap()
    }
    @MainActor
    private func attach(_ name: String, app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name; item.lifetime = .keepAlways; add(item)
    }
    /// App Store screenshots. Skipped unless STORE_SHOTS_DIR is set:
    /// TEST_RUNNER_STORE_SHOTS_DIR=/path xcodebuild test -only-testing:HowMuchUITests/HowMuchUITests/testStoreScreenshots
    @MainActor
    func testStoreScreenshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["STORE_SHOTS_DIR"], !folder.isEmpty else { throw XCTSkip("STORE_SHOTS_DIR not set") }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func shot(_ name: String) {
            sleep(2)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        func launch(_ arguments: [String]) -> XCUIApplication {
            let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
            XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 15) || app.staticTexts["paste.summary"].waitForExistence(timeout: 5))
            return app
        }
        var app = launch(["--preview", "-appearance", "light"])
        shot("overview")
        app.buttons["nav.calendar"].tap(); shot("calendar")
        app.buttons["nav.earnings"].tap(); shot("earnings")
        app.buttons["nav.overview"].tap()
        let card = app.buttons["pet.card"]; XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        shot("penny")
        app.terminate()
        app = launch(["--preview", "--ui-test-shared-job", "-appearance", "light"])
        XCTAssertTrue(app.staticTexts["paste.summary"].waitForExistence(timeout: 10))
        shot("paste-job")
        app.terminate()
        app = launch(["--preview", "-appearance", "dark"])
        shot("overview-dark")
        app.buttons["nav.calendar"].tap(); shot("calendar-dark")
        app.terminate()
        app = launch(["--ui-test-account", "--ui-test-friends", "-appearance", "light"])
        let petCard = app.buttons["pet.card"]; XCTAssertTrue(petCard.waitForExistence(timeout: 10)); petCard.tap()
        let friends = app.buttons["pet.friends"]; reveal(friends, in: app); friends.tap()
        XCTAssertTrue(app.staticTexts["PENNY-MYCODE"].waitForExistence(timeout: 5))
        shot("friends")
        let sam = app.descendants(matching: .any).matching(identifier: "friends.friend.PENNY-SAMSAM").firstMatch
        reveal(sam, in: app); sam.tap()
        XCTAssertTrue(app.staticTexts["Mochi"].waitForExistence(timeout: 5))
        app.buttons["friend.hello"].tap()
        XCTAssertTrue(app.staticTexts["Mochi waved back! You and Sam each got 2 coins."].waitForExistence(timeout: 5))
        shot("friend-visit")
    }
    @MainActor
    func testFoodMiscAndCabClaimsPersistEditDeleteAndUndo() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account"]; app.launch()
        let name = "C" + String(UUID().uuidString.prefix(4))
        app.buttons["nav.add"].tap()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 5))
        app.textFields["Event name"].tap(); app.textFields["Event name"].typeText(name); app.buttons["Save"].tap()
        openShift(name, in: app)
        for (kind,amount,note) in [("food","12.34","Food QA"),("miscellaneous","3.21","Misc QA"),("cab","1.25","Cab QA")] {
            tapTrailingArea(app.buttons["Add claim"], in: app)
            XCTAssertTrue(app.buttons["claim.category." + kind].waitForExistence(timeout: 5))
            app.buttons["claim.category." + kind].tap()
            app.textFields["claim.amount"].tap(); app.textFields["claim.amount"].typeText(amount)
            let noteField = app.textFields["claim.note"]; reveal(noteField, in: app); noteField.tap(); noteField.typeText(note)
            app.buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts[note].waitForExistence(timeout: 5))
        }
        app.terminate(); app.launch(); openShift(name, in: app)
        let foodMenu = app.buttons["Food claim actions: Food QA"]; reveal(foodMenu, in: app)
        attach("All three claim categories", app: app)
        XCTAssertTrue(foodMenu.exists); let claimID = foodMenu.identifier
        foodMenu.tap(); app.buttons["Edit claim"].tap()
        XCTAssertTrue(app.buttons["claim.category.food"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["claim.category.food"].isSelected)
        app.buttons["claim.category.miscellaneous"].tap(); app.buttons["Save"].tap()
        let editedMenu = app.buttons["Miscellaneous claim actions: Food QA"]
        XCTAssertTrue(editedMenu.waitForExistence(timeout: 5)); XCTAssertEqual(editedMenu.identifier, claimID)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "claim.actions.")).count, 3)
        attach("Cab food and miscellaneous reimbursements", app: app)
        reveal(editedMenu, in: app); editedMenu.tap(); app.buttons["Delete claim"].tap(); app.sheets.buttons["Delete claim"].tap()
        XCTAssertFalse(app.staticTexts["Food QA"].exists)
        tapTrailingArea(app.buttons["Undo last change"], in: app)
        XCTAssertTrue(app.buttons["Miscellaneous claim actions: Food QA"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testUpcomingGroupsSwitchViewsAndRespectDateRangeAndEarnings() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        tapTrailingArea(app.buttons["overview.upcoming"], in: app)
        let toggle = app.switches["upcoming.groupEvents"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        let weekend = app.buttons["upcoming.event.SGD|weekend roadshow"]
        XCTAssertTrue(weekend.waitForExistence(timeout: 5)); reveal(weekend, in: app)
        attach("Upcoming grouped by event", app: app); weekend.tap()
        let detail = app.scrollViews["upcoming.eventDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekend roadshow,")).count, 2)
        attach("Grouped upcoming event and its shifts", app: app)
        app.navigationBars["Weekend roadshow"].buttons.firstMatch.tap()
        app.buttons["Tomorrow"].tap(); XCTAssertFalse(weekend.exists)
        app.buttons["7 days"].tap(); XCTAssertTrue(weekend.waitForExistence(timeout: 5))
        for _ in 0..<3 { app.swipeDown() }
        toggle.tap(); XCTAssertFalse(weekend.exists)
        app.navigationBars["Upcoming shifts"].buttons.firstMatch.tap()
        app.buttons["nav.earnings"].tap(); app.buttons["Upcoming"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0"); toggle.tap()
        let wedding = app.buttons["upcoming.event.SGD|wedding reception"]; reveal(wedding, in: app); wedding.tap()
        XCTAssertTrue(app.staticTexts["1 upcoming shift"].waitForExistence(timeout: 5))
        XCTAssertEqual(detail.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wedding reception,")).count, 1)
        tapTrailingArea(app.buttons["View all event earnings"], in: app)
        let earnings = app.scrollViews["event.detail"]; XCTAssertTrue(earnings.waitForExistence(timeout: 5))
        XCTAssertEqual(earnings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wedding reception,")).count, 2)
    }
    @MainActor
    func testUpcomingGroupingPreferencePersistsAndIsAccountScoped() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account"]; app.launch()
        tapTrailingArea(app.buttons["overview.upcoming"], in: app)
        let toggle = app.switches["upcoming.groupEvents"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String != "1" { toggle.tap() }
        app.terminate(); app.launch(); tapTrailingArea(app.buttons["overview.upcoming"], in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        app.terminate(); app.launchArguments = ["--ui-test-account", "--ui-test-owner-b"]; app.launch()
        tapTrailingArea(app.buttons["overview.upcoming"], in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        app.terminate(); app.launchArguments = ["--ui-test-account"]; app.launch(); tapTrailingArea(app.buttons["overview.upcoming"], in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1"); toggle.tap()
    }
    @MainActor
    func testHourlyAndLumpSumBreakdownAndStaticEventSummary() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        openShift("Roadshow", in: app)
        let breakdown = app.buttons["Pay breakdown"]
        tapTrailingArea(breakdown, in: app)
        XCTAssertTrue(app.staticTexts["Hourly Rate, SGD 20.00/h"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paid hours, 8"].exists)
        XCTAssertTrue(app.staticTexts["Break, 60 min · unpaid"].exists)
        XCTAssertFalse(app.staticTexts["Pay type"].exists)
        attach("Hourly pay breakdown", app: app)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 5))
        let lump = app.buttons["Lump sum"]; reveal(lump, in: app); lump.tap()
        let amount = app.textFields["shift.amount"]; XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (amount.value as? String ?? "").count)); amount.typeText("200")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        if !app.staticTexts["Lump Sum Rate, SGD 200.00"].exists { tapTrailingArea(breakdown, in: app) }
        XCTAssertTrue(app.staticTexts["Lump Sum Rate, SGD 200.00"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Hourly Rate, SGD 20.00/h"].exists)
        attach("Lump sum pay breakdown", app: app)
        tapTrailingArea(app.buttons["View event earnings"], in: app)
        XCTAssertTrue(app.scrollViews["event.detail"].waitForExistence(timeout: 5))
        attach("Event summary without navigation chevron", app: app)
    }
    @MainActor
    func testSharedJobDetailsPersistAndEarningsUndoKeepsGrouping() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account"]; app.launch()
        let suffix = String(UUID().uuidString.prefix(4))
        let original = "QA" + suffix, renamed = "Job" + suffix, final = "End" + suffix
        app.buttons["nav.add"].tap()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 5))
        app.textFields["Event name"].tap(); app.textFields["Event name"].typeText(original)
        app.textFields["Location (optional)"].tap(); app.textFields["Location (optional)"].typeText("Old site\n")
        // With the keyboard up, a tap can only dismiss it; make sure the second date was really added.
        let anotherDate = app.staticTexts["ANOTHER DATE"]
        for _ in 0..<3 where !anotherDate.exists {
            tapTrailingArea(app.buttons["shift.addDate"], in: app)
            _ = anotherDate.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(anotherDate.exists)
        app.buttons["Save"].tap()
        openShift(original, in: app); app.buttons["Edit"].tap()
        let name = app.textFields["Event name"], location = app.textFields["Location (optional)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count)); name.typeText(renamed)
        location.tap(); location.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); location.typeText("Venue QA")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        openShift(renamed, in: app)
        tapTrailingArea(app.buttons["View event earnings"], in: app)
        let body = app.scrollViews["event.detail"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", renamed + ",", "Venue QA")).count, 2)
        tapTrailingArea(app.buttons["event.editDetails"], in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: renamed.count)); name.typeText(final)
        location.tap(); location.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); location.typeText("Next site")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars[final].waitForExistence(timeout: 5))
        XCTAssertEqual(body.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", final + ",", "Next site")).count, 2)
        attach("Shared event name and location in Earnings", app: app)
        tapTrailingArea(body.buttons["Undo last change"], in: app)
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 5))
        XCTAssertEqual(body.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", renamed + ",", "Venue QA")).count, 2)
    }
    @MainActor
    func testEarningsCanSetSharedLocationForMixedVenueEvent() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.earnings"].tap()
        tapTrailingArea(app.staticTexts["Wedding reception"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["event.editDetails"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["event.editDetails"], in: app)
        let location = app.textFields["Location (optional)"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["These shifts currently have different locations. Enter a shared location to replace them all."].exists)
        location.tap(); location.typeText("Shared venue")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Wedding reception"].waitForExistence(timeout: 5))
        let body = app.scrollViews["event.detail"]
        XCTAssertTrue(body.staticTexts["Shared venue"].firstMatch.exists)
        XCTAssertEqual(body.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Wedding reception,", "Shared venue")).count, 2)
        attach("Earnings shared location and edit controls", app: app)
    }
    @MainActor
    func testLiveAppleMapsPlaceSearchAndDirections() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        openShift("Roadshow", in: app)
        app.buttons["Edit"].tap()
        let find = app.buttons["shift.findLocation"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.tap()
        XCTAssertTrue(app.textFields["location.query"].waitForExistence(timeout: 5))
        let suggestion = app.buttons["location.suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 30), "Live Apple Maps should return place suggestions")
        attach("Live Apple Maps place suggestions", app: app)
        suggestion.tap()
        XCTAssertTrue(app.buttons["shift.findLocation"].waitForExistence(timeout: 5))
        let location = app.textFields["Location (optional)"]
        XCTAssertTrue((location.value as? String ?? "").localizedCaseInsensitiveContains("Suntec"))
        app.buttons["Save"].tap()
        let directions = app.buttons["shift.directions"]
        XCTAssertTrue(directions.waitForExistence(timeout: 5)); directions.tap()
        XCTAssertTrue(app.navigationBars["Map & directions"].waitForExistence(timeout: 5))
        let transit = app.buttons["location.transit"]
        let match = app.buttons["location.destination.0"]
        let resolved = app.buttons.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "location.destination.0", "location.transit")).firstMatch
        XCTAssertTrue(resolved.waitForExistence(timeout: 25))
        if match.exists { match.tap() }
        XCTAssertTrue(transit.waitForExistence(timeout: 5), "Resolved destination should provide transport actions")
        attach("Live workplace map and directions", app: app)
        XCTAssertTrue(app.buttons["location.driving"].exists)
        XCTAssertTrue(app.buttons["location.walking"].exists)
        // Walking sits below the fold, and a swipe in the middle of the screen pans the map instead of scrolling,
        // so drag from the route buttons below the map.
        let walking = app.buttons["location.walking"], window = app.windows.firstMatch
        for _ in 0..<3 where walking.frame.maxY > window.frame.maxY - 40 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        tapTrailingArea(walking, in: app)
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 12), "Directions should launch the real Apple Maps app")
        attach("Apple Maps directions handoff", app: maps)
        app.activate()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["shift.directions"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testTypedLocationFallbackAndCancel() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.add"].tap()
        XCTAssertTrue(app.buttons["shift.findLocation"].waitForExistence(timeout: 5))
        app.buttons["shift.findLocation"].tap()
        let query = app.textFields["location.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Do not save this")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["shift.findLocation"].waitForExistence(timeout: 5))
        XCTAssertFalse((app.textFields["Location (optional)"].value as? String ?? "").contains("Do not save"))
        app.buttons["shift.findLocation"].tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Meet at site entrance")
        tapTrailingArea(app.buttons["location.useTyped"], in: app)
        XCTAssertTrue(app.buttons["shift.findLocation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Location (optional)"].value as? String, "Meet at site entrance")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testIntroPagesLeadToSignUpAndShowOnlyOnce() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-onboarding"]; app.launch()
        XCTAssertTrue(app.staticTexts["WELCOME TO HOWMUCH"].waitForExistence(timeout: 10))
        attach("Intro first page", app: app)
        for eyebrow in ["ADD JOBS FAST", "GET PAID ON TIME", "STAY ON SCHEDULE", "MEET PENNY"] {
            app.buttons["intro.next"].tap()
            XCTAssertTrue(app.staticTexts[eyebrow].waitForExistence(timeout: 5), eyebrow)
        }
        XCTAssertFalse(app.buttons["intro.skip"].exists, "the last page has no Skip")
        attach("Intro last page", app: app)
        app.buttons["intro.signUp"].tap()
        XCTAssertTrue(app.buttons["account.signInApple"].waitForExistence(timeout: 10), "Sign up leads to Sign in with Apple")
        // Seen once, the intro doesn't come back.
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["account.signInApple"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["WELCOME TO HOWMUCH"].exists)
    }
    @MainActor
    func testTelegramLinkingHelpGuideAndUnlink() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account", "--ui-test-telegram"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 10)); app.buttons["nav.settings"].tap()
        let row = app.staticTexts["Telegram"]; reveal(row, in: app); row.tap()
        func showing(_ text: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch }
        XCTAssertTrue(showing("Not linked").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What you can do in Telegram"].exists || app.staticTexts["WHAT YOU CAN DO IN TELEGRAM"].exists)
        attach("Telegram screen before linking", app: app)
        app.buttons["telegram.link"].tap()
        // Telegram (Safari in the simulator) opens; come back as the person would after tapping Start.
        _ = app.wait(for: .runningBackground, timeout: 10)
        app.activate()
        XCTAssertTrue(showing("Linked to @howmuch_tester").waitForExistence(timeout: 10))
        attach("Telegram linked", app: app)
        app.buttons["telegram.unlink"].tap()
        let confirm = app.buttons["Unlink"]; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(showing("Not linked").waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let data = app.staticTexts["Data & backups"]; reveal(data, in: app); data.tap()
        let export = app.descendants(matching: .any).matching(identifier: "data.telegramBot").firstMatch
        reveal(export, in: app); XCTAssertTrue(export.waitForExistence(timeout: 5))
    }
    @MainActor
    func testAppearanceCaptionDescribesTheChosenOption() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 10)); app.buttons["nav.settings"].tap()
        let caption = app.staticTexts["settings.appearanceCaption"]; reveal(caption, in: app)
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        for (option, text) in [("Dark", "Always dark, even when your iPhone is in Light Mode."),
                               ("Light", "Always light, even when your iPhone is in Dark Mode."),
                               ("Match iPhone", "Switches between light and dark with your iPhone.")] {
            app.buttons[option].tap()
            XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5), option)
        }
    }
    @MainActor
    func testFriendsVisitPetsAndSayHiOnceADay() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account", "--ui-test-friends"]; app.launch()
        let card = app.buttons["pet.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let friends = app.buttons["pet.friends"]; reveal(friends, in: app); friends.tap()
        XCTAssertTrue(app.staticTexts["PENNY-MYCODE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["friends.invite"].exists, "an invite link to share")
        // Accept Alex's request.
        let accept = app.buttons["friends.accept.PENNY-ALEXAL"]
        XCTAssertTrue(accept.waitForExistence(timeout: 5)); accept.tap()
        XCTAssertTrue(app.staticTexts["You're now friends! 🎉"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "friends.friend.PENNY-ALEXAL").firstMatch.waitForExistence(timeout: 5))
        attach("Friends list", app: app)
        // Visit Sam's Mochi and say hi.
        let sam = app.descendants(matching: .any).matching(identifier: "friends.friend.PENNY-SAMSAM").firstMatch
        reveal(sam, in: app); sam.tap()
        XCTAssertTrue(app.staticTexts["Mochi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sam's pet"].exists)
        XCTAssertTrue(app.staticTexts["Sam said hi to you today"].exists || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Sam said hi to you today")).firstMatch.exists)
        let hello = app.buttons["friend.hello"]; XCTAssertTrue(hello.isEnabled); hello.tap()
        XCTAssertTrue(app.staticTexts["Mochi waved back! You and Sam each got 2 coins."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["friend.hello"].isEnabled, "once a day")
        attach("Said hi to a friend's pet", app: app)
    }
    @MainActor
    func testShiftExtraIsAddedToThePayout() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.add"].tap()
        let event = app.textFields["Event name"]
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap(); event.typeText("Extras QA")
        let payout = app.staticTexts["shift.payoutPreview"]
        reveal(payout, in: app); XCTAssertTrue(payout.waitForExistence(timeout: 5))
        func amount(_ label: String) -> Double { Double(label.filter { $0.isNumber || $0 == "." }) ?? -1 }
        let before = amount(payout.label)
        let extra = app.textFields["shift.extra"]; reveal(extra, in: app); extra.tap(); extra.typeText("20")
        let note = app.textFields["shift.extraNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap(); note.typeText("Transport allowance")
        reveal(payout, in: app)
        XCTAssertEqual(amount(payout.label), before + 20, accuracy: 0.001)
        attach("Shift extra added to the payout", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5), "the shift with an extra saves")
    }
    @MainActor
    func testFaceIDLockCoversTheAppUntilUnlocked() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-app-lock"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 10)); app.buttons["nav.settings"].tap()
        let toggle = app.switches["settings.appLock"]
        reveal(toggle, in: app); XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(app.switches["settings.appLock"].waitForValue("1", timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "HowMuch is fully in the background before returning")
        app.activate()
        let unlock = app.buttons["appLock.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), "returning to HowMuch shows the lock")
        XCTAssertFalse(app.switches["settings.appLock"].isHittable, "nothing underneath can be used while locked")
        attach("HowMuch locked after returning", app: app)
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.appLock"].waitForExistence(timeout: 5))
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(app.switches["settings.appLock"].waitForValue("0", timeout: 5))
    }
    @MainActor
    func testJobEditorCardsPayModesAndValidation() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.add"].tap()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 5))
        attach("Job editor work and schedule", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["shift.error"].waitForExistence(timeout: 5))
        let event = app.textFields["Event name"]; event.tap(); event.typeText("Editor design QA")
        let overtime = app.switches["Overtime"]; reveal(overtime, in: app)
        if overtime.value as? String != "1" { overtime.switches.firstMatch.exists ? overtime.switches.firstMatch.tap() : overtime.tap() }
        XCTAssertTrue(app.textFields["After hours"].waitForExistence(timeout: 5))
        let lump = app.buttons["Lump sum"]; lump.tap()
        let amount = app.textFields["shift.amount"]; amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (amount.value as? String ?? "").count))
        amount.typeText("200")
        app.swipeUp()
        let minutes = app.textFields["Minutes"]; reveal(minutes, in: app); minutes.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        // The keyboard can lag the tap; retry once so typing lands in the field.
        if !minutes.waitForKeyboardFocus(timeout: 2) { minutes.tap(); _ = minutes.waitForKeyboardFocus(timeout: 3) }
        minutes.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (minutes.value as? String ?? "").count)); minutes.typeText("30")
        app.swipeUp()
        let paidBreak = app.switches["Paid break"]; reveal(paidBreak, in: app); paidBreak.tap()
        let due = app.switches["Payment due date"]; reveal(due, in: app); due.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shift.due"].firstMatch.exists)
        attach("Job editor pay and breaks", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["nav.overview"].waitForExistence(timeout: 5))
        app.buttons["Search shifts"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Editor design QA")
        let result = app.staticTexts.matching(identifier: "Editor design QA").allElementsBoundByIndex.last!
        XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
        XCTAssertTrue(app.navigationBars["Editor design QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SGD 200.00"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 5))
        let editedAmount = app.textFields["shift.amount"]; reveal(editedAmount, in: app)
        attach("Edit job payout", app: app)
        XCTAssertEqual(editedAmount.value as? String, "200")
        editedAmount.tap(); editedAmount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3)); editedAmount.typeText("250")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["SGD 250.00"].firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor
    func testShiftAndClaimSurviveRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account"]; app.launch()
        let name = "Beta QA \(UUID().uuidString.prefix(8))"
        app.buttons["nav.add"].tap()
        let event = app.textFields["Event name"]
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        event.tap(); event.typeText(name)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["nav.overview"].waitForExistence(timeout: 5))
        openShift(name, in: app)
        let claim = app.buttons["Add claim"]
        reveal(claim, in: app); claim.tap()
        let amount = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Amount (")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("12.34")
        let note = app.textFields["Note (optional)"]
        note.tap(); note.typeText("Airport cab QA")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Airport cab QA"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        openShift(name, in: app)
        reveal(app.staticTexts["Airport cab QA"], in: app)
        XCTAssertTrue(app.staticTexts["Airport cab QA"].exists)
        attach("Saved shift and reimbursement", app: app)
    }
    @MainActor
    func testPastedJobMessageFillsEveryDateForReview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5))
        app.buttons["nav.add"].tap()
        XCTAssertTrue(app.buttons["paste.type"].waitForExistence(timeout: 5))
        app.buttons["paste.type"].tap()
        let text = app.textViews["paste.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("ni hao! you free for this?\n\nLocation: The Singapore EDITION Hotel\nAddress: 38 Cuscaden Rd, Singapore 249731\n\n12th Nov 1200-2100hrs\n13-14th Nov 0800-2000hrs\n15th Nov 0900-2000hrs")
        app.buttons["paste.fill"].tap()
        XCTAssertTrue(app.staticTexts["paste.summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["paste.summary"].label.contains("4 dates"))
        XCTAssertEqual(app.textFields["Event name"].value as? String, "The Singapore EDITION Hotel")
        attach("Pasted job filled in", app: app)
        let save = app.buttons["Save"]
        save.tap()
        XCTAssertTrue(app.buttons["nav.calendar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["paste.type"].exists)
    }
    @MainActor
    func testSharedJobFromAnotherAppOpensAddShiftFilledIn() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-shared-job"]; app.launch()
        XCTAssertTrue(app.staticTexts["paste.summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["paste.summary"].label.contains("4 dates"))
        XCTAssertEqual(app.textFields["Event name"].value as? String, "The Singapore EDITION Hotel")
        attach("Shared job opened", app: app)
        app.buttons["Cancel"].tap()
        // A filled-in form asks before throwing the job away.
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5)); discard.tap()
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5))
        // Offered once only.
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(app.staticTexts["paste.summary"].waitForExistence(timeout: 3))
    }
    @MainActor
    func testAddJobShortcutFillsInACopiedMessage() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-add-job"]; app.launch()
        XCTAssertTrue(app.staticTexts["paste.summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["paste.summary"].label.contains("2 dates"))
        attach("Add a job from the clipboard", app: app)
        app.terminate()
        // Nothing usable copied: Add shift opens empty instead.
        app.launchArguments = ["--preview", "--ui-test-add-job-blank"]; app.launch()
        XCTAssertTrue(app.textFields["Event name"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["paste.summary"].exists)
        XCTAssertTrue(["", "Event name"].contains(app.textFields["Event name"].value as? String ?? ""))
    }
    @MainActor
    func testOverviewPointsToTheNextShiftWhenTomorrowIsFree() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-quiet-days"]; app.launch()
        let heading = app.staticTexts["Next up"]
        reveal(heading, in: app)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(app.staticTexts["in 3 days"].exists)
        XCTAssertTrue(app.staticTexts["Weekend roadshow"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Today"].exists)
        attach("Overview with nothing today or tomorrow", app: app)
    }
    @MainActor
    func testDevelopersGetTheirBadgeAndEverySkin() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-developer"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 10)); app.buttons["nav.settings"].tap()
        app.buttons["Profile settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile.developer"].waitForExistence(timeout: 5))
        attach("Developer badge on the profile", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["nav.overview"].tap()
        let card = app.buttons["pet.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        app.buttons["Skins"].firstMatch.tap()
        let terminal = app.buttons["pet.item.terminal"]
        reveal(terminal, in: app)
        XCTAssertTrue(terminal.exists)
        terminal.tap()
        XCTAssertTrue(terminal.staticTexts["Wearing"].waitForExistence(timeout: 5))
        attach("Developer skins, all unlocked", app: app)
        let holo = app.buttons["pet.item.holo"]; holo.tap()
        XCTAssertTrue(holo.staticTexts["Wearing"].waitForExistence(timeout: 5))
        attach("Penny in the Holographic skin", app: app)
        // Every hat, pair of glasses, neckwear and scene is unlocked too, with no coins spent.
        app.buttons["Hats"].firstMatch.tap()
        let crown = app.buttons["pet.item.royal-crown"]
        reveal(crown, in: app); crown.tap()
        XCTAssertTrue(crown.staticTexts["Wearing"].waitForExistence(timeout: 5))
        app.buttons["Scenes"].firstMatch.tap()
        let confetti = app.buttons["pet.item.confetti"]
        reveal(confetti, in: app); confetti.tap()
        XCTAssertTrue(confetti.staticTexts["Wearing"].waitForExistence(timeout: 5))
        attach("Developer wardrobe, all unlocked", app: app)
        let top = app.textFields["pet.name"]; reveal(top, in: app)
        attach("Penny holographic at the top", app: app)
    }
    @MainActor
    func testGiftCodesUnlockSpecialItemsAndDevelopersMakeThem() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-pet-codes"]; app.launch()
        let card = app.buttons["pet.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        XCTAssertFalse(app.buttons["pet.item.halo"].exists) // specials are hidden until unlocked
        XCTAssertFalse(app.buttons["pet.code.make"].exists)  // only developers make codes
        let redeem = app.buttons["pet.code.redeem"]
        reveal(redeem, in: app); redeem.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("launch2026")
        app.alerts.buttons["Redeem"].tap()
        _ = app.alerts.firstMatch.waitForExistence(timeout: 5)
        attach("Gift code result", app: app)
        XCTAssertTrue(app.alerts.staticTexts["Unlocked Golden halo and Fireworks! Find them in the wardrobe."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        let halo = app.buttons["pet.item.halo"]
        reveal(halo, in: app); halo.tap()
        XCTAssertTrue(halo.staticTexts["Wearing"].waitForExistence(timeout: 5))
        attach("Golden halo unlocked with a gift code", app: app)
        app.terminate()

        let dev = XCUIApplication(); dev.launchArguments = ["--preview", "--ui-test-pet-codes", "--ui-test-developer"]; dev.launch()
        XCTAssertTrue(dev.buttons["pet.card"].waitForExistence(timeout: 10)); dev.buttons["pet.card"].tap()
        let make = dev.buttons["pet.code.make"]
        reveal(make, in: dev); make.tap()
        let galaxy = dev.buttons["code.item.galaxy"]
        for _ in 0..<12 where !galaxy.isHittable { dev.swipeUp() }
        galaxy.tap()
        let custom = dev.textFields["code.custom"]
        reveal(custom, in: dev); custom.tap(); custom.typeText("STARS2026\n")
        let makeCode = dev.buttons["code.make"]
        reveal(makeCode, in: dev); makeCode.tap()
        XCTAssertTrue(dev.staticTexts["code.new"].waitForExistence(timeout: 5))
        XCTAssertEqual(dev.staticTexts["code.new"].label, "STARS2026")
        attach("Developer made a gift code", app: dev)
        // Swiping a code in Your codes revokes it.
        let row = dev.descendants(matching: .any).matching(identifier: "code.row.STARS2026").firstMatch
        reveal(row, in: dev); XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let revoke = dev.buttons["Revoke"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 5)); revoke.tap()
        XCTAssertTrue(dev.staticTexts["code.status.STARS2026"].waitForExistence(timeout: 5))
        XCTAssertEqual(dev.staticTexts["code.status.STARS2026"].label, "Revoked")
        XCTAssertFalse(dev.staticTexts["code.new"].exists)  // nothing left to share
        attach("Developer revoked a gift code", app: dev)
        row.press(forDuration: 1.2)
        let delete = dev.buttons["Delete code"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        XCTAssertTrue(dev.staticTexts["No codes yet."].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        attach("Developer deleted a revoked gift code", app: dev)
    }
    @MainActor
    func testPetCardOpensItsPage() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        let card = app.buttons["pet.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        reveal(card, in: app)
        attach("Pet on Overview", app: app)
        card.tap()
        XCTAssertTrue(app.textFields["pet.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["pet.name"].value as? String, "Penny")
        attach("Pet page", app: app)
        let missions = app.staticTexts["This week's missions"]
        reveal(missions, in: app)
        XCTAssertTrue(missions.exists)
        attach("Pet stats and missions", app: app)
        // Buy and wear a party hat with the demo's coins, then try on a background.
        let partyHat = app.buttons["pet.item.party-hat"]
        reveal(partyHat, in: app)
        attach("Pet wardrobe", app: app)
        partyHat.tap()
        let buy = app.buttons["Buy Party hat"]
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        buy.tap()
        XCTAssertTrue(partyHat.staticTexts["Wearing"].waitForExistence(timeout: 5))
        app.buttons["Scenes"].tap()
        let mint = app.buttons["pet.item.mint"]
        XCTAssertTrue(mint.waitForExistence(timeout: 5))
        attach("Pet in a party hat", app: app)
        app.buttons["Glasses"].tap()
        let sunglasses = app.buttons["pet.item.sunglasses"]
        XCTAssertTrue(sunglasses.waitForExistence(timeout: 5))
        sunglasses.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5) || app.buttons["Buy Sunglasses"].exists)
        attach("Not enough coins or buy sunglasses", app: app)
        if app.alerts.firstMatch.exists { app.alerts.buttons["OK"].tap() } else { app.buttons["Buy Sunglasses"].tap() }
        // Pioneers (everyone before launch) get their own skin.
        app.buttons["Skins"].tap()
        let pioneer = app.buttons["pet.item.pioneer"]
        XCTAssertTrue(pioneer.waitForExistence(timeout: 5))
        pioneer.tap()
        XCTAssertTrue(pioneer.staticTexts["Wearing"].waitForExistence(timeout: 5))
        let rainbow = app.buttons["pet.item.rainbow"]; reveal(rainbow, in: app)
        attach("Skins wardrobe", app: app)
        let top = app.textFields["pet.name"]; reveal(top, in: app)
        attach("Penny in her Pioneer skin", app: app)
        let badges = app.staticTexts["Badges"].firstMatch
        reveal(badges, in: app)
        attach("Pet badges", app: app)
    }
    @MainActor
    func testPayInTrackingShowsBankNotificationSetup() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-payments"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Pay-in tracking"], in: app)
        let setup = app.buttons["payin.notifications.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        attach("Pay-in tracking", app: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "payin.notifications.lastRun").firstMatch.exists)
        setup.tap()
        XCTAssertTrue(app.staticTexts["Step 1 of 10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Shortcuts"].exists)
        attach("Bank setup step 1", app: app)
        let next = app.buttons["bank.next"]
        for step in 2...10 {
            next.tap()
            XCTAssertTrue(app.staticTexts["Step \(step) of 10"].waitForExistence(timeout: 5), "step \(step)")
            if step == 6 { attach("Bank setup step 6", app: app) }
            if step == 9 { attach("Bank setup step 9", app: app) }
        }
        next.tap()
        XCTAssertTrue(app.staticTexts["And you're done!"].waitForExistence(timeout: 5))
        attach("Bank setup finished", app: app)
        app.buttons["Back to Pay-in tracking"].tap()
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
    }
    @MainActor
    func testLiveShiftSettingsToggle() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5))
        app.buttons["nav.settings"].tap()
        let row = app.staticTexts["Live shift"]
        reveal(row, in: app); row.tap()
        let toggle = app.switches["live.askFinish"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        attach("Live shift settings", app: app)
    }
    @MainActor
    func testCalendarEarningsAndMultiDateEntry() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.calendar"].waitForExistence(timeout: 5))
        attach("Overview", app: app)
        app.buttons["nav.calendar"].tap()
        XCTAssertTrue(app.buttons["calendar.today"].waitForExistence(timeout: 5))
        app.buttons["Next month"].tap(); app.buttons["Previous month"].tap(); app.buttons["calendar.today"].tap()
        attach("Calendar", app: app)
        let add = app.buttons["calendar.add"]
        reveal(add, in: app); add.tap()
        let event = app.textFields["Event name"]
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap(); event.typeText("Calendar QA")
        let another = app.buttons["shift.addDate"]
        reveal(another, in: app); another.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["nav.earnings"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["Calendar QA"], in: app)
        XCTAssertTrue(app.staticTexts["Calendar QA"].exists)
        app.buttons["nav.earnings"].tap()
        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 5))
        app.buttons["Week"].tap(); XCTAssertTrue(app.buttons["Next period"].waitForExistence(timeout: 5)); attach("Earnings week tap", app: app); app.buttons["Next period"].tap(); app.buttons["Previous period"].tap()
        app.buttons["All time"].tap()
        let months = app.buttons["Months"]
        reveal(months, in: app); months.tap()
        XCTAssertTrue(months.isSelected)
        attach("Earnings by month", app: app)
        app.buttons["nav.settings"].tap()
        XCTAssertTrue(app.staticTexts["Calendar sync"].waitForExistence(timeout: 5))
        attach("Settings", app: app)
    }
    @MainActor
    func testAccountSwitchingNeverShowsAnotherUsersRecords() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-account"]; app.launch()
        let name = "Private A " + String(UUID().uuidString.prefix(8))
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5))
        app.buttons["nav.add"].tap()
        let event = app.textFields["Event name"]
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap(); event.typeText(name)
        app.buttons["Save"].tap()
        app.terminate(); app.launchArguments = ["--ui-test-account", "--ui-test-owner-b"]; app.launch()
        XCTAssertTrue(app.buttons["Search shifts"].waitForExistence(timeout: 5))
        app.buttons["Search shifts"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(name)
        XCTAssertFalse(app.staticTexts[name].exists)
        app.terminate(); app.launchArguments = ["--ui-test-account"]; app.launch()
        openShift(name, in: app)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
    }
    @MainActor
    func testSignedOutAppRequiresAppleAccount() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-out"]; app.launch()
        XCTAssertTrue(app.buttons["account.signInApple"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["nav.overview"].exists)
        XCTAssertFalse(app.buttons["nav.calendar"].exists)
        attach("Apple sign-in required", app: app)
    }

    @MainActor
    func testSettingsDestinationsOpenAndControlsRespond() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5))
        app.buttons["nav.settings"].tap()
        let destinations = [
            ("Pay & breaks", "Pay & breaks"),
            ("Job notifications", "Job notifications"),
            ("Calendar sync", "Calendar sync"),
            ("Data & backups", "Data & backups"),
            ("Account & sync", "Account & sync"),
            ("Pay-in tracking", "Pay-in tracking")
        ]
        for (row, title) in destinations {
            let entry = app.staticTexts[row].firstMatch
            reveal(entry, in: app)
            XCTAssertTrue(entry.isHittable, "Settings row must be tappable: " + row)
            entry.tap()
            let navigation = app.navigationBars[title]
            guard navigation.waitForExistence(timeout: 5) else {
                XCTFail("Settings row did not open its destination: " + row)
                attach("Blocked settings destination " + row, app: app)
                return
            }
            if row == "Pay & breaks" {
                let save = app.buttons["Save defaults"]
                reveal(save, in: app); save.tap()
                XCTAssertTrue(app.alerts["Defaults saved"].waitForExistence(timeout: 3))
                app.alerts.buttons["OK"].tap()
            }
            if row == "Job notifications" {
                let starts = app.switches["Job start reminders"]
                let previous = starts.value as? String
                starts.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previous ?? ""), object: starts)], timeout: 3), .completed)
                let save = app.buttons["notifications.save"]
                reveal(save, in: app); save.tap()
                XCTAssertTrue(app.alerts["Preferences saved"].waitForExistence(timeout: 3))
                app.alerts.buttons["OK"].tap()
            }
            navigation.buttons.firstMatch.tap()
        }
        app.buttons["Profile settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["profile.pioneer"].exists)
        attach("Profile top", app: app)
        let profile = app.buttons["profile.save"]
        reveal(profile, in: app); profile.tap()
        XCTAssertTrue(app.alerts["Profile saved"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
        attach("Working profile settings", app: app)
    }

    @MainActor
    func testSettingsRowsRespondAcrossTheirFullWidth() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5))
        app.buttons["nav.settings"].tap()
        for title in ["Pay & breaks", "Job notifications", "Calendar sync", "Data & backups", "Account & sync", "Pay-in tracking"] {
            let label = app.staticTexts[title].firstMatch
            reveal(label, in: app)
            XCTAssertTrue(label.isHittable)
            // Tap the row's empty trailing area, as a finger often does, rather
            // than limiting coverage to the text glyphs.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0))
                .withOffset(CGVector(dx: 0, dy: label.frame.midY - app.windows.firstMatch.frame.minY)).tap()
            let navigation = app.navigationBars[title]
            guard navigation.waitForExistence(timeout: 5) else {
                XCTFail("The full Settings row must respond to taps: " + title)
                attach("Settings trailing touch area", app: app)
                return
            }
            navigation.buttons.firstMatch.tap()
        }
    }

    @MainActor
    private func tapTrailingArea(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        // Scrolling can still be settling when reveal returns.
        let settled = Date().addingTimeInterval(3)
        while !element.isHittable && Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(element.isHittable)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0))
            .withOffset(CGVector(dx: 0, dy: element.frame.midY - app.windows.firstMatch.frame.minY)).tap()
    }
    @MainActor
    func testPaidButtonsRespondAcrossWholeSurfaceAndUndo() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        openShift("Roadshow", in: app)
        tapTrailingArea(app.buttons["Mark as unpaid"], in: app)
        XCTAssertTrue(app.buttons["Mark as paid"].waitForExistence(timeout: 3))
        tapTrailingArea(app.buttons["Mark as paid"], in: app)
        XCTAssertTrue(app.buttons["Mark as unpaid"].waitForExistence(timeout: 3))
        tapTrailingArea(app.buttons["View event earnings"], in: app)
        let mark = app.buttons["Mark event as unpaid"]
        tapTrailingArea(mark, in: app)
        guard app.buttons["Mark event as paid"].waitForExistence(timeout: 3) else {
            XCTFail("The whole event payment button must be tappable")
            attach("Event payment touch area", app: app)
            return
        }
        tapTrailingArea(app.buttons["Undo payment change"], in: app)
        XCTAssertTrue(app.buttons["Mark event as unpaid"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testReusablePayerCanBeSelectedForEventAndInheritedByShift() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Payers"], in: app)
        XCTAssertTrue(app.staticTexts["REFIX PTE. LTD."].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["payers.add"], in: app)
        let name = app.textFields["payers.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Reusable company")
        let banks = app.descendants(matching: .any).matching(identifier: "payers.bankNames").firstMatch
        banks.tap(); banks.typeText("BANK COMPANY LTD\nALT BANK NAME")
        app.buttons["payers.save"].tap()
        XCTAssertTrue(app.staticTexts["Reusable company"].waitForExistence(timeout: 5))
        attach("Saved payer with multiple exact bank names", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        let earnings = app.buttons["nav.earnings"]
        XCTAssertTrue(earnings.waitForExistence(timeout: 5))
        XCTAssertTrue(earnings.isHittable)
        earnings.tap()
        XCTAssertTrue(earnings.isSelected)
        tapTrailingArea(app.staticTexts["Wedding reception"].firstMatch, in: app)
        tapTrailingArea(app.buttons["event.payer"], in: app)
        let chosen = app.buttons["payer.select.Reusable company"]
        XCTAssertTrue(chosen.waitForExistence(timeout: 5)); chosen.tap()
        XCTAssertTrue(app.buttons["event.payer"].label.contains("Reusable company"))
        attach("Event payer dropdown selection", app: app)
        let card = app.scrollViews["event.detail"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Wedding reception,")).firstMatch
        tapTrailingArea(card, in: app)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["shift.payer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shift.payer"].label.contains("Reusable company"))
        attach("Job editor inherits shared event payer", app: app)
        app.buttons["Cancel"].tap()
    }
    @MainActor
    func testSavedPayerValidationKeepsTypedCompany() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Payers"], in: app)
        tapTrailingArea(app.buttons["payers.add"], in: app)
        let name = app.textFields["payers.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("KEEP THIS COMPANY\n")
        app.buttons["payers.save"].tap()
        XCTAssertEqual(name.value as? String, "KEEP THIS COMPANY")
        XCTAssertTrue(app.staticTexts["Add a company name and 1–20 exact bank payer names."].waitForExistence(timeout: 5))
        attach("Saved payer validation preserves typed company", app: app)
    }
    @MainActor
    func testPaymentServiceErrorStopsLoadingAndAllowsRetry() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-payments", "--ui-test-payments-offline"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Pay-in tracking"], in: app)
        XCTAssertTrue(app.staticTexts["Pay-in tracking couldn’t be loaded. Refresh to try again."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        XCTAssertTrue(app.buttons["Refresh"].isEnabled)
        app.buttons["Refresh"].tap()
        XCTAssertTrue(app.staticTexts["Payment service is temporarily unavailable."].waitForExistence(timeout: 5))
        attach("Payment service error and retry", app: app)
    }
    @MainActor
    func testMonthlyEarningsReflectEditedAndDeletedShift() throws {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.earnings"].tap(); app.buttons["Months"].tap()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: Date())
        tapTrailingArea(app.buttons["earnings.month." + month], in: app)
        let initialTotal = app.staticTexts["earnings.total"].firstMatch.label
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Brand launch,"))
        let initialCount = cards.count
        XCTAssertGreaterThan(initialCount, 0)
        tapTrailingArea(cards.firstMatch, in: app)
        app.buttons["Edit"].tap()
        app.buttons["Lump sum"].tap()
        let amount = app.textFields["shift.amount"]; reveal(amount, in: app); amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (amount.value as? String ?? "").count)); amount.typeText("999")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Brand launch"].waitForExistence(timeout: 5))
        app.navigationBars["Brand launch"].buttons.firstMatch.tap()
        let updatedTotal = app.staticTexts["earnings.total"].firstMatch.label
        XCTAssertNotEqual(updatedTotal, initialTotal)
        XCTAssertTrue(app.staticTexts["SGD 999.00"].firstMatch.exists)
        tapTrailingArea(cards.firstMatch, in: app)
        reveal(app.buttons["Delete shift"], in: app)
        attach("Shift details with the delete button", app: app)
        tapTrailingArea(app.buttons["Delete shift"], in: app)
        app.sheets.buttons["Delete shift"].tap()
        // Offscreen cards are omitted from SwiftUI's accessibility tree. Verify
        // the exact remaining payout rather than treating visible cards as the DB.
        for _ in 0..<3 { app.swipeDown() }
        let total = app.staticTexts["earnings.total"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        let before = try XCTUnwrap(Decimal(string: updatedTotal.filter { $0.isNumber || $0 == "." }))
        let after = try XCTUnwrap(Decimal(string: total.label.filter { $0.isNumber || $0 == "." }))
        XCTAssertEqual(after, before - 999)
        XCTAssertFalse(app.staticTexts["SGD 999.00"].firstMatch.exists)
        attach("Monthly earnings updates after edit and deletion", app: app)
    }
    @MainActor
    func testPaymentReviewControlsWithIsolatedDBSResponses() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-payments"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Pay-in tracking"], in: app)
        XCTAssertTrue(app.staticTexts["Gmail connected"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["payment.scan"], in: app)
        let confirm = app.buttons["payment.receipt.1.confirm"]
        tapTrailingArea(confirm, in: app)
        let undo = app.buttons["payment.receipt.1.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        tapTrailingArea(undo, in: app)
        XCTAssertTrue(app.staticTexts["Undone"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["payment.receipt.2.dismiss"], in: app)
        let confirmDismiss = app.buttons.matching(NSPredicate(format: "label == %@", "Dismiss alert")).allElementsBoundByIndex.last
        XCTAssertNotNil(confirmDismiss); confirmDismiss?.tap()
        XCTAssertTrue(app.staticTexts["Ignored"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic scan completed"].exists)
        for _ in 0..<5 { app.swipeDown() }
        let auto = app.switches["Mark exact verified matches paid"]
        reveal(auto, in: app)
        auto.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: auto)], timeout: 3), .completed)
        let saved = app.buttons["payment.payers"]
        reveal(saved, in: app); saved.tap()
        XCTAssertTrue(app.navigationBars["Payers"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<5 { app.swipeDown() }
        tapTrailingArea(app.buttons["payment.disconnect"], in: app)
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["No email connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["payment.connect"].isEnabled)
        attach("Payment scan review undo rules and disconnect", app: app)
    }
    @MainActor
    func testGmailConnectsWithAnAppPassword() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-payments", "--ui-test-email-providers"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Pay-in tracking"], in: app)
        let gmailButton = app.buttons["payment.connect.gmail"]
        let icloudButton = app.buttons["payment.connect.icloud"]
        for _ in 0..<6 where !icloudButton.exists { app.swipeUp() }
        XCTAssertTrue(icloudButton.waitForExistence(timeout: 5))
        attach("Connect Gmail, Outlook and iCloud", app: app)
        XCTAssertTrue(gmailButton.exists)
        app.swipeDown()
        XCTAssertTrue(gmailButton.isHittable)
        gmailButton.tap()
        XCTAssertTrue(app.textFields["Gmail address"].waitForExistence(timeout: 5))
        let email = app.textFields["payment.icloud.email"]
        email.tap(); email.typeText("synthetic@gmail.com")
        let password = app.secureTextFields["payment.icloud.password"]
        password.tap(); password.typeText("abcd efgh ijkl mnop\n")
        let consent = app.switches["payment.icloud.consent"]
        reveal(consent, in: app); consent.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        attach("Gmail app password form", app: app)
        let save = app.buttons["payment.icloud.save"]
        XCTAssertTrue(save.isEnabled)
        tapTrailingArea(save, in: app)
        XCTAssertTrue(app.buttons["payment.disconnect"].waitForExistence(timeout: 5))
        let connected = app.staticTexts["Gmail connected"]
        for _ in 0..<6 where !connected.isHittable { app.swipeDown() }
        XCTAssertTrue(connected.exists)
        let automatic = app.switches["Mark exact verified matches paid"]
        reveal(automatic, in: app)
        XCTAssertFalse(automatic.isEnabled)
        attach("Gmail connected with an app password", app: app)
    }
    @MainActor
    func testICloudConnectionRetryAndBankConfirmation() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-payments", "--ui-test-email-providers"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Pay-in tracking"], in: app)
        let icloudButton = app.buttons["payment.connect.icloud"]
        for _ in 0..<6 where !icloudButton.exists { app.swipeUp() }
        XCTAssertTrue(icloudButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["payment.connect.microsoft"].isEnabled)
        tapTrailingArea(app.buttons["payment.connect.icloud"], in: app)
        let save = app.buttons["payment.icloud.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertFalse(save.isEnabled)
        let email = app.textFields["payment.icloud.email"]
        email.tap(); email.typeText("synthetic@me.com")
        let password = app.secureTextFields["payment.icloud.password"]
        password.tap(); password.typeText("aaaa-bbbb-cccc-dddd\n")
        let consent = app.switches["payment.icloud.consent"]
        reveal(consent, in: app); consent.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(consent.value as? String, "1")
        tapTrailingArea(save, in: app)
        XCTAssertTrue(app.staticTexts["Synthetic iCloud connection failed. Check the app-specific password."].waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        attach("iCloud failed connection preserves editable input", app: app)
        tapTrailingArea(save, in: app)
        // Pay-in tracking's bank-notification and forwarding sections sit above the mailbox section.
        let connected = app.staticTexts["iCloud Mail connected"]
        for _ in 0..<4 where !connected.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(connected.exists)
        let automatic = app.switches["Mark exact verified matches paid"]
        reveal(automatic, in: app)
        XCTAssertFalse(automatic.isEnabled)
        tapTrailingArea(app.buttons["payment.receipt.1.confirm"], in: app)
        XCTAssertTrue(app.alerts["Confirm bank payment"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["payment.receipt.1.confirm"].exists)
        tapTrailingArea(app.buttons["payment.receipt.1.confirm"], in: app)
        app.alerts.buttons["I checked my bank · Mark paid"].tap()
        XCTAssertTrue(app.buttons["payment.receipt.1.undo"].waitForExistence(timeout: 5))
        attach("iCloud detection requires explicit bank confirmation", app: app)
    }
    @MainActor
    func testBackupAndCalendarButtonsOpenSystemPickers() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Data & backups"], in: app)
        for name in ["Export shifts as CSV", "Export full archive", "Import Telegram CSV", "Restore full archive"] {
            tapTrailingArea(app.buttons[name], in: app)
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), "File picker must open: " + name)
            attach(name, app: app)
            cancel.tap()
            XCTAssertTrue(app.navigationBars["Data & backups"].waitForExistence(timeout: 5))
        }
        app.navigationBars.buttons.firstMatch.tap()
        tapTrailingArea(app.staticTexts["Calendar sync"], in: app)
        tapTrailingArea(app.buttons["calendar.exportICS"], in: app)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Calendar sync"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testLiveCalendarLinkOffersAppleGoogleAndTimeTree() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-calendar-link"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Calendar sync"], in: app)
        XCTAssertTrue(app.buttons["calendar.subscribeApple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar.subscribeGoogle"].exists)
        attach("Live calendar link", app: app)
        let timeTree = app.staticTexts["Using TimeTree?"].firstMatch
        reveal(timeTree, in: app)
        XCTAssertTrue(timeTree.exists || app.staticTexts["USING TIMETREE?"].exists)
        attach("TimeTree steps", app: app)
    }
    @MainActor
    func testShareAvailabilityWritesAMessageAndRemembersBlockedDays() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.calendar"].waitForExistence(timeout: 5)); app.buttons["nav.calendar"].tap()
        let share = app.buttons["calendar.availability"]
        reveal(share, in: app); share.tap()
        let message = app.staticTexts["availability.text"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.hasPrefix("My availability"))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "Asia/Singapore")
        let inAWeek = formatter.string(from: Date().addingTimeInterval(7 * 86400))
        let day = app.buttons["availability.day.\(inAWeek)"]
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        XCTAssertTrue(message.label.contains("Not available"))
        attach("Share availability", app: app)
    }
    @MainActor
    func testEditDuplicateDeleteAndCalendarEditor() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        openShift("Roadshow", in: app)
        app.buttons["Edit"].tap()
        let field = app.textFields["Event name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        field.typeText("Audit original"); app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Audit original"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["Add to Apple Calendar"], in: app)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        tapTrailingArea(app.buttons["Duplicate as new shift"], in: app)
        XCTAssertTrue(app.navigationBars["Add shift"].waitForExistence(timeout: 5))
        let copy = app.textFields["Event name"]; copy.tap()
        copy.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (copy.value as? String ?? "").count))
        copy.typeText("Audit duplicate"); app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Audit original"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["Delete shift"], in: app)
        app.sheets.buttons["Delete shift"].tap()
        // Active iOS search hides the navigation bar after returning to results.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (search.value as? String ?? "").count))
        search.typeText("Audit")
        XCTAssertTrue(app.staticTexts["Audit duplicate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Audit original"].exists)
        attach("Edit duplicate and delete completed", app: app)
    }
    @MainActor
    func testSignOutReturnsToMandatoryAppleScreen() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Account & sync"], in: app)
        tapTrailingArea(app.buttons["account.signOut"], in: app)
        app.sheets.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["account.signInApple"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nav.overview"].exists)
    }

    @MainActor
    func testWidgetPreviewsPrivacyRefreshAndDeepLink() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-widgets"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Widgets"], in: app)
        XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 5))
        let pay = app.switches["widgets.previewPay"]
        XCTAssertTrue(pay.exists)
        if pay.value as? String == "1" { pay.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(pay.value as? String, "0")
        pay.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap(); XCTAssertEqual(pay.value as? String, "1")
        attach("Next Shift widget preview", app: app)
        tapTrailingArea(app.buttons["widgets.refresh"], in: app)
        XCTAssertTrue(app.staticTexts["Widgets updated from this account."].waitForExistence(timeout: 5))
        attach("Upcoming Events and This Month widget previews", app: app)
        app.open(URL(string: "howmuch://widget/earnings?account=00000000-0000-4000-8000-000000000001")!)
        XCTAssertTrue(app.buttons["nav.earnings"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["nav.earnings"].isSelected)
        app.buttons["nav.settings"].tap()
        app.open(URL(string: "howmuch://widget/earnings?account=00000000-0000-4000-8000-000000000002")!)
        XCTAssertFalse(app.buttons["nav.earnings"].isSelected)
    }
    @MainActor
    func testWidgetPreviewOptionsSurviveReopening() {
        // Preview choices are account settings now; the demo account isn't saved between launches,
        // so this checks they stick while the app is open. Account sync is covered by the server tests.
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-widgets"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Widgets"], in: app)
        XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 5))
        let pay = app.switches["widgets.previewPay"]
        let location = app.switches["widgets.previewLocation"]
        if pay.value as? String != "1" { pay.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        if location.value as? String != "0" { location.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        app.navigationBars.buttons.firstMatch.tap()
        tapTrailingArea(app.staticTexts["Widgets"], in: app)
        XCTAssertEqual(pay.value as? String, "1"); XCTAssertEqual(location.value as? String, "0")
        attach("Saved widget preview preferences", app: app)
        pay.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        location.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        app.navigationBars.buttons.firstMatch.tap()
        tapTrailingArea(app.staticTexts["Widgets"], in: app)
        XCTAssertEqual(pay.value as? String, "0"); XCTAssertEqual(location.value as? String, "1")
    }
    @MainActor
    func testNotificationDeliveryShowsOneStatusAndRelevantActions() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.settings"].tap(); tapTrailingArea(app.staticTexts["Job notifications"], in: app)
        let fallback = app.descendants(matching: .any).matching(identifier: "notifications.deliveryStatus").firstMatch
        reveal(fallback, in: app); XCTAssertTrue(fallback.exists)
        XCTAssertFalse(app.staticTexts["Push notifications are registered for this account."].exists)
        XCTAssertFalse(app.buttons["Enable notifications on this iPhone"].exists)
        XCTAssertTrue(app.buttons["Open iPhone notification settings"].exists)
        attach("Clean notification delivery section", app: app)
    }

    @MainActor
    func testCalendarListsShiftContinuingFromYesterday() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-overnight-calendar"]; app.launch()
        app.buttons["nav.calendar"].tap()
        let overnight = app.staticTexts["Overnight calendar QA"].firstMatch
        reveal(overnight, in: app)
        XCTAssertTrue(overnight.exists)
        attach("Calendar includes overnight work from yesterday", app: app)
        overnight.tap()
        XCTAssertTrue(app.navigationBars["Overnight calendar QA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["22:00–06:00 (+1 day)"].firstMatch.exists)
    }
    @MainActor
    func testCalendarWidgetPreviewAndDateNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-widgets"]; app.launch()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Widgets"], in: app)
        XCTAssertTrue(app.staticTexts["Work Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Work Calendar"].isHittable)
        attach("Work Calendar medium preview", app: app)
        app.open(URL(string: "howmuch://widget/calendar?account=00000000-0000-4000-8000-000000000001&day=2026-11-06")!)
        XCTAssertTrue(app.buttons["nav.calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nav.calendar"].isSelected)
        XCTAssertTrue(app.buttons["calendar.day.2026-11-06"].isSelected)
        attach("Widget opens selected calendar day", app: app)
        app.open(URL(string: "howmuch://widget/calendar?account=00000000-0000-4000-8000-000000000002&day=2026-12-01")!)
        XCTAssertFalse(app.buttons["nav.calendar"].isSelected)
    }
    @MainActor
    func testWidgetAppearsInSystemGallery() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-widgets"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 1.5)
        print(springboard.debugDescription)
        let edit = springboard.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        print(springboard.debugDescription)
        springboard.buttons["Add Widget"].tap()
        print(springboard.debugDescription)
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("HowMuch")
        print(springboard.debugDescription)
        let howmuch = springboard.cells["HowMuch"]
        XCTAssertTrue(howmuch.waitForExistence(timeout: 5)); howmuch.tap()
        print(springboard.debugDescription)
        attach("HowMuch in system widget gallery", app: springboard)
        springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch.tap()
        let done = springboard.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        Thread.sleep(forTimeInterval: 2)
        print(springboard.debugDescription)
        let nextName = Calendar.current.component(.hour, from: Date()) < 18 ? "Brand launch" : "Hermès Private Sale"
        let liveJob = springboard.staticTexts[nextName].firstMatch
        XCTAssertTrue(liveJob.waitForExistence(timeout: 15))
        attach("Next Shift on the Home Screen", app: springboard)
        liveJob.tap()
        XCTAssertTrue(app.navigationBars[nextName].waitForExistence(timeout: 8))
        app.navigationBars[nextName].buttons.firstMatch.tap()
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Account & sync"], in: app)
        tapTrailingArea(app.buttons["account.signOut"], in: app)
        app.sheets.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["account.signInApple"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.staticTexts["Open HowMuch"].firstMatch.waitForExistence(timeout: 30))
        attach("Widget cleared after sign-out", app: springboard)
    }

    @MainActor
    func testTravelRequiresAddressAndConsentAndCanBeDisabled() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-travel"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Time to leave"], in: app)
        let enabled = app.switches["travel.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "1" { enabled.switches.firstMatch.tap() }
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let save = app.buttons["travel.save"]
        reveal(save, in: app); XCTAssertFalse(save.isEnabled)
        for _ in 0..<4 { app.swipeDown() }
        let origin = app.textFields["travel.origin"]
        if origin.exists { origin.tap(); origin.typeText("Singapore Botanic Gardens, Singapore") }
        else { let field = app.textViews["travel.origin"]; field.tap(); field.typeText("Singapore Botanic Gardens, Singapore") }
        if app.buttons["Continue"].firstMatch.waitForExistence(timeout: 2) { app.buttons["Continue"].firstMatch.tap() }
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        app.swipeUp()
        tapTrailingArea(save, in: app)
        XCTAssertTrue(app.buttons["Enable & save"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        tapTrailingArea(save, in: app)
        app.buttons["Enable & save"].tap()
        reveal(app.staticTexts["travel.message"], in: app)
        XCTAssertTrue(app.staticTexts["travel.message"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["travel.check"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Leave at")).firstMatch.waitForExistence(timeout: 5))
        attach("Travel reminders and saved origin", app: app)
        for _ in 0..<5 { app.swipeDown() }
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        tapTrailingArea(save, in: app)
        XCTAssertFalse(app.buttons["Enable & save"].exists)
    }

    @MainActor
    func testTravelRouteFailureKeepsSavedPreferences() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-travel", "--ui-test-travel-error"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Time to leave"], in: app)
        tapTrailingArea(app.buttons["travel.check"], in: app)
        let error = app.staticTexts["Route estimates are temporarily unavailable. Check Apple Maps before travelling."]
        reveal(error, in: app); XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["travel.check"].isEnabled)
        attach("Travel route unavailable and retry", app: app)
        for _ in 0..<5 { app.swipeDown() }
        XCTAssertEqual(app.textFields["travel.origin"].value as? String, "Singapore Botanic Gardens, Singapore")
        XCTAssertEqual(app.switches["travel.enabled"].value as? String, "1")
    }

    @MainActor
    func testTravelNotificationOpensDirectionsForOwnedJob() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-travel", "--ui-test-travel-notification"]; app.launch()
        XCTAssertTrue(app.buttons["Open route in Apple Maps"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["View job details"].exists)
        attach("Travel notification directions", app: app)
    }

    @MainActor
    func testWeeklyTemplatesCreateFourShiftsAndReuseSavedDetails() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.add"].waitForExistence(timeout: 5)); app.buttons["nav.add"].tap()
        let name = app.textFields["Event name"]; name.tap(); name.typeText("Weekly QA")
        let location = app.textFields["Location (optional)"]; location.tap(); location.typeText("Marina Bay Sands\n")
        // With the keyboard still up, the first tap only dismisses it; retry until the menu opens.
        let weekly = app.buttons["Weekly"]
        for _ in 0..<3 where !weekly.exists {
            reveal(app.buttons["shift.repeat"], in: app); app.buttons["shift.repeat"].tap()
            _ = weekly.waitForExistence(timeout: 2)
        }
        weekly.tap()
        let template = app.switches["shift.saveTemplate"]; reveal(template, in: app)
        template.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let title = app.textFields["shift.templateName"]; title.tap(); title.typeText("Usual crew")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Job templates"], in: app)
        XCTAssertTrue(app.staticTexts["Usual crew"].waitForExistence(timeout: 5))
        app.buttons["Template actions: Usual crew"].tap(); app.buttons["Edit template"].tap()
        let renamed = app.textFields["shift.templateName"]; reveal(renamed, in: app)
        renamed.tap(); renamed.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10)); renamed.typeText("Updated crew")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Updated crew"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["template.use"], in: app)
        XCTAssertEqual(app.textFields["Event name"].value as? String, "Weekly QA")
        XCTAssertEqual(app.textFields["Location (optional)"].value as? String, "Marina Bay Sands")
        attach("Reusable job template", app: app)
        app.buttons["Cancel"].tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["nav.earnings"].tap()
        tapTrailingArea(app.staticTexts["Weekly QA"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "4 shifts")).firstMatch.waitForExistence(timeout: 5))
        attach("Weekly series with four shifts", app: app)
    }

    @MainActor
    func testReceiptUploadRetryKeepsPhotoAndCanRemoveAttachment() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-receipts", "--ui-test-receipt-upload-error"]; app.launch()
        XCTAssertTrue(app.buttons["Search shifts"].waitForExistence(timeout: 5)); openShift("Brand launch", in: app)
        tapTrailingArea(app.buttons["Add claim"], in: app)
        app.buttons["claim.category.food"].tap()
        // Return closes the keyboard so it cannot cover the receipt buttons below the note.
        let note = app.textFields["claim.note"]; reveal(note, in: app); note.tap(); note.typeText("Photo QA\n")
        tapTrailingArea(app.buttons["receipt.sample"], in: app)
        XCTAssertTrue(app.images["receipt.preview"].waitForExistence(timeout: 15))
        let save = app.buttons["claim.save"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 20), .completed)
        let detectedAmount = app.textFields["claim.amount"]
        reveal(detectedAmount, in: app)
        XCTAssertEqual(detectedAmount.value as? String, "12.5")
        save.tap()
        let failure = app.staticTexts["Receipt upload unavailable. Try again."]
        reveal(failure, in: app); XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["receipt.preview"].exists)
        attach("Receipt retained after upload failure", app: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Photo QA"].waitForExistence(timeout: 5))
        // A 44-point icon, so tap it directly: a fixed screen-width offset misses it on wider phones.
        let actions = app.buttons["Food claim actions: Photo QA"]; reveal(actions, in: app); actions.tap()
        XCTAssertTrue(app.buttons["Edit claim"].waitForExistence(timeout: 5)); app.buttons["Edit claim"].tap()
        reveal(app.images["receipt.preview"], in: app); XCTAssertTrue(app.images["receipt.preview"].waitForExistence(timeout: 10))
        attach("Private receipt attachment", app: app)
        tapTrailingArea(app.buttons["receipt.view"], in: app)
        XCTAssertTrue(app.images["receipt.fullImage"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["receipt.download"], in: app)
        XCTAssertTrue(app.staticTexts["receipt.saved"].waitForExistence(timeout: 5))
        attach("Receipt downloaded and verified in Files", app: app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["claim.save"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["receipt.remove"], in: app); save.tap()
        XCTAssertTrue(app.staticTexts["Photo QA"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEventSummaryUsesOnlyReimbursementsAndKeepsWorkPay() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        app.buttons["nav.earnings"].tap()
        tapTrailingArea(app.staticTexts["Wedding reception"].firstMatch, in: app)
        let net = app.staticTexts["event.netWork"]
        reveal(net, in: app); XCTAssertTrue(net.label.contains("400.00"))
        XCTAssertFalse(app.staticTexts["Personal expenses"].exists)
        XCTAssertFalse(app.buttons["Add personal expense"].exists)
        attach("Event earnings and reimbursements", app: app)
    }

    @MainActor
    func testPublicTransportRoutePreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-travel", "--ui-test-transit"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Time to leave"], in: app)
        tapTrailingArea(app.buttons["travel.check"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "From: Singapore Botanic Gardens")).firstMatch.waitForExistence(timeout: 10))
        attach("Public transport departure preview", app: app)
    }

    @MainActor
    func testLiveAppleTransitEstimateFromPublicSingaporePlaces() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-live-transit"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Time to leave"], in: app)
        tapTrailingArea(app.buttons["travel.check"], in: app)
        let estimate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "From: ")).firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 40))
        attach("Live Apple Maps public transit estimate", app: app)
    }

    @MainActor
    func testPublicTransportReminderAppearsWithAppClosedAndOpensDirections() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "--ui-test-travel", "--ui-test-transit", "--ui-test-transit-notification", "--ui-test-notifications"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Time to leave"], in: app)
        tapTrailingArea(app.buttons["Enable iPhone notifications"], in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 2) { springboard.alerts.buttons["Allow"].tap() }
        tapTrailingArea(app.buttons["travel.testPlan"], in: app)
        let planned = app.staticTexts["1 planned transit reminder."]
        reveal(planned, in: app); XCTAssertTrue(planned.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let banner = springboard.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Time to leave for public transport")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25))
        attach("Public transit reminder while HowMuch is closed", app: springboard)
        banner.tap()
        XCTAssertTrue(app.buttons["Open route in Apple Maps"].waitForExistence(timeout: 8))
        attach("Transit notification opens owned job directions", app: app)
    }

    @MainActor
    func testFreshSystemNotificationIcon() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-account", "--ui-test-notifications"]
        app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5))
        app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Job notifications"], in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Enable only appears before permission is chosen; a simulator that already allowed it goes straight to "on".
        let enable = app.buttons["notifications.enable"]
        if enable.waitForExistence(timeout: 3) {
            tapTrailingArea(enable, in: app)
            let allow = springboard.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        let status = app.descendants(matching: .any).matching(identifier: "notifications.deliveryStatus").firstMatch
        reveal(status, in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "Notifications are on").evaluate(with: status) || app.staticTexts["Notifications are on"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["notifications.test"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Test scheduled in 5 seconds")).firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.staticTexts["HowMuch reminders are ready"].waitForExistence(timeout: 12))
        Thread.sleep(forTimeInterval: 1) // Let the system banner finish its entrance animation before visual inspection.
        attach("Fresh system notification with H app icon", app: springboard)
    }

    @MainActor
    func testNotificationPreviewPrivacyAndTestButton() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Job notifications"], in: app)
        let details = app.switches["notifications.details"]
        reveal(details, in: app)
        if details.value as? String == "1" { details.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        reveal(app.staticTexts["Open HowMuch for your location and job details."], in: app)
        XCTAssertTrue(app.staticTexts["Open HowMuch for your location and job details."].exists)
        for _ in 0..<4 { app.swipeDown() }
        reveal(details, in: app)
        details.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: details)], timeout: 3), .completed)
        app.swipeUp()
        XCTAssertFalse(app.staticTexts["Open HowMuch for your location and job details."].exists)
        tapTrailingArea(app.buttons["notifications.test"], in: app)
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Enable notifications above first", "Test scheduled in 5 seconds")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        attach("Notification privacy preview and test", app: app)
    }

    @MainActor
    func testMultipleStartReminderChoicesPersistTogether() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.settings"].waitForExistence(timeout: 5)); app.buttons["nav.settings"].tap()
        tapTrailingArea(app.staticTexts["Job notifications"], in: app)
        for minutes in [120, 60, 0] {
            let option = app.switches["notifications.start.\(minutes)"]
            reveal(option, in: app)
            XCTAssertTrue(option.isHittable)
            // A slow simulator can drop the first tap; wait for the switch, and try once more if it didn't turn on.
            for _ in 0..<2 where option.value as? String != "1" {
                option.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: option)], timeout: 2)
            }
            XCTAssertEqual(option.value as? String, "1")
        }
        tapTrailingArea(app.buttons["notifications.save"], in: app)
        XCTAssertTrue(app.alerts["Preferences saved"].waitForExistence(timeout: 5)); app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        tapTrailingArea(app.staticTexts["Job notifications"], in: app)
        for minutes in [120, 60, 30, 0] {
            let option = app.switches["notifications.start.\(minutes)"]; reveal(option, in: app)
            XCTAssertEqual(option.value as? String, "1", "Multiple start times must be saved together")
        }
        attach("Multiple reminder times selected", app: app)
    }

    @MainActor
    func testCabClaimRedesignEditDeleteAndUndo() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["nav.earnings"].waitForExistence(timeout: 5)); app.buttons["nav.earnings"].tap()
        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 5))
        attach("Clean event cards", app: app)
        tapTrailingArea(app.staticTexts["Roadshow"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Roadshow"].waitForExistence(timeout: 5))
        tapTrailingArea(app.buttons["Add claim"], in: app)
        XCTAssertTrue(app.textFields["claim.amount"].waitForExistence(timeout: 5))
        attach("Clean cab claim editor", app: app)
        app.textFields["claim.amount"].tap(); app.textFields["claim.amount"].typeText("12.34")
        app.textFields["claim.note"].tap(); app.textFields["claim.note"].typeText("QA cab ride")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["QA cab ride"].waitForExistence(timeout: 5))
        for _ in 0..<4 { app.swipeDown() }
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "claim.actions.")).firstMatch
        reveal(menu, in: app)
        let identity = menu.identifier
        menu.tap(); app.buttons["Edit claim"].tap()
        let amount = app.textFields["claim.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (amount.value as? String ?? "").count))
        amount.typeText("0"); app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Enter an amount of at least 0.01."].waitForExistence(timeout: 5))
        amount.tap(); amount.typeText(XCUIKeyboardKey.delete.rawValue + "18.75")
        let note = app.textFields["claim.note"]; note.tap()
        note.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (note.value as? String ?? "").count)); note.typeText("QA cab ride updated")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["QA cab ride updated"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "claim.actions.")).count, 1)
        XCTAssertTrue(app.buttons[identity].exists, "Editing must keep the existing claim identity")
        XCTAssertTrue(app.staticTexts["SGD 178.75"].exists)
        attach("Updated cab reimbursement", app: app)
        reveal(app.buttons[identity], in: app); app.buttons[identity].tap(); app.buttons["Delete claim"].tap()
        app.buttons["Delete claim"].tap()
        XCTAssertTrue(app.staticTexts["QA cab ride updated"].waitForNonExistence(timeout: 5))
        tapTrailingArea(app.buttons["Undo last change"], in: app)
        XCTAssertTrue(app.staticTexts["QA cab ride updated"].waitForExistence(timeout: 5))
    }

}

private extension XCUIElement {
    /// True once this field has keyboard focus.
    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: self)], timeout: timeout) == .completed
    }
}

private extension XCUIElement {
    /// True once this element's value matches.
    func waitForValue(_ value: String, timeout: TimeInterval) -> Bool {
        let matches = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: matches, object: self)], timeout: timeout) == .completed
    }
}
