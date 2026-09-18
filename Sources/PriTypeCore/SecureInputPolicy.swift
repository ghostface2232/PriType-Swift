// MARK: - SecureInputPolicy

/// Pure policy for deciding whether a secure-input-looking client should bypass IMK composition.
///
/// `IsSecureEventInputEnabled()` is system-wide, not scoped to the focused field.
/// Treat it as a warning signal: fail closed when the current client is incapable or
/// has no selection, but allow a normal marked-text-capable field to recover from a
/// stale flag left behind by another app. Avoid Accessibility probing on the hot path.
struct SecureInputSignals: Sendable {
    let bundleId: String
    let hasTextInputCapability: Bool
    let hasInvalidSelection: Bool
    let hasGlobalSecureInput: Bool
}

struct SecureInputPolicy: Sendable {
    static func isSystemSecureClient(_ bundleId: String) -> Bool {
        bundleId == "com.apple.SecurityAgent" ||
            bundleId == "com.apple.loginwindow" ||
            bundleId == "com.apple.screencaptureui"
    }

    static func shouldPassThrough(_ signals: SecureInputSignals) -> Bool {
        if isSystemSecureClient(signals.bundleId) {
            return true
        }

        // An empty supported-attributes list is not proof of a secure field.
        // Only combine these heuristics with a live global secure-input warning.
        // This also permits legacy clients with no document-range API to compose.
        return signals.hasGlobalSecureInput &&
            (signals.hasInvalidSelection || !signals.hasTextInputCapability)
    }
}
