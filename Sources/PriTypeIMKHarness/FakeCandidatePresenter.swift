import Cocoa
import PriTypeCore

/// Stands in for the Hanja candidate window: records what the composer shows
/// and answers keys the way the window does, without opening a panel.
public final class FakeCandidatePresenter: HanjaCandidatePresenting, @unchecked Sendable {
    /// The candidates on show, in order; empty when nothing is shown.
    public private(set) var entries: [HanjaEntry] = []
    public private(set) var isVisible = false

    private var onSelect: (@Sendable (HanjaEntry) -> Void)?
    private var onDismiss: (@Sendable () -> Void)?

    public init() {}

    public func show(
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void
    ) {
        self.entries = entries
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        isVisible = !entries.isEmpty
    }

    public func dismiss() {
        let callback = onDismiss
        close()
        callback?()
    }

    /// As the window: 1–9 choose on the first page, Return the first, Escape
    /// closes, paging keys are consumed, and any other key closes the
    /// candidates and goes on to be typed.
    public func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        if let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
           (1...9).contains(digit), digit <= entries.count {
            choose(digit)
            return true
        }
        switch event.keyCode {
        case 36, 76:                    // Return, keypad Enter
            choose(1)
            return true
        case 53:                        // Escape
            dismiss()
            return true
        case 125, 126, 48, 30, 33:      // ↓ ↑ Tab ] [
            return true
        default:
            dismiss()
            return false
        }
    }

    /// Choose the candidate numbered `number` (1-based, across pages), as a
    /// click on it would.
    public func choose(_ number: Int) {
        let entry = entries[number - 1]
        let callback = onSelect
        // The window reports the selection before it hides.
        callback?(entry)
        close()
    }

    private func close() {
        entries = []
        isVisible = false
        onSelect = nil
        onDismiss = nil
    }
}
