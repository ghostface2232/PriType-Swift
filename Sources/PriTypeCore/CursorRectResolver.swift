import Cocoa
import InputMethodKit

// MARK: - CursorRectResolver

/// Resolves the on-screen caret position for the Hanja candidate window.
///
/// Native apps (TextEdit, Xcode) answer `IMKTextInput.firstRect` directly, but
/// Chromium/Electron hosts block or garbage the coordinate APIs while the Hanja key
/// event is being processed, so resolution runs a strategy chain (fcitx5-macos
/// inspired):
///
/// 1. `firstRect(forCharacterRange:)` on the marked (else selected) range
/// 2. `attributes(forCharacterIndex:)` at index 0, then at pos-1 — Chromium answers index 0 with the caret
/// 3. cached last-known-good position (zero-cost, window stays where it last was)
/// 4. Accessibility API (`AXSelectedTextRange` → `AXBoundsForRange`)
/// 5. mouse location (last resort)
public enum CursorRectResolver {
    /// The last position resolved for a client. When Chromium blocks coordinate
    /// queries, the same client's last position beats jumping to the mouse. It
    /// is never reused for another client: that one's caret can be in another
    /// window or on another display, and the candidates would open there.
    nonisolated(unsafe) static var lastKnownCursorRect: (client: ObjectIdentifier, rect: NSRect)?

    /// Resolve a usable caret rect for `client`, falling back through the strategy
    /// chain. Always returns SOMETHING displayable (mouse location at worst).
    /// Call BEFORE committing the preedit: Chromium updates cursor position
    /// asynchronously after commit, so post-commit queries return garbage.
    /// `accessibility` is strategy 4; tests replace it.
    static func resolve(
        client: IMKTextInput?,
        accessibility: () -> NSRect? = getCursorRectViaAccessibility
    ) -> NSRect {
        var cursorRect = NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 20, width: 0, height: 20)
        var resolved = false
        let clientID = client.map { ObjectIdentifier($0 as AnyObject) }

        if let client {
            var actualRange = NSRange()

            // Prefer markedRange during preedit. Chromium fails with garbage values
            // if we request firstRect for selectedRange while a preedit is active.
            var targetRange = client.markedRange()
            if targetRange.location == NSNotFound || targetRange.length == 0 {
                targetRange = client.selectedRange()
            }

            if targetRange.location != NSNotFound {
                // Strategy 1: firstRect — the standard IMK approach
                let rect = client.firstRect(forCharacterRange: targetRange, actualRange: &actualRange)
                if isValidCursorRect(rect) {
                    cursorRect = rect
                    resolved = true
                    DebugLogger.log("Hanja: cursor from firstRect (pre-commit): \(rect)")
                } else {
                    DebugLogger.log("Hanja: firstRect returned invalid rect for range \(targetRange): \(rect)")

                    // Strategy 2: attributes(forCharacterIndex:), index 0 first, as
                    // Squirrel, macSKK and fcitx5 ask. Measured in Google Docs (Chrome,
                    // macOS 27): every firstRect query came back as garbage, while
                    // index 0 answered with the caret itself, following it as each
                    // syllable was typed. A document index past 0 answered with one
                    // fixed spot near the window's corner — valid-looking, so it was
                    // taken, and the candidates opened there from the second line on.
                    // The previous character's document index stays as the fallback.
                    var queryIndexes = [0]
                    if targetRange.location > 1 { queryIndexes.append(targetRange.location - 1) }
                    for queryIndex in queryIndexes {
                        var lineRect = NSRect.zero
                        _ = client.attributes(forCharacterIndex: queryIndex, lineHeightRectangle: &lineRect)
                        if isValidCursorRect(lineRect) {
                            cursorRect = lineRect
                            resolved = true
                            DebugLogger.log("Hanja: cursor from attributes(idx \(queryIndex)): \(lineRect)")
                            break
                        }
                        DebugLogger.log("Hanja: attributes(idx \(queryIndex)) also invalid: \(lineRect)")
                    }
                }
            }

            // Strategy 3: this client's last-known-good position (fcitx5-style).
            // If the coordinate query failed but the same client answered before,
            // the window stays near where it last appeared — much better than
            // jumping to the mouse cursor across the screen.
            if !resolved, let cached = lastKnownCursorRect, cached.client == clientID {
                cursorRect = cached.rect
                resolved = true
                DebugLogger.log("Hanja: using this client's last-known-good position: \(cached.rect)")
            }

            // Strategy 4: AX element position (rough approximation)
            if !resolved {
                if let axRect = accessibility() {
                    cursorRect = axRect
                    resolved = true
                    DebugLogger.log("Hanja: cursor from Accessibility API: \(axRect)")
                } else {
                    DebugLogger.log("Hanja: all strategies failed, using mouse location")
                }
            }
        }

        // Cache the resolved position for this client's future fallback
        if resolved, let clientID {
            lastKnownCursorRect = (clientID, cursorRect)
        }

        return cursorRect
    }

    // MARK: - Cursor Position Validation

    /// Validate that a rect from firstRect is a usable cursor position
    /// Electron/Chromium apps can return garbage values (e.g. x=1.6e-314, y=19896)
    ///
    /// Negative coordinates are legitimate: a display left of or below the main
    /// one has them. Garbage is recognized by its form (non-finite, or within 1pt
    /// of zero on either axis — uninitialized memory such as 1.6e-314) and by
    /// lying on no display.
    ///
    /// - Parameter screens: display frames to test against; defaults to the
    ///   connected screens.
    public static func isValidCursorRect(_ rect: NSRect, screens: [NSRect]? = nil) -> Bool {
        let origin = rect.origin
        guard origin.x.isFinite, origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return false }
        // Reject negative or zero height (malformed)
        guard rect.size.height > 0 else { return false }
        // Reject near-zero coordinates: zero, tiny and subnormal values are what an
        // uninitialized query returns. Magnitude, not sign, so negative
        // coordinates on secondary displays pass.
        guard abs(origin.x) > 1, abs(origin.y) > 1 else { return false }
        // Check that the point is on a connected screen
        let frames = screens ?? NSScreen.screens.map(\.frame)
        return frames.contains { $0.contains(origin) }
    }

    // MARK: - Accessibility API Cursor Position

    /// Per call. Not measured against a real slow app: chosen to leave room for
    /// one that is merely slow (Chromium turns its accessibility support on at
    /// the first query) while a hung app costs at most about 3s — the six calls
    /// of one lookup — instead of freezing typing for over half a minute.
    private static let accessibilityTimeout: Float = 0.5

    /// Get cursor position via macOS Accessibility API
    /// Chromium/Electron apps have broken IMK firstRect but properly implement AX text attributes.
    /// Uses AXSelectedTextRange → AXBoundsForRange to get the caret's screen coordinates.
    ///
    /// - Returns: NSRect of the caret position in screen coordinates (bottom-left origin), or nil if unavailable
    private static func getCursorRectViaAccessibility() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        // Every call below is a synchronous round trip to the focused app, on the
        // main thread that all of PriType's typing runs on. The default timeout is
        // about six seconds per call, so a busy app could freeze input everywhere
        // for tens of seconds. On the system-wide element this sets the timeout for
        // every element the process creates; a caret is useless that late anyway,
        // and the mouse position is the next fallback.
        AXUIElementSetMessagingTimeout(systemWide, accessibilityTimeout)

        // Get the currently focused UI element
        var focusedElement: AnyObject?
        var focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        // Fallback: If system-wide focused element fails (common in Chromium intermittently),
        // try going through the focused application instead
        if focusResult != .success || focusedElement == nil {
            DebugLogger.log("Hanja AX: systemWide focusedElement failed (\(focusResult.rawValue)), trying app path")

            var focusedApp: AnyObject?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
               let appElement = validatedAXElement(focusedApp) {
                focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
                if focusResult != .success {
                    DebugLogger.log("Hanja AX: app focusedElement also failed (\(focusResult.rawValue))")
                    return nil
                }
            } else {
                DebugLogger.log("Hanja AX: focusedApplication also failed")
                return nil
            }
        }

        guard let axElement = validatedAXElement(focusedElement) else {
            DebugLogger.log("Hanja AX: focused value was not an AXUIElement")
            return nil
        }

        // Strategy 1: AXSelectedTextRange → AXBoundsForRange
        if let rect = getBoundsForSelectedText(axElement) {
            return rect
        }

        // Strategy 2: Use element's AXPosition + AXSize as approximation
        // The focused element itself (e.g. text area) gives us a reasonable position
        if let rect = getElementCaretPosition(axElement) {
            return rect
        }

        DebugLogger.log("Hanja AX: all strategies failed")
        return nil
    }

    /// Try to get caret bounds via AXBoundsForRange
    private static func getBoundsForSelectedText(_ axElement: AXUIElement) -> NSRect? {
        // Get the selected text range (caret position)
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue)
        guard rangeResult == .success, let rangeVal = validatedAXValue(selectedRangeValue) else {
            DebugLogger.log("Hanja AX: selectedTextRange failed (\(rangeResult.rawValue))")
            return nil
        }

        // Extract the CFRange to check if we have a zero-length selection (caret)
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal, .cfRange, &cfRange) else {
            DebugLogger.log("Hanja AX: selectedTextRange was not a CFRange")
            return nil
        }

        // If caret is at position > 0, try bounds for the character BEFORE caret
        // This often works better than bounds for a zero-length range
        let queryRange: AnyObject
        if cfRange.length == 0 && cfRange.location > 0 {
            var charRange = CFRange(location: cfRange.location - 1, length: 1)
            // AXValueCreate is effectively non-nil for a valid CFRange, but fall
            // back to the original range instead of force-unwrapping if it isn't.
            if let charRangeValue = AXValueCreate(.cfRange, &charRange) {
                queryRange = charRangeValue
            } else {
                queryRange = rangeVal
            }
        } else {
            queryRange = rangeVal
        }

        // Get the bounds for this text range
        var boundsValue: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            axElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            queryRange,
            &boundsValue
        )
        guard boundsResult == .success, let boundsVal = validatedAXValue(boundsValue) else {
            DebugLogger.log("Hanja AX: boundsForRange failed (\(boundsResult.rawValue))")
            return nil
        }

        // Convert AXValue to CGRect
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsVal, .cgRect, &bounds) else {
            DebugLogger.log("Hanja AX: AXValueGetValue failed")
            return nil
        }

        DebugLogger.log("Hanja AX: raw bounds = \(bounds)")
        guard let primaryHeight = primaryDisplayHeight else { return nil }

        // Chrome returns (0, y, 0, 0) — only y is valid. Supplement x from the
        // element's position.
        if bounds.size.width == 0 && bounds.size.height == 0 {
            var posValue: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
               let pv = validatedAXValue(posValue) {
                var pos = CGPoint.zero
                guard AXValueGetValue(pv, .cgPoint, &pos) else {
                    DebugLogger.log("Hanja AX: element position was not a CGPoint")
                    return nil
                }
                if let result = chromiumPartialCaret(bounds, elementX: pos.x, primaryHeight: primaryHeight) {
                    DebugLogger.log("Hanja AX: Chrome partial → supplemented with element pos: \(result)")
                    if isValidCursorRect(result) { return result }
                }
            }
        }

        // Normal case: full bounds available
        let result = appKitRect(fromAX: bounds, primaryHeight: primaryHeight)

        guard isValidCursorRect(result) else {
            DebugLogger.log("Hanja AX: converted rect invalid: \(result)")
            return nil
        }

        return result
    }

    /// Fallback: use element's AXPosition to approximate caret location
    private static func getElementCaretPosition(_ axElement: AXUIElement) -> NSRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pv = validatedAXValue(posValue), let sv = validatedAXValue(sizeValue) else {
            DebugLogger.log("Hanja AX: element position/size unavailable")
            return nil
        }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pos),
              AXValueGetValue(sv, .cgSize, &size) else {
            DebugLogger.log("Hanja AX: element position/size had unexpected AXValue types")
            return nil
        }

        // Use the bottom-left of the element as a rough caret position
        guard let primaryHeight = primaryDisplayHeight else { return nil }
        let defaultHeight: CGFloat = 18
        let bottomLeft = appKitRect(fromAX: CGRect(x: pos.x, y: pos.y + size.height, width: 0, height: 0),
                                    primaryHeight: primaryHeight)
        let result = NSRect(x: pos.x, y: bottomLeft.minY, width: 0, height: defaultHeight)

        DebugLogger.log("Hanja AX: element position fallback: \(result)")
        guard isValidCursorRect(result) else { return nil }
        return result
    }

    // MARK: - Accessibility Coordinates

    /// Height of the primary display, the one with the menu bar. Accessibility
    /// reports global coordinates from ITS top-left corner with y growing down;
    /// AppKit's screen coordinates start at its bottom-left with y growing up.
    /// Not `NSScreen.main`, which is the display with the key window: when that
    /// is an external display of another height, the caret lands off by the
    /// difference.
    static var primaryDisplayHeight: CGFloat? {
        NSScreen.screens.first?.frame.height
    }

    /// An Accessibility rect in AppKit screen coordinates.
    static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width, height: rect.height)
    }

    /// Chromium answers AXBoundsForRange with only a y: (0, y, 0, 0). With the
    /// focused element's x that still places the caret's line. A display above
    /// or left of the primary one has negative coordinates, so a real y is told
    /// from a missing one by its magnitude, not its sign. `nil` when `bounds` is
    /// not such a partial answer.
    static func chromiumPartialCaret(_ bounds: CGRect, elementX: CGFloat, primaryHeight: CGFloat) -> NSRect? {
        guard bounds.width == 0, bounds.height == 0, bounds.origin.y.isFinite, abs(bounds.origin.y) > 1 else {
            return nil
        }
        let lineHeight: CGFloat = 18
        return appKitRect(fromAX: CGRect(x: elementX, y: bounds.origin.y, width: 0, height: lineHeight),
                          primaryHeight: primaryHeight)
    }

    private static func validatedAXElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func validatedAXValue(_ value: AnyObject?) -> AXValue? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
