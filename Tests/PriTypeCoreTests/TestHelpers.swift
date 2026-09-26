import Testing
import Cocoa
@testable import PriTypeCore

// MARK: - Shared Test Helpers

/// Mock implementation of ConfigurationProviding for tests
final class MockConfiguration: ConfigurationProviding, @unchecked Sendable {
    var toggleKey: ToggleKey = .rightCommand
    var rightCommandAsToggle: Bool { true }
    var controlSpaceAsToggle: Bool { false }
    var capsLockInputSourceSwitchEnabled: Bool { false }
    var doubleSpacePeriodEnabled: Bool { true }
    var toggleExcludedBundleIDs: [String] = []
}

/// Mock implementation of HangulComposerDelegate for tests
final class MockComposerDelegate: HangulComposerDelegate {
    var insertedTexts: [String] = []
    var markedText: String = ""
    var fullText: String = ""
    /// Ordered log of delegate calls across insertText/setMarkedText, e.g.
    /// ["insert:아", "mark:나"]. Used to assert the commit-before-mark invariant.
    var orderedCalls: [String] = []
    /// Ordered record of the decomposed-syllable rewrite requests.
    var precomposeRequests: [Bool] = []
    var forgetPrecomposedCount = 0
    var resumePrecomposingCount = 0
    var backspaceCompositionUpdateDepth = 0
    var backspaceCompositionUpdateCallCount = 0
    var markedTextDuringBackspaceUpdates: [String] = []
    var shouldPassThroughBackspaceAfterClearingComposition = false
    var passThroughBackspaceAfterClearingCompositionCallCount = 0
    
    func insertText(_ text: String) {
        insertedTexts.append(text)
        orderedCalls.append("insert:\(text)")
        markedText = ""
        fullText.append(text)
    }

    func setMarkedText(_ text: String) {
        orderedCalls.append("mark:\(text)")
        markedText = text
        if backspaceCompositionUpdateDepth > 0 {
            markedTextDuringBackspaceUpdates.append(text)
        }
    }

    func beginBackspaceCompositionUpdate() {
        backspaceCompositionUpdateDepth += 1
        backspaceCompositionUpdateCallCount += 1
    }

    func endBackspaceCompositionUpdate() {
        backspaceCompositionUpdateDepth -= 1
    }

    func prepareForSystemBackspaceAfterClearingComposition() -> Bool {
        passThroughBackspaceAfterClearingCompositionCallCount += 1
        guard shouldPassThroughBackspaceAfterClearingComposition else {
            return false
        }
        markedText = ""
        return true
    }
    
    func precomposeSyllableBeforeCursor(followsBackspace: Bool) {
        precomposeRequests.append(followsBackspace)
    }

    func forgetLastPrecomposedSyllable() {
        forgetPrecomposedCount += 1
    }

    func resumePrecomposing() {
        forgetPrecomposedCount += 1
        resumePrecomposingCount += 1
    }

    func textBeforeCursor(length: Int) -> String? {
        if fullText.isEmpty { return "" }
        let count = fullText.count
        let start = max(0, count - length)
        let startIndex = fullText.index(fullText.startIndex, offsetBy: start)
        return String(fullText[startIndex...])
    }
    
    /// Set to make the mock stand in for a host that reports no usable caret
    /// (Google Docs, a terminal): it confirms nothing, so it is never edited.
    var reportsNoUsableCaret = false
    /// Ordered record of what each replacement asked the host to confirm.
    var verifiedContexts: [String] = []

    func replaceTextBeforeCursor(length: Int, with text: String, verifying context: String) -> TextReplacementResult {
        verifiedContexts.append(context)
        guard !reportsNoUsableCaret, fullText.hasSuffix(context), fullText.count >= length else {
            return .unavailable
        }
        fullText.removeLast(length)
        fullText.append(text)
        return .issued
    }
    
    func reset() {
        insertedTexts = []
        markedText = ""
        fullText = ""
        orderedCalls = []
        backspaceCompositionUpdateDepth = 0
        backspaceCompositionUpdateCallCount = 0
        markedTextDuringBackspaceUpdates = []
        shouldPassThroughBackspaceAfterClearingComposition = false
        passThroughBackspaceAfterClearingCompositionCallCount = 0
        precomposeRequests = []
        forgetPrecomposedCount = 0
        resumePrecomposingCount = 0
        reportsNoUsableCaret = false
        verifiedContexts = []
    }
}

/// Factory for creating NSEvent instances in tests
enum TestEventFactory {
    static func keyEvent(
        char: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown,
        timestamp: TimeInterval = 0,
        isARepeat: Bool = false
    ) -> NSEvent? {
        return NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: char,
            charactersIgnoringModifiers: char,
            isARepeat: isARepeat,
            keyCode: keyCode
        )
    }
}
