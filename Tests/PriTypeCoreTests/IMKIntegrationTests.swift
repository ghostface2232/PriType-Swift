import Cocoa
import Testing
@testable import PriTypeCore
import PriTypeIMKHarness

/// End-to-end runs of the real IMK controller against fake text fields
/// (`PriTypeIMKHarness`). Only key delivery and the host app are simulated.
///
/// Serialized and synchronous on main: every controller shares one composer,
/// and nothing may interleave between a test's setup and its `finish()`.
@Suite("IMK integration", .serialized)
@MainActor
struct IMKIntegrationTests {
    private typealias Call = FakeTextClient.Call

    private func start() -> (IMKHarness, IMKHarness.Field) {
        PriTypeInputController.resetSystemModeTracking()
        let harness = IMKHarness()
        let field = harness.makeField()
        harness.focus(field)
        return (harness, field)
    }

    // MARK: Commit order

    @Test("Typing composes in place, commits each syllable before marking the next, and space commits")
    func typingAndSpace() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gksrmf")
        #expect(field.client.text == "한글")
        #expect(field.client.markedText == "글")
        harness.press(.space)
        #expect(field.client.text == "한글 ")
        #expect(field.client.markedText == nil)
        #expect(field.client.calls == [
            .mark("ㅎ"), .mark("하"), .mark("한"), .insert("한"),
            .mark("ㄱ"), .mark("그"), .mark("글"), .insert("글"), .insert(" "),
        ])
    }

    @Test("Return commits the syllable, then the host breaks the line")
    func returnCommitsFirst() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        field.client.clearLog()
        #expect(!harness.press(.return))
        #expect(field.client.text == "한\n")
        #expect(field.client.calls.first == .insert("한"))
        #expect(field.client.calls.last == .host("insert(\\n)"))
    }

    @Test("Backspace takes jamo off the syllable, and the host deletes the last one")
    func backspaceToEmpty() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("dy")
        #expect(field.client.markedText == "요")
        field.client.clearLog()
        #expect(harness.press(.backspace))
        #expect(field.client.markedText == "ㅇ")
        #expect(!harness.press(.backspace))
        #expect(field.client.text.isEmpty)
        // Apple's order: commit the jamo, then the host's own deleteBackward.
        #expect(field.client.calls == [.mark("ㅇ"), .insert("ㅇ"), .host("delete(ㅇ)")])
    }

    @Test("Escape drops the composition and is consumed")
    func escapeCancels() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gk")
        #expect(harness.press(.escape))
        #expect(field.client.text.isEmpty)
        #expect(!harness.press(.escape))
        #expect(field.client.calls.last == .host("escape"))
    }

    @Test("An arrow commits, then the host moves the caret")
    func arrowCommits() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("rk")
        #expect(!harness.press(.left))
        #expect(field.client.text == "가")
        #expect(field.client.selection.location == 0)
        #expect(Array(field.client.calls.suffix(2)) == [.insert("가"), .host("left")])
    }

    @Test("A click outside commits the composition")
    func clickCommits() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gks")
        harness.click()
        #expect(field.client.markedText == nil)
        #expect(field.client.text == "한")
        harness.type("k")
        #expect(field.client.text == "한ㅏ")
    }

    @Test("The same keyDown delivered twice is processed once")
    func duplicateKeyDown() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("dy")
        let event = harness.makeEvent(keyCode: 51, characters: "\u{7F}")
        #expect(field.controller.handle(event, client: field.client))
        #expect(field.controller.handle(event, client: field.client))
        #expect(field.client.markedText == "ㅇ")
    }

    @Test("A long passage typed key by key comes out exactly, with nothing left marked")
    func passageRoundTrip() {
        let (harness, field) = start()
        defer { harness.finish() }
        let passage = "다람쥐 헌 쳇바퀴에 타고파. 키스의 고유조건은 입술끼리 만나야 하고 특별한 기술은 필요치 않다. "
            + "닭갈비와 삶은 달걀, 읽고 앉아 없는 값을 셈했다!"
        #expect(Dubeolsik.keys(for: "안녕하세요") == "dkssudgktpdy")
        harness.type(Dubeolsik.keys(for: passage))
        harness.press(.space)
        #expect(field.client.text == passage + " ")
        #expect(field.client.markedText == nil)
        #expect(harness.keyLatencies.count == Dubeolsik.keys(for: passage).count + 1)
    }

    // MARK: Mode switching

    @Test("A toggle commits the syllable, switches, reports the mode, and switches back")
    func toggleRoundTrip() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gk")
        harness.toggle()
        #expect(field.client.markedText == nil)
        #expect(field.client.text == "하")
        #expect(harness.reportedModes == [.english])
        #expect(!harness.type("gk").contains(true), "English keys pass through to the host")
        #expect(field.client.text == "하gk")
        harness.toggle()
        #expect(harness.reportedModes == [.english, .korean])
        harness.type("rk")
        #expect(field.client.text == "하gk가")
    }

    @Test("A toggle still on its way from the key monitor applies before the next key")
    func toggleBeforeNextKey() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type("gk")
        harness.toggleFromKeyMonitor()
        #expect(InputModeCoordinator.shared.pendingActionCount == 1)
        harness.type("a")
        #expect(InputModeCoordinator.shared.pendingActionCount == 0)
        #expect(field.client.text == "하a")
    }

    @Test("A key typed before the toggle stays in the old mode even if it arrives after")
    func keyBeforeToggleKeepsMode() {
        let (harness, field) = start()
        defer { harness.finish() }
        // Typed first, but still in flight to IMK when the toggle is recorded.
        let early = harness.makeEvent(keyCode: 0, characters: "a")
        harness.toggleFromKeyMonitor()
        #expect(field.controller.handle(early, client: field.client))
        #expect(field.client.markedText == "ㅁ")
        #expect(InputModeCoordinator.shared.pendingActionCount == 1)
        harness.type("a")
        #expect(field.client.text == "ㅁa")
    }

    @Test("macOS selecting the English mode (Caps Lock) commits and switches")
    func systemModeSwitch() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.systemSelects(.korean)
        harness.type("gk")
        harness.systemSelects(.english)
        #expect(field.client.text == "하")
        #expect(field.client.markedText == nil)
        harness.type("a")
        #expect(field.client.text == "하a")
        #expect(harness.reportedModes.isEmpty, "a system selection is not reported back")
    }

    @Test("Re-asserting the mode macOS already had does not undo a custom toggle")
    func reassertionIgnored() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.systemSelects(.korean)
        harness.toggle()
        // Refocus: IMK repeats the selected input source, which still says Korean.
        harness.systemSelects(.korean)
        harness.type("a")
        #expect(field.client.text == "a")
    }

    // MARK: Focus

    @Test("Moving focus commits into the field being left, never the new one")
    func focusSwitchCommitsToOldField() {
        let (harness, first) = start()
        defer { harness.finish() }
        harness.type("gk")
        let second = harness.makeField(bundleID: "com.pritype.imk-harness.other")
        harness.focus(second)
        #expect(first.client.text == "하")
        #expect(first.client.markedText == nil)
        #expect(second.client.text.isEmpty)
        harness.type("rk")
        #expect(second.client.text == "가")
        #expect(first.client.text == "하")
    }

    @Test("A late deactivation of the old controller leaves the new field's composition alone")
    func lateDeactivation() {
        let (harness, first) = start()
        defer { harness.finish() }
        let second = harness.makeField()
        harness.focus(second)
        harness.type("rk")
        first.controller.deactivateServer(first.client)
        #expect(second.client.markedText == "가")
        #expect(first.client.text.isEmpty)
        harness.type("s")
        #expect(second.client.markedText == "간")
    }

    @Test("The mode survives a focus change")
    func modeSurvivesFocus() {
        let (harness, _) = start()
        defer { harness.finish() }
        harness.toggle()
        let second = harness.makeField()
        harness.focus(second)
        harness.type("gk")
        #expect(second.client.text == "gk")
    }

    // MARK: Hanja

    @Test("The Hanja key offers the word before the caret, and a digit converts it")
    func hanjaWord() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "대한민국"))
        harness.pressHanjaKey()
        #expect(field.client.markedText == nil, "the syllable is committed for the lookup")
        #expect(harness.candidates.entries.first?.hanja == "大韓民國")
        harness.type("1")
        #expect(field.client.text == "大韓民國")
        #expect(!harness.candidates.isVisible)
    }

    @Test("A shorter ending replaces only its own syllables")
    func hanjaShorterEnding() throws {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "대한민국"))
        harness.pressHanjaKey()
        let number = try #require(harness.candidates.entries.firstIndex { $0.hanja == "國" }) + 1
        harness.candidates.choose(number)
        #expect(field.client.text == "대한민國")
        harness.type(Dubeolsik.keys(for: "가"))
        #expect(field.client.text == "대한민國가")
    }

    @Test("A one-syllable candidate chosen after the caret moved leaves the text alone")
    func hanjaAfterCaretMoved() {
        let (harness, field) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "요"))
        harness.press(.space)
        harness.type(Dubeolsik.keys(for: "한"))
        harness.pressHanjaKey()
        #expect(harness.candidates.entries.first?.hanja == "韓")
        // A click after 요: IMK tells the input method nothing, nothing is marked.
        field.client.placeCaret(at: 1)
        harness.candidates.choose(1)
        #expect(field.client.text == "요 한", "요 is not the 한 the candidate was looked up from")
        #expect(!harness.candidates.isVisible)
    }

    @Test("A lookup in another app never joins the last syllable typed in the previous one")
    func hanjaIgnoresPreviousApp() throws {
        let (harness, first) = start()
        defer { harness.finish() }
        harness.type(Dubeolsik.keys(for: "한"))
        let second = harness.makeField(bundleID: "com.pritype.imk-harness.other")
        harness.focus(second)
        #expect(first.client.text == "한")
        harness.type(Dubeolsik.keys(for: "국"))
        harness.pressHanjaKey()
        let offered = try #require(harness.candidates.entries.first)
        #expect(offered.hangul == "국", "not 韓國 from 한 + 국")
        harness.candidates.choose(1)
        #expect(second.client.text == offered.hanja)
        #expect(first.client.text == "한")
    }
}
