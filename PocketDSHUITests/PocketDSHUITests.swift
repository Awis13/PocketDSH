import XCTest

final class PocketDSHUITests: XCTestCase {
    @MainActor
    func testMarkdownTable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DSH_MARKDOWN_PREVIEW"] = """
        Прогноз на неделю (Прага, Open-Meteo):

        | День | Погода | T° | Осадки |
        |---|---|---:|---:|
        | Пн 07.09 | 🌫️ туман | 7…22°C | 0 мм |
        | Вт 08.09 | 🌫️ туман | 11…31°C | 0 мм |
        | Ср 09.09 | 🌧️ дождь | 15…24°C | 5 мм (75%) |
        | Чт 10.09 | ☁️ пасмурно | 12…19°C | 0 мм (39%) |
        | Пт 11.09 | ☁️ пасмурно | 11…18°C | 0 мм |
        | Сб 12.09 | ☁️ пасмурно | 10…22°C | 0 мм |
        | Вс 13.09 | 🌫️ туман | 7…24°C | 0 мм |

        Кратко: сегодня–завтра **тепло и сухо**, в среду дождь.
        """
        app.launch()
        let table = app.scrollViews["markdownTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["|---|---|---:|---:|"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Markdown weather table"; image.lifetime = .keepAlways; add(image)
        table.swipeLeft()
        let end = XCTAttachment(screenshot: app.screenshot()); end.name = "Table horizontal scroll"; end.lifetime = .keepAlways; add(end)
    }
    @MainActor
    func testAgentImageOutput() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Agent image output check")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        let image = app.buttons["Open image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30))
        let inline = XCTAttachment(screenshot: app.screenshot()); inline.name = "Agent image inline"; inline.lifetime = .keepAlways; add(inline)
        image.tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        let full = XCTAttachment(screenshot: app.screenshot()); full.name = "Agent image fullscreen"; full.lifetime = .keepAlways; add(full)
        app.buttons["Close image"].tap()
    }
    @MainActor
    func testExpressiveThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for name in ["pixel", "glass", "hacker"] {
            app.launch()
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
            app.buttons["Appearance"].tap()
            let option = app.buttons["theme-" + name]
            for _ in 0..<4 { if option.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(option.isHittable); option.tap()
            XCTAssertTrue(option.isSelected)
            app.buttons["Done"].tap()
            let home = XCTAttachment(screenshot: app.screenshot()); home.name = name + "-home"; home.lifetime = .keepAlways; add(home)
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
            app.buttons["Appearance"].tap()
            for _ in 0..<4 { if option.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(option.isSelected, "Theme survives relaunch")
            app.buttons["Done"].tap()
            let search = app.textFields["sessionSearch"]
            search.tap(); search.typeText("Model selection check")
            let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
            XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
            XCTAssertTrue(app.buttons["voiceRecord"].waitForExistence(timeout: 15))
            let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = name + "-chat"; chat.lifetime = .keepAlways; add(chat)
            app.terminate()
        }
    }
    @MainActor
    func testVoiceRecordingCanBeCancelled() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Model selection check")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        let voice = app.buttons["voiceRecord"]
        XCTAssertTrue(voice.waitForExistence(timeout: 15)); XCTAssertTrue(voice.isEnabled)
        let origin = voice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let left = origin.withOffset(CGVector(dx: -95, dy: 0))
        origin.press(forDuration: 5, thenDragTo: left)
        XCTAssertEqual(voice.label, "Hold to record")
        XCTAssertFalse(app.staticTexts["Sending…"].exists)
        XCTAssertFalse(app.staticTexts["Transcribing…"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Voice swipe cancelled"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.staticTexts["voiceError"].exists)
    }
    @MainActor
    func testFollowBottomAndManualHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Model selection check")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        let scroll = app.scrollViews["transcriptScroll"]
        let bottom = app.descendants(matching: .any)["transcriptBottom"].firstMatch
        func verifyBottom() {
            let visible = NSPredicate { _, _ in
                guard bottom.exists, scroll.exists else { return false }
                let marker = bottom.frame, viewport = scroll.frame
                return marker.minY >= viewport.minY && marker.maxY <= viewport.maxY + 2
            }
            expectation(for: visible, evaluatedWith: nil)
            waitForExpectations(timeout: 15)
        }
        verifyBottom()
        scroll.swipeDown()
        let resume = app.buttons["Jump to latest message"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        verifyBottom()
        app.textFields["composer"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        verifyBottom()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Bottom follows keyboard"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testLiveReasoningWindow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Model selection check")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        let composer = app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        if !app.buttons["Stop agent"].exists {
        composer.tap()
        composer.typeText("Find the smallest positive integer divisible by 12, 15, 18 and 28. Verify the result mentally and give a short answer. Do not use tools or change files.")
        app.buttons["sendPrompt"].tap()
        }
        let reasoning = app.staticTexts["Thinking"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 120))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Live reasoning window"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(reasoning.waitForNonExistence(timeout: 120))
    }
    @MainActor
    func testPhotoDraftAndSend() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Image upload check · shapes")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        XCTAssertTrue(app.buttons["attachPhoto"].waitForExistence(timeout: 15))
        while app.buttons["Remove image"].firstMatch.exists { app.buttons["Remove image"].firstMatch.tap() }
        app.buttons["attachPhoto"].tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Remove image"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["sendPrompt"].isEnabled)
        app.buttons["sendPrompt"].tap()
        XCTAssertTrue(app.buttons["Remove image"].firstMatch.waitForNonExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Photo sent in Dracula"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testAppearanceAndImages() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Appearance"].waitForExistence(timeout: 15))
        app.buttons["Appearance"].tap()
        for name in ["dark", "nord", "dracula"] {
            let option = app.buttons["theme-" + name]
            if !option.isHittable { app.swipeUp() }
            option.tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Theme " + name; shot.lifetime = .keepAlways; add(shot)
        }
        app.buttons["Done"].tap()
        app.terminate(); app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Image upload check · shapes")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        let image = app.buttons["Open image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30))
        image.tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 10))
        app.buttons["Close image"].tap()
        app.buttons["attachPhoto"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        // iOS 26 PhotosPicker exposes thumbnails with incorrect isHittable values.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Remove image"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["sendPrompt"].isEnabled, "Image-only prompt can be sent")
        app.buttons["Remove image"].firstMatch.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Dracula image conversation"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testLiveSessionSearchHistoryAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let search = app.textFields["sessionSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Pocket DSH")
        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.tap()
        XCTAssertTrue(app.staticTexts["POCKET_OK"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields["composer"].exists || app.textViews["composer"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native DSH live conversation"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch()
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap(); search.typeText("Pocket DSH")
        XCTAssertTrue(session.waitForExistence(timeout: 15)); session.tap()
        XCTAssertTrue(app.staticTexts["POCKET_OK"].waitForExistence(timeout: 30))
    }
}
