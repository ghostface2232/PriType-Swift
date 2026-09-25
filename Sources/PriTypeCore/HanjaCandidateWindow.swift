import Cocoa
import SwiftUI
import os

/// Where `HangulComposer` shows Hanja candidates. The app uses
/// `HanjaCandidateWindow`; the IMK harness substitutes one that records the
/// candidates, so tests drive a selection without opening a panel.
public protocol HanjaCandidatePresenting: AnyObject {
    var isVisible: Bool { get }
    /// `onClickOutside` runs, after `onDismiss`, when a click anywhere but the
    /// candidates closed them: the caret may have moved.
    func show(
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void,
        onClickOutside: @escaping @Sendable () -> Void
    )
    func dismiss()
    /// A key the input method received while the candidates are up.
    /// Returns whether the candidates consumed it.
    func handleKey(_ event: NSEvent) -> Bool
}

/// Custom floating candidate window for Hanja selection
///
/// Displays a list of Hanja candidates near the text cursor position.
/// Supports keyboard navigation (1-9, arrow keys, page up/down).
public final class HanjaCandidateWindow: HanjaCandidatePresenting, @unchecked Sendable {
    
    public static let shared = HanjaCandidateWindow()
    
    private var window: NSWindow?

    /// The candidates' one SwiftUI host, made with the panel and kept with it.
    /// A page, a new lookup, hiding and showing again only replace its root
    /// view, which SwiftUI diffs into the views it already has. Building a new
    /// host every time cost 20–30 ms of main-thread layout per show and per page
    /// — keys queue behind it — and freed only about 0.7 MB when discarded.
    private var hostView: NSHostingView<HanjaCandidateView>?

    /// Where the lookup's caret is, so every page is placed against it.
    private var cursorRect: NSRect = .zero

    /// The widest page of this lookup so far. Pages never get narrower within a
    /// lookup, so flipping through them does not make the panel jump.
    private var lookupWidth: CGFloat = 0

    /// Counts lookups. The hover belongs to one lookup: a row the pointer was
    /// over when the last one closed must not come back lit.
    private var lookupNumber = 0

    private var candidates: [HanjaEntry] = []
    private var currentPage = 0
    private let pageSize = 9
    private var onSelect: (@Sendable (HanjaEntry) -> Void)?
    private var onDismiss: (@Sendable () -> Void)?
    private var onClickOutside: (@Sendable () -> Void)?
    
    public var isVisible: Bool {
        MainActor.assumeIsolated {
            window?.isVisible ?? false
        }
    }

    /// How many candidates the shown page has (0: no window), readable from any
    /// thread.
    ///
    /// The event tap consults it on every keyDown so it can route candidate keys
    /// itself. Some clients never hand those keys to the input method: once the
    /// syllable is committed for the lookup, Terminal sends Escape, the arrows
    /// and Return straight to the shell — Return would run the command line
    /// instead of choosing a candidate. The count, not just a flag, because a
    /// digit past the page's last candidate is not a candidate key: the tap must
    /// let it through. Set whenever a page is drawn, cleared on every dismissal.
    private static let pageCandidatesState = OSAllocatedUnfairLock(initialState: 0)
    public static var shownPageCandidates: Int { pageCandidatesState.withLock { $0 } }
    static func setShownPageCandidates(_ count: Int) { pageCandidatesState.withLock { $0 = count } }

    /// Watches for clicks outside the panel while it is up (`watchClicks`).
    private var clickMonitor: Any?

    private init() {}
    
    /// Show the candidate window with the given entries
    /// - Parameters:
    ///   - entries: Array of HanjaEntry to display
    ///   - cursorRect: The rect near the text cursor to position the window
    ///   - onSelect: Callback when a candidate is selected
    ///   - onDismiss: Callback when the window is dismissed
    ///   - onClickOutside: Callback, after `onDismiss`, when a click outside closed it
    public func show(
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void,
        onClickOutside: @escaping @Sendable () -> Void
    ) {
        MainActor.assumeIsolated {
            showOnMain(
                entries: entries,
                cursorRect: cursorRect,
                onSelect: onSelect,
                onDismiss: onDismiss,
                onClickOutside: onClickOutside
            )
        }
    }

    @MainActor
    private func showOnMain(
        entries: [HanjaEntry],
        cursorRect: NSRect,
        onSelect: @escaping @Sendable (HanjaEntry) -> Void,
        onDismiss: @escaping @Sendable () -> Void,
        onClickOutside: @escaping @Sendable () -> Void
    ) {
        self.candidates = entries
        self.currentPage = 0
        self.cursorRect = cursorRect
        self.lookupWidth = 0
        self.lookupNumber &+= 1
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.onClickOutside = onClickOutside
        
        guard !entries.isEmpty else {
            dismiss()
            return
        }
        
        // Reuse existing panel or create a new one
        let panel: NSPanel
        if let existing = window as? NSPanel {
            panel = existing
        } else {
            panel = CandidatePanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 0),
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            
            let host = NSHostingView(rootView: HanjaCandidateView.empty)
            // The panel is sized here (`updateContent`), from the host's
            // intrinsic size. Its min/max constraints are off: they would size
            // the panel to each page and shrink it back below the width this
            // lookup has reached.
            host.sizingOptions = [.intrinsicContentSize]

            // The backdrop of the system's context menus, as a real one is
            // built: on macOS 26 and later an `NSGlassEffectView` with the
            // menu's radius (read from an `NSPopupMenuWindow`), before that the
            // `.menu` material. The glass only looks like a menu's in a window
            // drawn as active — see `CandidatePanel`.
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = Self.cornerRadius
                glass.contentView = host
                panel.contentView = glass
            } else {
                let backdrop = NSVisualEffectView()
                backdrop.material = .menu
                backdrop.blendingMode = .behindWindow
                backdrop.state = .active
                backdrop.maskImage = Self.roundedMask(radius: Self.cornerRadius)
                host.frame = backdrop.bounds
                host.autoresizingMask = [.width, .height]
                backdrop.addSubview(host)
                panel.contentView = backdrop
            }
            self.hostView = host

            self.window = panel
        }
        
        updateContent()
        panel.orderFrontRegardless()
        watchClicks()

        DebugLogger.log("Hanja: Window shown at \(panel.frame), level=\(panel.level.rawValue)")
    }
    
    /// Dismiss the candidate window (hides without destroying)
    public func dismiss() {
        MainActor.assumeIsolated {
            dismissOnMain()
        }
    }

    /// Close the candidates on a click anywhere but the panel. A click moves the
    /// caret without telling the input method: the lookup committed the
    /// syllable, and with nothing marked IMK sends no commit. Left open, the
    /// candidates would take the next digit and replace the text before the new
    /// caret. A global monitor sees only other apps' events, so clicks on the
    /// panel's own candidates never reach it.
    @MainActor
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DebugLogger.log("Hanja: click outside the candidates")
            guard let self else { return }
            let clickedOutside = self.onClickOutside
            self.dismiss()
            clickedOutside?()
        }
    }

    @MainActor
    private func stopWatchingClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    @MainActor
    private func dismissOnMain() {
        let dismissCallback = onDismiss
        hide()
        dismissCallback?()
    }

    /// Everything closing the window undoes, on every path. The panel and its
    /// host are kept for the next lookup; the host keeps drawing the last page
    /// while hidden, which nothing sees. It is not emptied here: a click on a
    /// candidate gets here from inside that candidate's button action, and the
    /// view handling the event must outlive it.
    @MainActor
    private func hide() {
        Self.setShownPageCandidates(0)
        stopWatchingClicks()
        window?.orderOut(nil)
        candidates = []
        currentPage = 0
        onSelect = nil
        onDismiss = nil
        onClickOutside = nil
    }
    
    /// Handle a key event while the candidate window is visible
    /// - Returns: true if the event was consumed
    public func handleKey(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let digit = event.charactersIgnoringModifiers?.first?.wholeNumberValue

        return MainActor.assumeIsolated {
            handleKeyOnMain(keyCode: keyCode, digit: digit)
        }
    }

    /// Apply a candidate key routed by the event tap. Main thread only.
    public func handleRoutedKey(keyCode: UInt16, digit: Int?) {
        MainActor.assumeIsolated {
            _ = handleKeyOnMain(keyCode: keyCode, digit: digit)
        }
    }

    /// How the event tap treats a keyDown while candidates are showing.
    public enum RoutedKey: Equatable {
        /// Handle it in the window and keep it from the app (select, page, close).
        case consume(digit: Int?)
        /// Close the window and let the app have the key (caret movement).
        case dismissAndPass
        /// Not a candidate key; leave it to the input-method path.
        case ignore
    }

    private static let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                                  83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]

    /// Candidate-key routing by physical key, so digits work on any layout
    /// (AZERTY types them only with Shift). Keys with Command, Control or Option
    /// are shortcuts and are never routed. A digit with no candidate on the page
    /// closes the window and reaches the app, as it does on the IMK path.
    public static func route(keyCode: Int64, flags: CGEventFlags, pageCandidates: Int) -> RoutedKey {
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return .ignore }
        if let digit = digitKeys[keyCode], !flags.contains(.maskShift) {
            return digit <= pageCandidates ? .consume(digit: digit) : .dismissAndPass
        }
        switch keyCode {
        case 53, 36, 76, 125, 126, 48, 30, 33: return .consume(digit: nil)   // Esc Return Enter ↓ ↑ Tab ] [
        case 123, 124: return .dismissAndPass                                 // ← →
        default: return .ignore
        }
    }

    @MainActor
    private func handleKeyOnMain(keyCode: UInt16, digit: Int?) -> Bool {
        guard isVisible else { return false }

        // ESC -> dismiss
        if keyCode == 53 { // Escape
            dismiss()
            return true
        }
        
        // Number keys 1-9 -> select
        if let digit, digit >= 1 && digit <= 9 {
            let index = (currentPage * pageSize) + (digit - 1)
            if index < candidates.count {
                selectCandidate(at: index)
                return true
            }
        }
        
        // Enter -> select first on current page
        if keyCode == 36 || keyCode == 76 { // Return / Numpad Enter
            let index = currentPage * pageSize
            if index < candidates.count {
                selectCandidate(at: index)
                return true
            }
        }
        
        // Arrow Down / Tab -> next page
        if keyCode == 125 || keyCode == 48 { // Down arrow / Tab
            if (currentPage + 1) * pageSize < candidates.count {
                currentPage += 1
                updateContent()
            }
            return true
        }
        
        // Arrow Up -> previous page
        if keyCode == 126 { // Up arrow
            if currentPage > 0 {
                currentPage -= 1
                updateContent()
            }
            return true
        }
        
        // ] -> next page
        if keyCode == 30 { // ]
            if (currentPage + 1) * pageSize < candidates.count {
                currentPage += 1
                updateContent()
            }
            return true
        }
        
        // [ -> previous page
        if keyCode == 33 { // [
            if currentPage > 0 {
                currentPage -= 1
                updateContent()
            }
            return true
        }
        
        // Any other key -> dismiss and don't consume
        dismiss()
        return false
    }
    
    // MARK: - Private
    
    @MainActor
    private func selectCandidate(at index: Int) {
        guard index < candidates.count else { return }
        let entry = candidates[index]
        // Select, then hide without onDismiss: the selection did the cleanup.
        onSelect?(entry)
        hide()
    }

    /// Draw the current page into the kept host, size the panel to it and
    /// place it against the lookup's caret. Placed on every page, not only on
    /// show: a wider page must be clamped to the screen too.
    @MainActor
    private func updateContent() {
        guard let window, let hostView else { return }

        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, candidates.count)
        let pageEntries = Array(candidates[startIndex..<endIndex])
        let totalPages = (candidates.count + pageSize - 1) / pageSize
        Self.setShownPageCandidates(pageEntries.count)

        hostView.rootView = HanjaCandidateView(
            lookup: lookupNumber,
            entries: pageEntries,
            currentPage: currentPage + 1,
            totalPages: totalPages,
            onSelect: { [weak self] index in
                guard let self else { return }
                self.selectCandidate(at: self.currentPage * self.pageSize + index)
            }
        )

        let fitting = hostView.intrinsicContentSize
        lookupWidth = max(lookupWidth, fitting.width)
        window.setContentSize(NSSize(width: lookupWidth, height: fitting.height))
        positionWindow(near: cursorRect)
    }
    
    @MainActor
    private func positionWindow(near cursorRect: NSRect) {
        guard let window = window else { return }
        let windowSize = window.frame.size

        // Pick the screen that actually contains the caret so multi-monitor placement
        // is exact; clamp to its visibleFrame (excludes menu bar / Dock).
        let anchor = NSPoint(x: cursorRect.minX, y: cursorRect.minY)
        let activeScreen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.main
        var origin = Self.panelOrigin(
            caret: cursorRect,
            panelSize: windowSize,
            visibleFrame: activeScreen?.visibleFrame
        )

        // Snap to whole DEVICE pixels so the panel and its text render crisply
        // (sub-pixel origins blur the glass/text on Retina).
        let scale = activeScreen?.backingScaleFactor ?? 1
        if scale > 0 {
            origin.x = (origin.x * scale).rounded() / scale
            origin.y = (origin.y * scale).rounded() / scale
        }

        window.setFrameOrigin(origin)
    }

    /// Corner radius of the system's menus: larger since macOS 26.
    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 12 }
        return 6
    }

    /// A stretchable rounded-rectangle mask for the pre-26 backdrop. A
    /// `.behindWindow` effect view clips its blur to this, and the window
    /// shadow follows its shape.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Vertical clearance between the caret line and the panel.
    static let verticalGap: CGFloat = 6

    /// Horizontal space between the converted syllable and the panel's left edge.
    static let horizontalGap: CGFloat = 4

    /// Where the candidate panel goes for a caret rect (screen coordinates,
    /// bottom-left origin). Pure so it can be tested without a window.
    ///
    /// Measured on macOS 27, the rect clients report through IMK sits one glyph
    /// height ABOVE the text actually drawn: in Notes the reported rect spanned
    /// y 1874–1897 while the line's centre was at 1862. Placing the panel under
    /// `minY` therefore covered the line being written — in Notes, TextEdit,
    /// Terminal and KakaoTalk alike. So the panel clears one extra caret height:
    /// under a rect that is right it just sits a line lower, under a shifted one
    /// it sits directly below the text, and in neither case does it cover it. It
    /// starts right of the syllable being converted. With no room below it flips
    /// above the reported rect, which is above the text either way.
    static func panelOrigin(caret: NSRect, panelSize: NSSize, visibleFrame: NSRect?) -> NSPoint {
        var origin = NSPoint(
            x: caret.maxX + horizontalGap,
            y: caret.minY - caret.height - panelSize.height - verticalGap
        )
        guard let screen = visibleFrame else { return origin }

        // No room below → flip to above the line.
        if origin.y < screen.minY {
            origin.y = caret.maxY + verticalGap
        }
        // Clamp so the panel never spills off the top or bottom edge.
        if origin.y + panelSize.height > screen.maxY {
            origin.y = screen.maxY - panelSize.height
        }
        if origin.y < screen.minY {
            origin.y = screen.minY
        }
        // Horizontal clamp.
        if origin.x + panelSize.width > screen.maxX {
            origin.x = screen.maxX - panelSize.width
        }
        if origin.x < screen.minX {
            origin.x = screen.minX
        }
        return origin
    }
}

// MARK: - SwiftUI Candidate View

private struct HanjaCandidateView: View {
    /// Which lookup this page belongs to; a new one clears the hover.
    let lookup: Int
    let entries: [HanjaEntry]
    let currentPage: Int
    let totalPages: Int
    let onSelect: (Int) -> Void

    /// The row under the pointer. Held here rather than in each row so a new
    /// lookup can clear it without rebuilding the rows (`.id` would, at ~10 ms
    /// a show); a page flip keeps it, as the pointer has not moved.
    @State private var hoveredIndex: Int?

    /// What the host starts with, before its first page.
    static let empty = HanjaCandidateView(lookup: 0, entries: [], currentPage: 1, totalPages: 1, onSelect: { _ in })

    var body: some View {
        // Laid out like a context menu: rows inset from the edge by the width
        // of their highlight, no rule between rows, one before the footer.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HanjaCandidateRow(
                    number: index + 1,
                    entry: entry,
                    isHovered: hoveredIndex == index,
                    onSelect: { onSelect(index) },
                    onHover: { hovering in
                        if hovering {
                            hoveredIndex = index
                        } else if hoveredIndex == index {
                            hoveredIndex = nil
                        }
                    }
                )
            }

            if totalPages > 1 {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                HStack(spacing: 6) {
                    Text("\(currentPage) / \(totalPages)")
                        .monospacedDigit()
                    Text("▲▼ 페이지 이동")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 3)
            }
        }
        .padding(5)
        .frame(minWidth: 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: lookup) {
            hoveredIndex = nil
        }
    }
}

private struct HanjaCandidateRow: View {
    let number: Int
    let entry: HanjaEntry
    let isHovered: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // Hanja: one character, or a whole word that must not be clipped.
                // Left-aligned, so a single character starts where 大韓民國 does.
                Text(entry.hanja)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .frame(minWidth: 24, alignment: .leading)

                Text(entry.meaning)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // No reading column: a Hanja is one syllable, so a candidate's
                // length already says how much of the typed text it replaces
                // (大韓民國, 民國, 國), and the meaning repeats the reading.
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }
}

/// The candidates' window, drawn as an active one.
///
/// Liquid Glass renders differently in an active window and an inactive one:
/// inactive, it lays a grey veil over whatever is behind it. An input method's
/// panel belongs to an app that is never active — it must not take focus from
/// the field being typed in — so its glass always had that veil, and read as
/// murky grey where a context menu is clear. The system's own menu window
/// (`NSPopupMenuWindow`) answers this by reporting an active appearance
/// whatever its key state, which is all that sets its glass apart from ours:
/// compared over the same backdrops, same class, style, tint and radius, this
/// is the difference that makes them match.
///
/// These are AppKit's private hooks, overridden by name. On a system without
/// them they are simply never called and the panel falls back to the inactive
/// look; nothing else depends on them. Focus is unaffected: the panel stays
/// non-activating and never becomes key.
private final class CandidatePanel: NSPanel {
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
}
