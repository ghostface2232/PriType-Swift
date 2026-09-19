import Foundation
import Testing
@testable import PriTypeCore

// MARK: - TextConvenienceHandler Tests

@Suite("TextConvenienceHandler")
struct TextConvenienceHandlerTests {
    
    // MARK: - Double Space Period Tests
    
    @Test("Double space converts to period")
    func doubleSpacePeriodConversion() {
        let handler = TextConvenienceHandler(isDoubleSpacePeriodEnabled: { true })
        let delegate = MockComposerDelegate()
        delegate.fullText = "Hello "
        var buffer = "Hello "
        
        _ = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
        let result = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
        
        #expect(result == .convertedToPeriod)
        #expect(delegate.fullText.hasSuffix(". "))
    }
    
    @Test("Normal space does not convert")
    func normalSpaceDoesNotConvert() {
        let handler = TextConvenienceHandler()
        let delegate = MockComposerDelegate()
        delegate.fullText = "Hello"
        var buffer = "Hello"
        
        let result = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
        
        #expect(result == .normalSpace)
    }
    
    @Test("Reset space state prevents conversion")
    func resetSpaceState() {
        let handler = TextConvenienceHandler()
        let delegate = MockComposerDelegate()
        delegate.fullText = "Hello "
        var buffer = "Hello "
        _ = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
        
        handler.resetSpaceState()
        
        let result = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
        #expect(result == .normalSpace)
    }
    
    @Test("Double space after Hangul converts to period")
    func doubleSpaceAfterHangul() {
        for text in ["한 ", "ㅎ "] {
            let handler = TextConvenienceHandler(isDoubleSpacePeriodEnabled: { true })
            let delegate = MockComposerDelegate()
            delegate.fullText = text
            var buffer = text
            _ = handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate)
            #expect(handler.handleDoubleSpacePeriod(buffer: &buffer, delegate: delegate) == .convertedToPeriod)
        }
    }

    // English mode performs no composition and is a pure pass-through, so it no
    // longer routes through TextConvenienceHandler. The behaviour is covered by
    // `HangulComposerTests.englishModePurePassthrough`.
}
